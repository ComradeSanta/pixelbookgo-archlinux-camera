# IMX208 + Intel IPU3 camera fix for Linux

A set of patches that make the built-in webcam work on laptops and tablets
using the **Sony IMX208** sensor behind an **Intel IPU3** Image Signal
Processor — including the **Google Pixelbook Go (2019)**, some Microsoft
Surface tablets, and a handful of older Dell XPS models.

Without these patches, libcamera refuses to initialize the sensor and the
camera simply does not appear in any app:

```
ERROR IPAIPU3 ipu3.cpp:306 Failed to create camera sensor helper for imx208
ERROR IPU3    ipu3.cpp:1194 Failed to initialise the IPU3 IPA
```

## What this repo contains

| File | Purpose |
|---|---|
| `libcamera-add-imx208-helper.patch` | Registers the IMX208 sensor helper and properties in libcamera. **This is the one required for the camera to show up at all.** |
| `kernel-imx208-add-get_selection.patch` | Adds the V4L2 `get_selection` pad op to the kernel IMX208 driver. **Optional** — silences `Unable to get rectangle` warnings, may not apply cleanly to every kernel version. |
| `build-and-install-libcamera.sh` | Original Fedora build script (kept for reference). |
| `override-libcamera.sh` | Original Fedora library-override script (kept for reference). |
| `README-IMX208-修复指南.md` | Original Chinese-language install guide (kept for reference). |
| `verify-camera.sh` | Cross-distro end-to-end check: kernel modules, `/dev/video*`, libcamera enumeration, PipeWire node visibility. Run this after installing to confirm everything is wired up. |
| `arch/libcamera/PKGBUILD` | Arch Linux packaging for a patched `libcamera` 0.7.1. Build with `makepkg -si` from inside that directory. |

## Quick start — Arch Linux

```bash
git clone https://github.com/<your-fork>/imx208-ipu3-camera-fix.git
cd imx208-ipu3-camera-fix/arch/libcamera
makepkg -si
sudo systemctl --user restart wireplumber pipewire   # pick up the new SPA plugin
../verify-camera.sh
```

