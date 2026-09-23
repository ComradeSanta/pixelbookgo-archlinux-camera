/* wemeet-v4l2fix.so — two workarounds for Tencent Meeting (TRTC engine):
 *
 * 1. TRTC sends DQBUF/QBUF with v4l2_buffer.memory = 0 on the capture side,
 *    which v4l2loopback rejects with EINVAL (result: black camera while
 *    other apps work). Rewritten to V4L2_MEMORY_MMAP before the ioctl.
 * 2. TRTC reads capture buffers lazily (after DQBUF, during encode), while
 *    the loopback producer rewrites that same shared memory ~2 frames
 *    later — producing a torn frame whose seam slowly rolls up the picture.
 *    Each mmap of a capture buffer is substituted with a PRIVATE anonymous
 *    mapping that is refreshed synchronously at every DQBUF (the only
 *    moment the buffer is guaranteed stable), so late reads stay clean.
 *
 * Loaded via LD_PRELOAD in wemeet.sh / the wemeetapp desktop entry.
 * Only touches /dev/video* fds, so it is inert for well-behaved callers.
 *
 * Set WEMEET_V4L2FIX_LOG=/path/to/log to enable ioctl tracing for debugging.
 * Set WEMEET_V4L2FIX_DUMP=/path/to/raw to dump the first
 * WEMEET_V4L2FIX_DUMP_N (default 90) DQBUF'd capture frames verbatim
 * (fixed-size records, one per buffer length) — for diagnosing artifacts
 * in the frames wemeet actually receives.
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
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

static int (*real_ioctl)(int, unsigned long, ...);
static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_close)(int);
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);
static int (*real_munmap)(void *, size_t);

static unsigned char tracked[256];
static FILE *logf;
static __thread int in_hook;

/* frame-dump state */
#define MAX_BUFS 32
static off_t buf_offset[256][MAX_BUFS];
static size_t buf_len[256][MAX_BUFS];
/* anti-tear: wemeet reads capture buffers late (after DQBUF, during encode),
 * while the loopback producer rewrites that same shared memory ~2 frames
 * later — a torn frame with a seam that slowly rolls up the picture.
 * We hand wemeet a PRIVATE copy of each buffer instead of the shared
 * mapping, refreshed synchronously at every DQBUF while the buffer is
 * guaranteed stable (just marked done; next rewrite is frames away). */
static void *buf_src[256][MAX_BUFS];   /* real mapping of the driver buffer */
static void *buf_priv[256][MAX_BUFS];  /* private copy returned to wemeet */
static FILE *dumpf;
static long dump_left;
static pthread_mutex_t dump_lock = PTHREAD_MUTEX_INITIALIZER;

