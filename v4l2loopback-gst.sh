#!/bin/sh
# Launch GStreamer pipeline from libcamera → v4l2loopback
# Auto-detects the v4l2loopback device by card label

VDEV=$(v4l2-ctl --list-devices 2>/dev/null | grep -A1 "Virtual Camera" | tail -1 | tr -d '\t ')

if [ -z "$VDEV" ]; then
    echo "v4l2loopback device not found. Is the module loaded?"
    exit 1
fi

exec gst-launch-1.0 libcamerasrc camera-name="\\\\_SB_.PCI0.I2C3.CAM0" \
    ! "video/x-raw,format=NV12,width=1280,height=720,framerate=30/1" \
    ! queue max-size-buffers=3 \
    ! videoconvert \
    ! videobalance contrast=1.1 saturation=1.6 \
    ! "video/x-raw,format=YUY2" \
    ! v4l2sink device="$VDEV"
