#!/usr/bin/env bash
# wemeet.sh — Launch Tencent Meeting with virtual camera support
# Part of the virtualcamera project
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/vcam.log"

info()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m✗\033[0m %s\n' "$*"; }
log()   { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

has_vcam() {
    for dev in /dev/video*; do
        local name
        name=$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "")
        if [ "$name" = "Virtual Camera" ]; then
            return 0
        fi
    done
    return 1
}

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

# ─── ensure virtual camera is active ────────────────────────────────────────
ensure_camera() {
    if has_vcam; then
        local vcam_dev
        vcam_dev=$(find_vcam_device)
        ok "Virtual camera detected: $vcam_dev"
    else
        warn "No active virtual camera detected"
        info "Auto-starting virtual camera…"
        echo ""

        if bash "${SCRIPT_DIR}/vcam-on.sh"; then
            ok "Virtual camera ready"
        else
            warn "Could not auto-start virtual camera"
            warn "Continuing with wemeet anyway — camera may not work"
        fi
    fi

    # The device may exist (module loads at boot) while the feed is off —
    # the camera would show black. Do not auto-start it (user prefers to
    # toggle manually), but make the cause obvious.
    if systemctl --user cat v4l2loopback-camera.service &>/dev/null && \
       ! systemctl --user is-active --quiet v4l2loopback-camera.service; then
        warn "Camera feed is NOT running — video will be black."
        warn "Turn it on first: ./vcam-toggle.sh (menu: 开关虚拟摄像头)"
        command -v notify-send &>/dev/null && \
            notify-send -i camera-web "虚拟摄像头未开启" "视频将是黑屏——请先点击“开关虚拟摄像头”" || true
    fi
}

# ─── launch wemeet ──────────────────────────────────────────────────────────
launch_wemeet() {
    if ! [ -x /opt/wemeet/bin/wemeetapp ]; then
        fail "wemeet is not installed in /opt/wemeet!"
        exit 1
    fi

    info "Launching Tencent Meeting…"
    log "Launching wemeet with args: $*"

    export QT_AUTO_SCREEN_SCALE_FACTOR=1
    export QT_STYLE_OVERRIDE=fusion
    export IBUS_USE_PORTAL=1
    export LC_ALL=zh_CN.UTF-8
    export PATH="/opt/wemeet/bin${PATH:+:$PATH}"
    export LD_LIBRARY_PATH="/opt/wemeet/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QT_PLUGIN_PATH="/opt/wemeet/plugins"

    if [ "$XDG_SESSION_TYPE" = 'wayland' ]; then
        export QT_QPA_PLATFORM=xcb
        export XDG_SESSION_TYPE=x11
        unset WAYLAND_DISPLAY
        export WEMEET_XWAYLAND=1
    fi

    # Work around wemeet's TRTC engine sending DQBUF/QBUF with
    # v4l2_buffer.memory unset — v4l2loopback rejects those with EINVAL,
    # which used to leave the camera black. See wemeet-v4l2fix.c.
    local fix_so="${SCRIPT_DIR}/wemeet-v4l2fix.so"
    if [ -r "$fix_so" ]; then
        export LD_PRELOAD="${fix_so}${LD_PRELOAD:+:$LD_PRELOAD}"
    else
        warn "wemeet-v4l2fix.so missing — camera may stay black (rebuild: gcc -O2 -shared -fPIC -o wemeet-v4l2fix.so wemeet-v4l2fix.c -ldl)"
    fi

    exec /opt/wemeet/bin/wemeetapp "$@"
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    info "═══════════════════════════════════════════"
    info "  Tencent Meeting with Virtual Camera"
    info "═══════════════════════════════════════════"
    echo ""

    log "=== wemeet.sh started ==="

    ensure_camera
    echo ""
    launch_wemeet "$@"
}

main "$@"
