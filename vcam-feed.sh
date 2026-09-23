#!/usr/bin/env bash
# vcam-feed.sh — Feed real camera into virtual camera device
# Part of the virtualcamera project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/vcam.log"
PID_FILE="${SCRIPT_DIR}/vcam-feed.pid"

info()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m✗\033[0m %s\n' "$*"; }
log()   { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# ─── find v4l2loopback device ────────────────────────────────────────────────
find_vcam_device() {
    for dev in /dev/video*; do
        local name
        name=$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "")
        if [ "$name" = "Virtual Camera" ]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

# ─── find real camera source ─────────────────────────────────────────────────
find_camera_source() {
    # Prefer v4l2src on the IMGU output node (reliable NV12 output)
    if [ -n "${VCAM_SOURCE:-}" ]; then
        echo "$VCAM_SOURCE"
        return 0
    fi

    for dev in /dev/video*; do
        local name
        name=$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "")
        if [ "$name" = "ipu3-imgu 0 output" ]; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

# ─── resolution ──────────────────────────────────────────────────────────────
CAM_WIDTH="${VCAM_WIDTH:-1280}"
CAM_HEIGHT="${VCAM_HEIGHT:-720}"
CAM_FPS="${VCAM_FPS:-30}"

# ─── gstreamer pipeline ──────────────────────────────────────────────────────
build_pipeline() {
    local cam_src="$1"
    local vcam_dev="$2"

    # IPU3/libcamerasrc outputs DMABuf-backed NV12 buffers. v4l2loopback
    # cannot import DMABuf, so videoconvert copies to system memory.
    # Output YUY2 (V4L2 YUYV) because wemeet's TRTC engine requests YUYV
    # on the capture side and v4l2loopback does not convert between formats.
    local base_caps="video/x-raw,format=NV12,width=${CAM_WIDTH},height=${CAM_HEIGHT},framerate=${CAM_FPS}/1"
    local out_caps="video/x-raw,format=YUY2"
    local sink="v4l2sink device=$vcam_dev"

    if command -v gst-inspect-1.0 &>/dev/null && gst-inspect-1.0 libcamerasrc &>/dev/null 2>&1; then
        echo "libcamerasrc ! ${base_caps} ! videoconvert ! ${out_caps} ! queue max-size-buffers=3 ! ${sink}"
        return 0
    fi

    if [ -n "$cam_src" ] && [ -e "$cam_src" ]; then
        echo "v4l2src device=$cam_src ! ${base_caps} ! videoconvert ! ${out_caps} ! queue max-size-buffers=3 ! ${sink}"
        return 0
    fi

    echo "videotestsrc ! ${out_caps} ! ${sink}"
    return 0
}

# ─── start feed ──────────────────────────────────────────────────────────────
do_start() {
    local vcam_dev cam_src
    if ! vcam_dev=$(find_vcam_device); then
        fail "No virtual camera device found. Run vcam-on.sh first."
        exit 1
    fi

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        warn "Camera feed is already running (PID $(cat "$PID_FILE"))"
        exit 0
    fi

    cam_src=$(find_camera_source || echo "")

    if [ -z "$cam_src" ]; then
        warn "No hardware camera output found, using test pattern"
        info "Install pipewire-v4l2 or check camera drivers for real video"
    fi

    local pipeline
    pipeline=$(build_pipeline "$cam_src" "$vcam_dev")

    # Use the anti-flicker tuning file (pins exposure to 10 ms = one 50 Hz mains cycle)
    export LIBCAMERA_IPA_CONFIG_PATH="${LIBCAMERA_IPA_CONFIG_PATH:-$HOME/.config/libcamera/ipa}"

    info "Starting camera feed → $vcam_dev (${CAM_WIDTH}x${CAM_HEIGHT} @ ${CAM_FPS}fps)…"
    [ -n "$cam_src" ] && info "Source: $cam_src"
    info "Pipeline: $pipeline"

    # Run in background, log stderr for debugging
    nohup gst-launch-1.0 $pipeline >> "$LOG_FILE" 2>&1 &
    disown
    local pid=$!
    echo "$pid" > "$PID_FILE"
    sleep 1

    if kill -0 "$pid" 2>/dev/null; then
        ok "Camera feed started (PID $pid)"
        log "Feed started (PID $pid) → $vcam_dev (source: ${cam_src:-test})"
    else
        rm -f "$PID_FILE"
        fail "Camera feed failed to start — check $LOG_FILE for details"
        warn "Try manually: gst-launch-1.0 v4l2src device=/dev/video2 ! v4l2sink device=$vcam_dev"
        exit 1
    fi
}

# ─── stop feed ───────────────────────────────────────────────────────────────
do_stop() {
    if [ ! -f "$PID_FILE" ]; then
        info "Camera feed is not running"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        info "Stopping camera feed (PID $pid)…"
        kill "$pid" 2>/dev/null || true
        sleep 0.3
        kill -9 "$pid" 2>/dev/null || true
        ok "Camera feed stopped"
        log "Feed stopped (PID $pid)"
    else
        info "Camera feed was already stopped"
    fi

    rm -f "$PID_FILE"
}

# ─── status ──────────────────────────────────────────────────────────────────
do_status() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        local vcam_dev
        vcam_dev=$(find_vcam_device || echo "none")
        ok "Camera feed running (PID $(cat "$PID_FILE")) → $vcam_dev"
    else
        info "Camera feed is not running"
        [ -f "$PID_FILE" ] && rm -f "$PID_FILE"
    fi
}

# ─── usage ───────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: vcam-feed.sh {start|stop|status}"
    echo ""
    echo "  start   Feed real camera into the virtual camera device"
    echo "  stop    Stop the camera feed"
    echo "  status  Show feed status"
    echo ""
    echo "Environment:"
    echo "  VCAM_WIDTH   Video width (default: 1280)"
    echo "  VCAM_HEIGHT  Video height (default: 720)"
    echo "  VCAM_FPS     Frame rate (default: 30)"
    echo "  VCAM_SOURCE  Override camera source device (e.g. /dev/video2)"
    exit 1
}

# ─── main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    *)      usage ;;
esac
