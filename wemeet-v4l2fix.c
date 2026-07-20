/* wemeet-v4l2fix.so — work around wemeet/TRTC sending DQBUF/QBUF with
 * v4l2_buffer.memory = 0 on the capture side, which v4l2loopback rejects
 * with EINVAL (result: black camera in Tencent Meeting while other apps
 * work). This shim rewrites memory to V4L2_MEMORY_MMAP before the ioctl.
 *
 * Loaded via LD_PRELOAD in wemeet.sh. Only touches /dev/video* fds and
 * only when memory == 0, so it is inert for well-behaved callers.
 *
 * Set WEMEET_V4L2FIX_LOG=/path/to/log to enable ioctl tracing for debugging.
 *
 * Build: gcc -O2 -shared -fPIC -o wemeet-v4l2fix.so wemeet-v4l2fix.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>

static int (*real_ioctl)(int, unsigned long, ...);
static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_close)(int);

static unsigned char tracked[256];
static FILE *logf;
static __thread int in_hook;

static void fix_init(void) {
    if (real_ioctl) return;
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    real_open = dlsym(RTLD_NEXT, "open");
    real_open64 = dlsym(RTLD_NEXT, "open64");
    real_close = dlsym(RTLD_NEXT, "close");
    const char *p = getenv("WEMEET_V4L2FIX_LOG");
    if (p && *p) {
        logf = fopen(p, "a");
        if (logf) setvbuf(logf, NULL, _IOLBF, 0);
    }
}

static void flog(const char *fmt, ...) {
    if (!logf) return;
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    fprintf(logf, "[%ld.%03ld] ", ts.tv_sec % 100000, ts.tv_nsec / 1000000);
    va_list ap; va_start(ap, fmt);
    vfprintf(logf, fmt, ap);
    va_end(ap);
    fflush(logf);
}

int ioctl(int fd, unsigned long req, ...) {
    fix_init();
    va_list ap; va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    unsigned long r32 = req & 0xffffffffUL;
    int fixed = 0;
    if (fd >= 0 && fd < 256 && tracked[fd] && arg &&
        (r32 == VIDIOC_DQBUF || r32 == VIDIOC_QBUF || r32 == VIDIOC_QUERYBUF)) {
        struct v4l2_buffer *b = arg;
        if (b->type == V4L2_BUF_TYPE_VIDEO_CAPTURE && b->memory == 0) {
            b->memory = V4L2_MEMORY_MMAP;
            fixed = 1;
        }
    }
    int ret = real_ioctl(fd, req, arg);
    if (fixed && !in_hook) {
        in_hook = 1;
        flog("ioctl(fd=%d, %s) mem fixup -> %d\n", fd,
             r32 == VIDIOC_DQBUF ? "DQBUF" : r32 == VIDIOC_QBUF ? "QBUF" : "QUERYBUF",
             ret);
        in_hook = 0;
    }
    return ret;
}

static void note_open(int fd, const char *path) {
    if (fd >= 0 && fd < 256 && path &&
        strncmp(path, "/dev/video", 10) == 0) {
        tracked[fd] = 1;
        flog("open(%s) = %d\n", path, fd);
    }
}

int open(const char *path, int flags, ...) {
    fix_init();
    mode_t m = 0;
    int fd;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap);
        fd = real_open(path, flags, m);
    } else {
        fd = real_open(path, flags);
    }
    if (!in_hook) { in_hook = 1; note_open(fd, path); in_hook = 0; }
    return fd;
}

int open64(const char *path, int flags, ...) {
    fix_init();
    mode_t m = 0;
    int fd;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); m = va_arg(ap, mode_t); va_end(ap);
        fd = real_open64(path, flags, m);
    } else {
        fd = real_open64(path, flags);
    }
    if (!in_hook) { in_hook = 1; note_open(fd, path); in_hook = 0; }
    return fd;
}

int close(int fd) {
    fix_init();
    if (fd >= 0 && fd < 256 && tracked[fd]) {
        tracked[fd] = 0;
        flog("close(%d)\n", fd);
    }
    return real_close(fd);
}
