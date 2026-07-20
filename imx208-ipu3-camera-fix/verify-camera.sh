#!/bin/bash
# verify-camera.sh — Confirm that the IMX208 + IPU3 camera is wired up end-to-end.
#
# Checks, in order:
#   1. Kernel modules loaded (ipu3_cio2, ipu3_imgu, imx208)
#   2. /dev/video* nodes exist and are accessible to the current user
#   3. libcamera enumerates the IMX208 sensor
#   4. PipeWire exposes a camera source node
#   5. (informational) User is in the `video` group
#
# Distro-agnostic: works on any Linux with libcamera + pipewire-libcamera
# installed. Exits 0 if all hard checks pass, 1 if any hard check fails.
# Soft checks (missing tools, not in video group) print warnings but do
# not affect the exit code.

set -u

PASS=0
FAIL=0
WARN=0
SKIPPED=0

# ANSI colors if stdout is a tty.
if [ -t 1 ]; then
    C_OK=$'\033[32m'
    C_FAIL=$'\033[31m'
    C_WARN=$'\033[33m'
    C_INFO=$'\033[36m'
    C_OFF=$'\033[0m'
else
    C_OK="" C_FAIL="" C_WARN="" C_INFO="" C_OFF=""
fi

ok()   { echo "${C_OK}[ OK ]${C_OFF} $*"; PASS=$((PASS+1)); }
fail() { echo "${C_FAIL}[FAIL]${C_OFF} $*"; FAIL=$((FAIL+1)); }
warn() { echo "${C_WARN}[WARN]${C_OFF} $*"; WARN=$((WARN+1)); }
info() { echo "${C_INFO}[INFO]${C_OFF} $*"; }
skip() { echo "[SKIP] $*"; SKIPPED=$((SKIPPED+1)); }

have() { command -v "$1" >/dev/null 2>&1; }

echo "=== IMX208 + IPU3 camera verification ==="
echo

# 1. Kernel modules
echo "--- Kernel modules ---"
for mod in ipu3_cio2 ipu3_imgu imx208; do
    if lsmod 2>/dev/null | grep -qw "$mod"; then
        ok "module $mod loaded"
    elif [ -d "/sys/module/$mod" ]; then
        ok "module $mod present (built-in or loaded)"
    else
        fail "module $mod not loaded"
    fi
done

# 2. /dev/video* nodes
echo
echo "--- Device nodes ---"
if compgen -G "/dev/video*" > /dev/null; then
    n=$(ls /dev/video* 2>/dev/null | wc -l)
    ok "/dev/video* exists ($n node(s))"
    if [ -r /dev/video0 ] 2>/dev/null; then
        ok "/dev/video0 is readable by current user (logind uaccess active)"
    else
        warn "/dev/video0 is not readable by current user"
        info "  -> If you're on a graphical seat, this usually means"
        info "     logind uaccess hasn't granted the active seat yet."
        info "     Try re-logging in or running from the active session."
    fi
else
    fail "no /dev/video* nodes found"
fi

# 3. libcamera enumeration
echo
echo "--- libcamera ---"
if have cam; then
    cam_out=$(cam -l 2>&1)
    # cam -l prints startup logs (warnings, errors) before the final
    # "Available cameras:" section. Extract just that section for
    # the [ OK ] case so the output stays readable. For the [FAIL]
    # case, dump the full output so the user can diagnose.
    cam_list=$(echo "$cam_out" | awk '/^Available cameras:/{flag=1; print; next} flag{print}')
    if echo "$cam_out" | grep -qi 'imx208'; then
        ok "cam -l sees IMX208:"
        echo "$cam_list" | sed 's/^/        /'
    else
        fail "cam -l does not list IMX208"
        info "  -> cam -l output:"
        echo "$cam_out" | sed 's/^/        /'
        info "  -> This means the libcamera IMX208 patch is not active."
        info "     On Arch: rebuild libcamera with the PKGBUILD in arch/libcamera/."
    fi
else
    skip "cam (libcamera-tools) not installed; cannot check libcamera enumeration"
fi

# 4. PipeWire
echo
echo "--- PipeWire ---"
if have wpctl; then
    wp_out=$(wpctl status 2>&1)
    if echo "$wp_out" | grep -qi 'imx208'; then
        ok "wpctl status shows IMX208 as a PipeWire node"
    else
        # Not necessarily fatal — the camera might be in a non-default
        # video category. Try pw-cli as a fallback.
        if have pw-cli; then
            pw_out=$(pw-cli ls Node 2>&1)
            if echo "$pw_out" | grep -qi 'imx208'; then
                ok "pw-cli ls Node shows IMX208 (visible to PipeWire)"
                warn "wpctl status did not show it — it may be in a hidden category"
            else
                fail "PipeWire does not expose IMX208 as a node"
                info "  -> Restart the user session: systemctl --user restart wireplumber pipewire"
            fi
        else
            fail "wpctl status does not mention IMX208, and pw-cli is missing"
            info "  -> Restart the user session: systemctl --user restart wireplumber pipewire"
        fi
    fi
elif have pw-cli; then
    if pw-cli ls Node 2>/dev/null | grep -qi 'imx208'; then
        ok "pw-cli ls Node shows IMX208 (wpctl not installed)"
    else
        fail "PipeWire does not expose IMX208 as a node"
    fi
else
    skip "neither wpctl nor pw-cli available; cannot check PipeWire"
fi

# 5. video group (informational)
echo
echo "--- User session ---"
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx video; then
    ok "user $(id -un) is in the 'video' group"
else
    warn "user $(id -un) is NOT in the 'video' group"
    info "  -> This is fine on a graphical seat (logind uaccess covers it)."
    info "     Required for headless / SSH / no active seat:"
    info "       sudo usermod -aG video $(id -un)"
    info "     (takes effect on next login)"
fi

# Summary
echo
echo "=== Summary ==="
echo "  pass: $PASS"
echo "  fail: $FAIL"
echo "  warn: $WARN"
echo "  skip: $SKIPPED"

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "${C_FAIL}Camera is NOT fully wired up. See the [FAIL] lines above.${C_OFF}"
    exit 1
fi

echo
echo "${C_OK}Camera verification passed.${C_OFF}"
exit 0
