#!/usr/bin/env bash
# vcam-toggle.sh — Toggle the virtual camera feed on/off
# Part of the virtualcamera project
#
# Single-button workflow for people who do NOT want the camera always on
# (a running feed keeps the sensor active and its LED lit):
#   toggle on → use WeChat/Wemeet → toggle off.
#
# The v4l2loopback module stays loaded (harmless, no LED); only the feed
# (physical camera → /dev/video0) is started/stopped. Based on the earlier
# ~/.local/bin/camera-toggle.sh design, integrated with this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="v4l2loopback-camera.service"
GAIN_FIX="${HOME}/.local/bin/imx208-digital-gain-fix.sh"

notify() { command -v notify-send &>/dev/null && notify-send -i camera-web "$1" "$2" || true; }

has_vcam_device() {
    for dev in /dev/video*; do
        [ "$(cat /sys/class/video4linux/"$(basename "$dev")"/name 2>/dev/null || echo "")" = "Virtual Camera" ] && return 0
    done
    return 1
}

if systemctl --user is-active --quiet "$SERVICE" 2>/dev/null; then
    # ── TURN OFF ──
    systemctl --user stop "$SERVICE"
    systemctl --user restart wireplumber.service 2>/dev/null || true
    notify "虚拟摄像头已关闭" "相机指示灯应已熄灭"
else
    # ── TURN ON ──
    if ! has_vcam_device; then
        # Module not loaded (e.g. after vcam-off.sh) — full activation path
        exec "${SCRIPT_DIR}/vcam-on.sh"
    fi
    systemctl --user stop wireplumber.service 2>/dev/null || true
    # Fix IMX208 digital gain while the sensor is free (libcamera AGC
    # does not handle it; otherwise the image is too dark)
    [ -x "$GAIN_FIX" ] && "$GAIN_FIX" 2>/dev/null || true
    systemctl --user start "$SERVICE"
    sleep 2
    systemctl --user start wireplumber.service 2>/dev/null || true
    notify "虚拟摄像头已开启" "现在可以打开微信/腾讯会议"
fi
