#!/bin/sh
# Install to /usr/lib/systemd/system-sleep/imx208-dgain.sh
# Re-applies digital gain after suspend/resume.
case "$1" in
    post)
        for i in $(seq 1 20); do
            SENSOR=$(media-ctl -p 2>/dev/null | grep -A2 "imx208" | grep "device node" | awk '{print $NF}')
            if [ -n "$SENSOR" ]; then
                v4l2-ctl -d "$SENSOR" --set-ctrl=digital_gain=3 2>/dev/null && break
            fi
            sleep 0.3
        done
        ;;
esac
