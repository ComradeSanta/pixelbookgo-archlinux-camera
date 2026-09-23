#!/bin/sh
# Set IMX208 digital gain to 2x to compensate for low analog gain
# (libcamera IPU3 AGC doesn't control digital_gain, so we do it manually).
#
# Why 2x: the anti-flicker tuning (imx208.yaml) pins exposure time at 10 ms.
# With digital gain at 8x the AGC wanted <10 ms exposure indoors, leaving the
# pinned range and re-introducing 50 Hz flicker. 2x keeps typical indoor
# scenes inside the pinned window (10 ms x analog 1-8x) with headroom both
# ways. If your room is very dim, raise this to 2 (4x).
#
# This script is called by systemd (imx208-dgain.service) at login and by
# vcam-toggle.sh whenever the feed starts.

# Find IMX208 by checking for the digital_gain control
for dev in /dev/v4l-subdev*; do
    [ -e "$dev" ] || continue
    if v4l2-ctl -d "$dev" --get-ctrl=digital_gain >/dev/null 2>&1; then
        v4l2-ctl -d "$dev" --set-ctrl=digital_gain=1 2>/dev/null
        exit 0
    fi
done

echo "imx208 sensor not found or not powered"
exit 1