static void fix_init(void) {
    if (real_ioctl) return;
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    real_open = dlsym(RTLD_NEXT, "open");
    real_open64 = dlsym(RTLD_NEXT, "open64");
    real_close = dlsym(RTLD_NEXT, "close");
    real_mmap = dlsym(RTLD_NEXT, "mmap");
    real_munmap = dlsym(RTLD_NEXT, "munmap");
    const char *p = getenv("WEMEET_V4L2FIX_LOG");
    if (p && *p) {
        logf = fopen(p, "a");
        if (logf) setvbuf(logf, NULL, _IOLBF, 0);
    }
    p = getenv("WEMEET_V4L2FIX_DUMP");
    if (p && *p) {
        dumpf = fopen(p, "w");
        dump_left = 90;
        const char *n = getenv("WEMEET_V4L2FIX_DUMP_N");
        if (n && *n) dump_left = atol(n);
        if (dumpf) setvbuf(dumpf, NULL, _IOFBF, 1 << 20);
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

/* remember index -> offset/length from QUERYBUF so DQBUF can find the
 * mmap'ed address later */
static void note_querybuf(int fd, struct v4l2_buffer *b) {
    if (fd < 0 || fd >= 256 || !b || b->index >= MAX_BUFS) return;
    if (b->memory != V4L2_MEMORY_MMAP) return;
    buf_offset[fd][b->index] = b->m.offset;
    buf_len[fd][b->index] = b->length;
}

/* on successful capture DQBUF: refresh the private copy, then optionally
 * dump the frame for diagnostics */
static void on_dqbuf(int fd, struct v4l2_buffer *b, int ret) {
    if (ret || fd < 0 || fd >= 256 || !b || b->index >= MAX_BUFS) return;
    if (b->type != V4L2_BUF_TYPE_VIDEO_CAPTURE) return;
    void *src = buf_src[fd][b->index];
    void *priv = buf_priv[fd][b->index];
    size_t len = buf_len[fd][b->index];
    if (!src || !priv || !len) return;

    pthread_mutex_lock(&dump_lock);
    /* copy with a stability check: if the producer rewrites the buffer
     * while this thread is preempted mid-copy, the copy comes out torn.
     * Re-copying converges because the buffer stays untouched for the
     * next whole producer rotation (~2 frames). */
    for (int tries = 0; tries < 4; tries++) {
        memcpy(priv, src, len);
        if (memcmp(priv, src, len) == 0)
            break;
    }
    if (dumpf && dump_left > 0) {
        fwrite(priv, 1, len, dumpf);
        dump_left--;
        flog("dump idx=%u bytesused=%u len=%zu left=%ld\n",
             b->index, b->bytesused, len, dump_left);
    }
    pthread_mutex_unlock(&dump_lock);
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
    if (fd >= 0 && fd < 256 && tracked[fd] && arg) {
        if (r32 == VIDIOC_QUERYBUF && !ret)
            note_querybuf(fd, arg);
        else if (r32 == VIDIOC_DQBUF)
            on_dqbuf(fd, arg, ret);
        else if (r32 == VIDIOC_REQBUFS && !ret) {
            /* buffer set changed: drop stale mappings/offsets */
            struct v4l2_requestbuffers *rb = arg;
            if (rb->type == V4L2_BUF_TYPE_VIDEO_CAPTURE) {
                memset(buf_offset[fd], 0, sizeof(buf_offset[fd]));
                memset(buf_len[fd], 0, sizeof(buf_len[fd]));
                memset(buf_src[fd], 0, sizeof(buf_src[fd]));
                memset(buf_priv[fd], 0, sizeof(buf_priv[fd]));
            }
        }
    }
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

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    fix_init();
    if (fd >= 0 && fd < 256 && tracked[fd]) {
        /* capture buffer on a tracked video fd? substitute a private copy */
        for (int i = 0; i < MAX_BUFS; i++) {
            if (!buf_len[fd][i] || buf_offset[fd][i] != offset) continue;
            void *src = real_mmap(addr, length, prot, flags, fd, offset);
            if (src == MAP_FAILED) return src;
            void *priv = real_mmap(NULL, length, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (priv == MAP_FAILED) { real_munmap(src, length); return priv; }
            memcpy(priv, src, length);
            buf_src[fd][i] = src;
            buf_priv[fd][i] = priv;
            flog("mmap fd=%d idx=%d len=%zu -> priv %p (src %p)\n",
                 fd, i, length, priv, src);
            return priv;
        }
    }
    return real_mmap(addr, length, prot, flags, fd, offset);
}

int munmap(void *addr, size_t length) {
    fix_init();
    for (int fd = 0; fd < 256; fd++) {
        if (!tracked[fd]) continue;
        for (int i = 0; i < MAX_BUFS; i++) {
            if (buf_priv[fd][i] == addr) {
                real_munmap(buf_src[fd][i], buf_len[fd][i]);
                buf_src[fd][i] = NULL;
                buf_priv[fd][i] = NULL;
                return real_munmap(addr, length);
            }
        }
    }
    return real_munmap(addr, length);
}

int close(int fd) {
    fix_init();
    if (fd >= 0 && fd < 256 && tracked[fd]) {
        tracked[fd] = 0;
        for (int i = 0; i < MAX_BUFS; i++) {
            if (buf_src[fd][i]) real_munmap(buf_src[fd][i], buf_len[fd][i]);
            if (buf_priv[fd][i]) real_munmap(buf_priv[fd][i], buf_len[fd][i]);
        }
        memset(buf_offset[fd], 0, sizeof(buf_offset[fd]));
        memset(buf_len[fd], 0, sizeof(buf_len[fd]));
        memset(buf_src[fd], 0, sizeof(buf_src[fd]));
        memset(buf_priv[fd], 0, sizeof(buf_priv[fd]));
        flog("close(%d)\n", fd);
    }
    return real_close(fd);
}
