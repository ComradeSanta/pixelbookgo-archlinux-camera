#!/usr/bin/env bash
# vcam-on.sh — Enable virtual camera device
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

# ─── environment check ──────────────────────────────────────────────────────
check_env() {
    info "Checking environment…"

    # Detect user namespace
    if [ "$(cat /proc/self/uid_map 2>/dev/null | awk '{print $2}')" = "0" ]; then
        warn "Running inside a user namespace (sandbox/container)"
        warn "  → /dev/video* devices from the host may not be visible here"
        IN_USERNS=1
    else
        IN_USERNS=0
    fi

    # Detect no-new-privs (prevents sudo/setuid escalation)
    if grep -q "no-new-privs=1" /proc/self/status 2>/dev/null; then
        warn "no-new-privileges flag is set — privilege escalation may be blocked"
        NO_NEW_PRIVS=1
    else
        NO_NEW_PRIVS=0
    fi

    # Available privilege escalation tools
    PRIV_TOOL=""
    for tool in sudo run0 pkexec doas; do
        if command -v "$tool" &>/dev/null; then
            PRIV_TOOL="$tool"
            break
        fi
    done

    if [ -n "$PRIV_TOOL" ] && [ "$NO_NEW_PRIVS" = "0" ]; then
        ok "Privilege escalation available via: $PRIV_TOOL"
    else
        warn "No working privilege escalation tool — will use diagnostic mode only"
        PRIV_TOOL=""
    fi
}

# ─── find v4l2loopback device number ────────────────────────────────────────
find_vcam_device() {
    for dev in /dev/video*; do
        local name
        name=$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "")
        if [ "$name" = "Virtual Camera" ]; then
            basename "$dev" | sed 's/.*video//'
            return 0
        fi
    done
    return 1
}

# ─── find first available video device number ───────────────────────────────
find_free_video_nr() {
    local max=0
    for dev in /dev/video*; do
        local nr
        nr=$(basename "$dev" | sed 's/.*video//')
        [ "$nr" -gt "$max" ] 2>/dev/null && max="$nr"
    done
    echo "$((max + 1))"
}

# ─── strategy 1: check if already active ────────────────────────────────────
strategy_already_active() {
    local vcam_nr
    if vcam_nr=$(find_vcam_device); then
        ok "Virtual Camera already active at /dev/video${vcam_nr}!"
        echo "    /dev/video${vcam_nr}  →  Virtual Camera"
        return 0
    fi

    # Check if v4l2loopback module is loaded (device node may be hidden by namespace)
    if lsmod 2>/dev/null | grep -q v4l2loopback; then
        ok "v4l2loopback kernel module is already loaded"
        info "Virtual Camera device node may not be visible due to namespace isolation"
        return 0
    fi

    return 1
}

# ─── start camera feed ───────────────────────────────────────────────────────
start_feed() {
    # Prefer the systemd user service (single canonical feed path, 1280x720)
    if systemctl --user cat v4l2loopback-camera.service &>/dev/null; then
        if systemctl --user is-active --quiet v4l2loopback-camera.service; then
            ok "Camera feed already running"
        else
            info "Starting camera feed (v4l2loopback-camera.service)…"
            if systemctl --user start v4l2loopback-camera.service; then
                ok "Camera feed started"
            else
                warn "Camera feed could not be started — camera may show black video"
            fi
        fi
        return 0
    fi

    warn "v4l2loopback-camera.service not found — no feed started (see README §3.3)"
    return 0
}

# ─── strategy 2: load v4l2loopback via run0 ────────────────────────────────
strategy_run0() {
    info "Strategy: Load v4l2loopback via run0…"
    if ! command -v run0 &>/dev/null; then
        return 1
    fi

    local video_nr
    video_nr=$(find_free_video_nr)

    info "A polkit authentication dialog may appear — please authenticate."
    if run0 modprobe v4l2loopback devices=1 video_nr="$video_nr" \
        card_label="Virtual Camera" exclusive_caps=0 max_buffers=8 pixel_formats=NV12,YUYV 2>>"$LOG_FILE"; then
        sleep 1
        if [ -e "/dev/video${video_nr}" ]; then
            ok "Virtual camera created: /dev/video${video_nr}"
            run0 chmod 666 "/dev/video${video_nr}" 2>/dev/null || true
            ok "v4l2loopback loaded and virtual camera is ready"
            return 0
        fi
    fi
    warn "run0: module not loaded (may need polkit authentication)"
    return 1
}

# ─── strategy 3: load via pkexec ────────────────────────────────────────────
strategy_pkexec() {
    info "Strategy: Load v4l2loopback via pkexec…"
    if ! command -v pkexec &>/dev/null; then
        return 1
    fi

    local video_nr
    video_nr=$(find_free_video_nr)

    if pkexec modprobe v4l2loopback devices=1 video_nr="$video_nr" \
        card_label="Virtual Camera" exclusive_caps=0 max_buffers=8 pixel_formats=NV12,YUYV 2>>"$LOG_FILE"; then
        sleep 1
        if [ -e "/dev/video${video_nr}" ]; then
            ok "Virtual camera created via pkexec: /dev/video${video_nr}"
            pkexec chmod 666 "/dev/video${video_nr}" 2>/dev/null || true
            return 0
        fi
    fi
    warn "pkexec: module not loaded"
    return 1
}