`verify-camera.sh` should report all `[ OK ]` lines and exit 0. If it
exits non-zero, see [Troubleshooting](#troubleshooting) below.

## Quick start — Fedora / RPM-based

Use `build-and-install-libcamera.sh` (the script in this repo), then the
original `README-IMX208-修复指南.md` (in this repo, in Chinese) for
manual build instructions. The `libcamera-add-imx208-helper.patch` in
this repo applies cleanly to libcamera 0.7.1 — `patch -p1` from inside
the libcamera source tree:

```bash
cd /path/to/libcamera-0.7.1
patch -p1 < /path/to/this/repo/libcamera-add-imx208-helper.patch
# then build per the original Chinese guide
```

## Quick start — other distros

`verify-camera.sh` works on any distro — run it first to see which
layers (kernel, libcamera, PipeWire) are already in place. The
`libcamera-add-imx208-helper.patch` applies to upstream libcamera
0.7.1; for other versions you may need to adjust the line numbers or
class names.

If your distro ships libcamera ≥ 0.8 with a different helper layout,
the patch may not apply — check the libcamera 0.7.1 → current
migration notes and adapt.

## What the libcamera patch does

The patch adds two small entries to libcamera's built-in database:

1. **`CameraSensorHelperImx208`** in `src/ipa/libipa/camera_sensor_helper.cpp` —
   a 9-line class that tells the IPU3 IPA how to convert between
   libcamera's gain model and the IMX208's register layout. The model
   (`AnalogueGainLinear{ 0, 256, -1, 256 }`) is copied from IMX219
   because both use the same Sony gain register (0x0204). The actual
   IMX208 gain register range is [0, 224] per its datasheet, so the
   linear-gain assumption is approximate — tune with real measurements
   if exposure looks off.

2. **IMX208 properties entry** in `src/libcamera/sensor/camera_sensor_properties.cpp` —
   a 16-line entry with the pixel cell size (1.12 µm), standard
   test-pattern modes, and conservative sensor-delay defaults (2
   frames for exposure / gain / vblank / hblank). Without this entry
   libcamera falls back to unspecified values, which is why the
   patch is needed even after the helper is registered.

This is upstream as Patchwork message
`20250406191549.13225-1-peter.lishov@gmail.com` (Peter Lishov, April
2025), in **"Changes Requested"** state — not yet merged.

## Caveats — what this fix does NOT do

- **No calibration.** libcamera still falls back to
  `/usr/share/libcamera/ipa/ipu3/uncalibrated.yaml` because no
  `imx208.yaml` tuning file exists yet. Color, white balance, and
  exposure will be off compared to a real Windows/ChromeOS image. To
  fix this, generate a tuning file with `lc-compliance` against a
  calibration target — out of scope for this repo.

- **Gain model is approximate.** See the helper comment above; the
  linear-gain assumption works in practice but is mathematically
  wrong for the IMX208's actual register range.

- **Kernel patch is optional.** The Pixelbook Go's mainline
  `imx208` driver lacks `get_selection`, so libcamera prints
  warnings like `Unable to get rectangle 0 on pad 0/0: Inappropriate
  ioctl` and falls back to a 1936×1096 full-area crop. The camera
  works around this; the warnings are cosmetic. The bundled
  `kernel-imx208-add-get_selection.patch` would silence them, but
  it is best-effort: the hunk offsets were computed against a
  single kernel version and may not match yours.

## Verification

`./verify-camera.sh` checks every layer end-to-end. The script is
non-destructive — it only reads kernel/sysfs state and runs read-only
PipeWire/libcamera introspection commands. Safe to run any time.

After a working install, a healthy run looks like:

```
--- Kernel modules ---
[ OK ] module ipu3_cio2 loaded
[ OK ] module ipu3_imgu loaded
[ OK ] module imx208 loaded

--- Device nodes ---
[ OK ] /dev/video* exists (14 node(s))
[ OK ] /dev/video0 is readable by current user (logind uaccess active)

--- libcamera ---
[ OK ] cam -l sees IMX208:
        Available cameras:
        1: 'imx208' (\_SB_.PCI0.I2C3.CAM0)

--- PipeWire ---
[ OK ] wpctl status shows IMX208 as a PipeWire node

=== Summary ===
  pass: 7
  fail: 0

Camera verification passed.
```

## Troubleshooting

### `cam -l` does not list IMX208

The libcamera patch is not active in your running build.

- **Arch:** rebuild via `arch/libcamera/PKGBUILD` (see Quick start).
  If you have the upstream Arch `libcamera` package installed, add the
  seven `libcamera*` packages to `IgnorePkg` in `/etc/pacman.conf`
  **before** installing the rebuilt ones, so `pacman -Syu` doesn't
  clobber them on the next upgrade. The seven packages are
  `libcamera`, `libcamera-ipa`, `libcamera-tools`, `libcamera-debug`,
  `libcamera-docs`, `gst-plugin-libcamera`, `python-libcamera`.

- **Fedora / other:** the running libcamera on `LD_LIBRARY_PATH` is
  older than the freshly built one, or the build failed and the
  backup `libcamera.so.0.7.bak.*` got restored. Check
  `ldd $(which cam)` shows the patched library path.

### `wpctl status` does not show IMX208

`pipewire-libcamera` is not installed, or the WirePlumber session
was not restarted after install.

```bash
sudo pacman -S --needed pipewire-libcamera    # Arch
sudo dnf install pipewire-plugin-libcamera    # Fedora
systemctl --user restart wireplumber pipewire
```

### The camera works in `cam -l` but a specific app does not see it

Most camera apps use V4L2 directly and will not see the IPU3 sensor
without libcamera wrapping. Use a libcamera-native app:

- `snapshot` (GNOME, libcamera-native) — recommended
- `libcamerify <app>` (wraps a V4L2 app to use libcamera)

### Picture looks wrong (color off, exposure wrong, etc.)

Expected — see **Caveats** above. This is the uncalibrated
`uncalibrated.yaml` fallback. A proper IPU3 tuning file for the IMX208
would fix it but is out of scope.

## Attributions and history

- Original IMX208 Patchwork patch: **Peter Lishov**, libcamera mailing
  list, April 2025 (`20250406191549.13225-1-peter.lishov@gmail.com`).
- Original Fedora-focused build script and Chinese install guide:
  **Mason Zhang** — see `mason-yb-zhang/pixelbook-go-2019-imx208-camera-fix`
  on GitHub. This repo is a fork of Mason's.
- This fork adds the Arch Linux PKGBUILD, the cross-distro
  verification script, fixes the original libcamera patch's malformed
  unified-diff syntax, and adds an English-language README. Mason's
  original `libcamera-add-imx208-helper.patch` was an LLM-generated
  diff with broken `+` prefixes that `patch -p1` refused to apply
  (the patch content was correct, only the diff syntax was broken);
  see commit `6f3d57f` for details.

## See also

- `README-IMX208-修复指南.md` — original Chinese-language install guide
- `arch/libcamera/PKGBUILD` — Arch Linux build
- `verify-camera.sh` — end-to-end verification
- [libcamera source](https://git.libcamera.org/libcamera/libcamera.git/)
- [Linux kernel imx208.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/i2c/imx208.c)
