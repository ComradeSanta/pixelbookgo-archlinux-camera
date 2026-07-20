#!/usr/bin/env bash
# wechat.sh — Launch WeChat with virtual camera support
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

ensure_camera() {
    if has_vcam; then
        ok "Virtual camera detected"
    else
        warn "No active virtual camera detected"
        info "Auto-starting virtual camera…"
        echo ""

        if bash "${SCRIPT_DIR}/vcam-on.sh"; then
            ok "Virtual camera ready"
        else
            warn "Could not auto-start virtual camera"
            warn "Continuing with WeChat anyway — camera may not work"
        fi
    fi

    # Device may exist (module loads at boot) while the feed is off —
    # warn instead of auto-starting (user prefers manual toggle).
    if systemctl --user cat v4l2loopback-camera.service &>/dev/null && \
       ! systemctl --user is-active --quiet v4l2loopback-camera.service; then
        warn "Camera feed is NOT running — video will be black."
        warn "Turn it on first: ./vcam-toggle.sh (menu: 开关虚拟摄像头)"
        command -v notify-send &>/dev/null && \
            notify-send -i camera-web "虚拟摄像头未开启" "视频将是黑屏——请先点击“开关虚拟摄像头”" || true
    fi
}

find_wechat_bin() {
    # Try common binary names and paths
    for bin in wechat wechat-bin; do
        if command -v "$bin" &>/dev/null; then
            echo "$bin"
            return 0
        fi
    done

    # Flatpak
    if command -v flatpak &>/dev/null && flatpak info com.tencent.WeChat &>/dev/null 2>&1; then
        echo "flatpak"
        return 0
    fi

    # Official Tencent path
    if [ -x /opt/wechat/wechat ]; then
        echo "/opt/wechat/wechat"
        return 0
    fi

    # WeChat Linux (Tencent's official deb-based install, sometimes found here)
    if [ -x "/opt/WeChat/wechat" ]; then
        echo "/opt/WeChat/wechat"
        return 0
    fi

    return 1
}

launch_wechat() {
    local bin
    bin=$(find_wechat_bin) || {
        fail "WeChat is not installed!"
        echo ""
        info "Install options:"
        info "  AUR:        yay -S wechat-bin"
        info "  Flatpak:    flatpak install com.tencent.WeChat"
        info "  Official:   https://linux.weixin.qq.com/"
        exit 1
    }

    info "Launching WeChat…"
    log "Launching WeChat (type: $bin)"

    case "$bin" in
        flatpak)
            exec flatpak run com.tencent.WeChat "$@"
            ;;
        *)
            exec "$bin" "$@"
            ;;
    esac
}

main() {
    echo ""
    info "═══════════════════════════════════════════"
    info "  WeChat with Virtual Camera"
    info "═══════════════════════════════════════════"
    echo ""

    log "=== wechat.sh started ==="

    ensure_camera
    echo ""
    launch_wechat "$@"
}

main "$@"
