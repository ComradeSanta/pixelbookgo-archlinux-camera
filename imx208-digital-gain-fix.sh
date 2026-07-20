#!/bin/sh
# Set IMX208 digital gain to 8x to compensate for low analog gain
# libcamera IPU3 AGC doesn't control digital_gain, so we do it manually.
# This script is called by udev/systemd whenever the sensor powers up.

# Find IMX208 by checking for the digital_gain control
for dev in /dev/v4l-subdev*; do
    [ -e "$dev" ] || continue
    if v4l2-ctl -d "$dev" --get-ctrl=digital_gain >/dev/null 2>&1; then
        v4l2-ctl -d "$dev" --set-ctrl=digital_gain=3 2>/dev/null
        exit 0
    fi
done

echo "imx208 sensor not found or not powered"
exit 1
