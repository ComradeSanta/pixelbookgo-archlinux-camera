#!/bin/sh
# Set IMX208 digital gain to 8x
# libcamera's IPU3 AGC doesn't control digital_gain, leaving it at 1x.
# The IMX208's analog gain maxes out at only ~2x real gain — too low for
# indoor use.  We compensate by pushing digital gain to 8x.
#
# This script is called by the systemd service (boot/login) and the
# sleep hook (resume from suspend).  It tolerates the sensor not yet
# being powered: polls every 0.3s for up to 6s.

SENSOR=""
for n in 0 1 2 3 4 5 6 7 8; do
    dev="/dev/v4l-subdev$n"
    [ -e "$dev" ] || continue
    if media-ctl -p 2>/dev/null | grep -A2 "imx208" | grep -q "$dev"; then
        SENSOR="$dev"
        break
    fi
done

if [ -z "$SENSOR" ]; then
    echo "imx208 sensor not found"
    exit 1
fi

for i in $(seq 1 20); do
    if v4l2-ctl -d "$SENSOR" --get-ctrl=digital_gain >/dev/null 2>&1; then
        v4l2-ctl -d "$SENSOR" --set-ctrl=digital_gain=3 2>/dev/null
        exit 0
    fi
    sleep 0.3
done

exit 1
