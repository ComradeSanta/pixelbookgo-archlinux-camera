#!/usr/bin/env bash
# vcam-off.sh — Disable virtual camera device
# Part of the virtualcamera project
# Repository: /home/arch/virtualcamera
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/vcam.log"

# ─── helpers ────────────────────────────────────────────────────────────────
info()  { printf '\033[1;34m▶\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m✗\033[0m %s\n' "$*"; }
log()   { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

# ─── stop camera feed ─────────────────────────────────────────────────────────
stop_feed() {
    # Stop the systemd feed service (canonical feed path) if present
    if systemctl --user cat v4l2loopback-camera.service &>/dev/null; then
        systemctl --user stop v4l2loopback-camera.service 2>/dev/null || true
    fi
}

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

# ─── unload v4l2loopback ─────────────────────────────────────────────────────
unload_module() {
    # Check for virtual camera via sysfs (works inside namespaces) and lsmod
    local vcam_exists=0
    if find_vcam_device &>/dev/null; then
        vcam_exists=1
    elif ! lsmod 2>/dev/null | grep -q v4l2loopback; then
        ok "v4l2loopback not loaded — nothing to unload"
        return 0
    fi

    local vcam_dev
    if vcam_dev=$(find_vcam_device); then
        info "Found virtual camera: $vcam_dev"
    fi

    # modprobe -r fails while ANY process holds the device (wechat, wemeet,
    # guvcview, pipewire…). Give the just-stopped feed a moment to exit,
    # then report remaining holders instead of failing blindly.
    local i holders
    for i in 1 2 3 4 5 6; do
        holders=$(fuser /dev/video* 2>/dev/null || true)
        [ -z "$holders" ] && break
        sleep 0.5
    done
    if [ -n "$holders" ]; then
        warn "Device is still in use by:"
        fuser -v /dev/video* 2>&1 | grep -v '^$' | sed 's/^/    /' || true
        warn "Close camera apps first (WeChat, wemeet, guvcview…), then retry."
        return 1
    fi

    info "Unloading v4l2loopback kernel module…"

    # Pick ONE escalation tool and try ONCE — cascading run0→pkexec→sudo
    # used to produce multiple password prompts for the same failure.
    local tool=""
    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        tool="sudo"
    elif command -v run0 &>/dev/null; then
        tool="run0"
    elif command -v pkexec &>/dev/null; then
        tool="pkexec"
    elif command -v sudo &>/dev/null; then
        tool="sudo"
    fi

    if [ -z "$tool" ]; then
        warn "No privilege escalation tool available — run manually: modprobe -r v4l2loopback"
        return 1
    fi

    if "$tool" modprobe -r v4l2loopback 2>>"$LOG_FILE"; then
        ok "v4l2loopback unloaded via $tool"
        return 0
    fi

    warn "Could not unload module via $tool — see $LOG_FILE"
    return 1
}

# ─── show remaining virtual camera devices ────────────────────────────────────
show_remaining() {
    local found=0
    for dev in /dev/video*; do
        local name
        name=$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "")
        if [ "$name" = "Virtual Camera" ]; then
            warn "Virtual camera device still present: $dev"
            found=1
        fi
    done
    if [ "$found" = "0" ]; then
        ok "No virtual camera devices remaining"
    fi
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    info "═══════════════════════════════════════════"
    info "  Virtual Camera — Deactivate"
    info "═══════════════════════════════════════════"
    echo ""

    log "=== vcam-off.sh started ==="

    stop_feed
    echo ""
    unload_module
    echo ""
    show_remaining

    log "=== vcam-off.sh completed ==="
    ok "Virtual camera deactivated"
}

main "$@"
