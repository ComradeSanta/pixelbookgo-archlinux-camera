#!/bin/sh
# imx208-auto-dgain.sh — keep the IMX208 exposure pinned at the anti-flicker
# point by adapting the sensor's digital_gain to the scene brightness.
#
# The anti-flicker tuning (imx208.yaml) pins exposure time at 10 ms
# (683 lines = exactly one 50 Hz mains cycle); the AGC then only varies
# analogue gain 1x..8x. That gives a fixed 8x-wide exposure window, scaled
# by digital_gain (which libcamera never touches):
#   dgain 0 (1x):  10..80 ms·x      dgain 2 (4x):  40..320 ms·x
#   dgain 1 (2x):  20..160 ms·x     dgain 3 (8x):  80..640 ms·x
# When the scene falls outside the window the AGC leaves the 10 ms pin and
# 50 Hz banding returns (rolling dark bands). These windows tile the whole
# brightness range, so there is always a dgain that re-pins the exposure —
# this watcher picks it: pinned-high (dark scene) -> dgain+1, unpinned-low
# (bright scene) -> dgain-1.
#
# Runs in the v4l2loopback-camera.service cgroup (ExecStartPost) and dies
# with the feed. Harmless when the sensor is idle (controls unreadable).

exec 9>/tmp/imx208-auto-dgain.lock
flock -n 9 || exit 0   # singleton: never two watchers fighting over dgain

PIN=683          # pinned exposure in sensor lines (10 ms)
HI=60            # hysteresis in lines
SETTLE_POLLS=3   # polls to wait after a dgain change

find_sensor() {
    for dev in /dev/v4l-subdev*; do
        [ -e "$dev" ] || continue
        if v4l2-ctl -d "$dev" --get-ctrl=digital_gain >/dev/null 2>&1; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

get() { v4l2-ctl -d "$SENSOR" --get-ctrl="$1" 2>/dev/null | awk '{print $2}'; }

SENSOR=""
warmup=3
settle=0

while sleep 0.7; do
    if [ -z "$SENSOR" ]; then
        SENSOR=$(find_sensor) || continue
    fi
    E=$(get exposure); G=$(get analogue_gain); D=$(get digital_gain)
    case "$E$G$D" in *[!0-9]*) SENSOR=""; continue;; esac   # sensor gone?
    [ -z "$E" ] && { SENSOR=""; continue; }

    if [ "$warmup" -gt 0 ]; then warmup=$((warmup-1)); continue; fi
    if [ "$settle" -gt 0 ]; then settle=$((settle-1)); continue; fi

    if [ "$E" -gt $((PIN+HI)) ] && [ "$D" -lt 4 ]; then
        # unpinned above the pin (dark scene): raise digital gain
        v4l2-ctl -d "$SENSOR" --set-ctrl=digital_gain=$((D+1)) 2>/dev/null
        settle=$SETTLE_POLLS
    elif [ "$E" -lt $((PIN-HI)) ] && [ "$G" -le 4 ] && [ "$D" -gt 0 ]; then
        # below the pin with analogue gain bottomed out (bright scene)
        v4l2-ctl -d "$SENSOR" --set-ctrl=digital_gain=$((D-1)) 2>/dev/null
        settle=$SETTLE_POLLS
    fi
done
