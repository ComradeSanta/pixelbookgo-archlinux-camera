#!/bin/sh
# apply-v4l2loopback-patch.sh — apply the shared-capture patch to the
# v4l2loopback DKMS source and rebuild the module for all installed kernels.
#
# Idempotent: safe to run repeatedly (e.g. from the pacman hook that fires
# every time the v4l2loopback-dkms package is reinstalled/upgraded, which
# restores the pristine source and would otherwise silently drop the patch).
#
# Usage: sudo ./apply-v4l2loopback-patch.sh
set -e

SRC=$(ls -d /usr/src/v4l2loopback-* 2>/dev/null | sort -V | tail -1)
[ -n "$SRC" ] || { echo "no v4l2loopback source in /usr/src"; exit 1; }
VER=${SRC##*/v4l2loopback-}
PATCH="$(cd "$(dirname "$0")" && pwd)/v4l2loopback-shared-capture.patch"

if grep -q producer_streaming "$SRC/v4l2loopback.c"; then
    echo "patch already applied in $SRC — skipping patch step"
else
    (cd "$SRC" && patch -p1 < "$PATCH")
    echo "patched $SRC/v4l2loopback.c"
fi

# Force-rebuild for every installed kernel: DKMS considers the module
# "already installed" otherwise and keeps the old (unpatched) binaries.
for k in $(ls /usr/lib/modules); do
    dkms build "v4l2loopback/$VER" -k "$k" --force
    dkms install "v4l2loopback/$VER" -k "$k" --force
done
echo "done. Reload with: modprobe -r v4l2loopback && modprobe v4l2loopback"