# ─── strategy 4: load via sudo ──────────────────────────────────────────────
strategy_sudo() {
    info "Strategy: Load v4l2loopback via sudo…"
    if ! command -v sudo &>/dev/null; then
        return 1
    fi

    local video_nr
    video_nr=$(find_free_video_nr)

    # Check if sudo is functional first
    if sudo -n true 2>/dev/null; then
        # Passwordless sudo works
        sudo modprobe v4l2loopback devices=1 video_nr="$video_nr" \
            card_label="Virtual Camera" exclusive_caps=0 max_buffers=8 pixel_formats=NV12,YUYV 2>>"$LOG_FILE" || return 1
    else
        # Try with a timeout for password prompt
        timeout 10 sudo -A modprobe v4l2loopback devices=1 video_nr="$video_nr" \
            card_label="Virtual Camera" exclusive_caps=0 max_buffers=8 pixel_formats=NV12,YUYV 2>>"$LOG_FILE" || return 1
    fi

    sleep 1
    if [ -e "/dev/video${video_nr}" ]; then
        ok "Virtual camera created via sudo: /dev/video${video_nr}"
        sudo chmod 666 "/dev/video${video_nr}" 2>/dev/null || true
        return 0
    fi
    warn "sudo: module not loaded"
    return 1
}

# ─── diagnostics ────────────────────────────────────────────────────────────
show_diagnostics() {
    echo ""
    info "═══ Camera diagnostics ═══"
    echo ""

    # /dev/video devices
    local devs
    devs=$(ls /dev/video* 2>/dev/null || true)
    if [ -n "$devs" ]; then
        echo "  /dev/video devices:"
        for dev in $devs; do
            local name
            name=$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "unknown")
            echo "    $dev  →  $name"
        done
    else
        echo "  /dev/video*: none (expected inside user namespace)"
    fi

    # Devices visible via sysfs
    local sysfs_devs
    sysfs_devs=$(ls /sys/class/video4linux/ 2>/dev/null | grep -v subdev || true)
    if [ -n "$sysfs_devs" ]; then
        echo "  Hardware devices (sysfs):"
        for dev in $sysfs_devs; do
            local name
            name=$(cat /sys/class/video4linux/"$dev"/name 2>/dev/null || echo "unknown")
            local pci
            pci=$(readlink /sys/class/video4linux/"$dev"/device 2>/dev/null | grep -o 'pci.*' || echo "unknown")
            echo "    $dev  →  $name  ($pci)"
        done
    fi

    # Kernel module / virtual camera device
    if find_vcam_device &>/dev/null; then
        echo ""
        echo "  Virtual Camera device: PRESENT  ✓"
    elif lsmod 2>/dev/null | grep -q v4l2loopback; then
        echo ""
        echo "  v4l2loopback module: LOADED (device not visible — namespace isolation?)"
    else
        echo ""
        echo "  Virtual Camera: not active"
    fi

    # PipeWire visibility
    if command -v pw-cli &>/dev/null && pw-cli info &>/dev/null 2>&1; then
        echo ""
        echo "  PipeWire video sources (from V4L2 SPA plugin):"
        local pw_sources
        pw_sources=$(pw-cli list-objects 2>/dev/null | grep -B1 "Video/Device" | grep "object.path" || true)
        if [ -n "$pw_sources" ]; then
            echo "$pw_sources" | sed 's/^[[:space:]]*/    /'
        else
            echo "    (none detected via PipeWire)"
        fi
    fi

    echo ""
    info "Log: $LOG_FILE"
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    info "═══════════════════════════════════════════"
    info "  Virtual Camera — Activate"
    info "═══════════════════════════════════════════"
    echo ""

    log "=== vcam-on.sh started ==="

    check_env
    echo ""

    # Step 1: Check if already active
    if strategy_already_active; then
        echo ""
        show_diagnostics
        echo ""
        start_feed
        echo ""
        log "Activation not needed — already active"
        info "Camera is ready! Launch 腾讯会议 from your app menu"
        return 0
    fi
    echo ""

    # Step 2: Try privilege escalation to load v4l2loopback
    if [ -n "$PRIV_TOOL" ]; then
        case "$PRIV_TOOL" in
            run0)   strategy_run0   ;;
            pkexec) strategy_pkexec ;;
            sudo)   strategy_sudo   ;;
        esac && {
            echo ""
            show_diagnostics
            echo ""
            start_feed
            echo ""
            log "Activation successful via $PRIV_TOOL"
            info "Virtual camera is ready! Launch 腾讯会议 from your app menu"
            return 0
        } || true
        echo ""
    fi

    # Step 3: If we couldn't activate, show diagnostics and recommendations
    echo ""
    fail "Could not activate virtual camera in this session."
    echo ""
    info "─── What to try ───"
    echo ""

    if [ "$IN_USERNS" = "1" ]; then
        info "1. Run this script OUTSIDE the sandbox/container:"
        info "     cd ~/virtualcamera && ./vcam-on.sh"
        echo ""
    fi

    info "2. Install v4l2loopback (if not already installed):"
    info "     sudo pacman -S v4l2loopback-dkms"
    info "     sudo modprobe v4l2loopback"
    echo ""

    info "3. Load the virtual camera module manually:"
    info "     run0 modprobe v4l2loopback devices=1 video_nr=$(find_free_video_nr) pixel_formats=NV12,YUYV"
    echo ""

    info "4. If sudo is broken (wrong ownership), fix it:"
    info "     run0 chown root:root /etc/sudo.conf"
    echo ""

    info "5. Install pipewire-v4l2 for userspace v4l2→PipeWire bridge:"
    info "     sudo pacman -S pipewire-v4l2"
    echo ""

    show_diagnostics
    log "Activation failed"
    return 1
}

main "$@"
