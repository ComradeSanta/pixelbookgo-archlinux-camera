# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

Complete camera solution for the **Google Pixelbook Go (Atlas)** on Arch Linux, in three layers: (1) patched libcamera so the IMX208/IPU3 sensor works at all (`imx208-ipu3-camera-fix/`), (2) tuning + digital-gain so the picture looks right (`imx208-camera-color-fix/`), and (3) a v4l2loopback virtual camera with a live feed so WeChat and Tencent Meeting can use it (repo root). The root README.md is the full guide; this file documents the virtual-camera tooling.

## Scripts

- **`vcam-toggle.sh`** — Daily-use on/off switch for the camera **feed** (the module stays loaded; only the feed is toggled, because a running feed keeps the sensor streaming and its LED lit). Drives the `v4l2loopback-camera.service` systemd user service, applies `~/.local/bin/imx208-digital-gain-fix.sh` before start, cycles wireplumber so PipeWire releases/re-enumerates the device, and notifies via notify-send. Backed by `vcam-toggle.desktop`.
- **`vcam-on.sh`** — Activates virtual camera + starts camera feed. Checks if v4l2loopback Virtual Camera is already present (via sysfs name, not just any `/dev/video*`), then tries `run0` → `pkexec` → `sudo` to `modprobe v4l2loopback`. Dynamic video_nr detection (max existing + 1) avoids conflicts with hardware devices. Starts the feed via the `v4l2loopback-camera.service` (preferred) or `vcam-feed.sh start` (fallback).
- **`vcam-off.sh`** — Stops camera feed (service and/or vcam-feed.sh), then unloads the v4l2loopback module via run0/pkexec/sudo.
- **`vcam-feed.sh {start|stop|status}`** — Fallback feed daemon (the systemd user service `v4l2loopback-camera.service` running `~/.local/bin/v4l2loopback-gst.sh` is the canonical feed; the service is **disabled** at login by design so the LED stays off until the user toggles on). Pipes real video from the hardware camera into the v4l2loopback sink via gstreamer (prefers `libcamerasrc` for IPU3, falls back to `v4l2src` on the IMGU output node, then `videotestsrc`). Converts to YUY2 before the sink because wemeet's TRTC engine requests YUYV and v4l2loopback does not convert between formats. Stores PID in `vcam-feed.pid`. Configurable via `VCAM_WIDTH`, `VCAM_HEIGHT`, `VCAM_FPS`, `VCAM_SOURCE` env vars. Defaults to 1280×720@30fps (wemeet's TRTC capture hard-targets 1280×720 and does not tolerate the driver coercing a different size — feeding anything else leaves wemeet with a black screen).
- **`wemeet.sh`** — Checks for Virtual Camera (sysfs name), auto-runs vcam-on.sh if missing, LD_PRELOADs `wemeet-v4l2fix.so`, then `exec wemeet "$@"`. The stock desktop entry is overridden at user level (`~/.local/share/applications/wemeetapp.desktop` shadows `/usr/share/applications/wemeetapp.desktop`) with `Exec=env LD_PRELOAD=.../wemeet-v4l2fix.so /opt/wemeet/wemeetapp.sh %u` — the normal icon runs Tencent's original launcher and only adds the shim (user preference); `wemeet.sh` remains for terminal use.
- **`wemeet-v4l2fix.c` / `.so`** — LD_PRELOAD shim required for wemeet. Its TRTC engine sends per-frame DQBUF/QBUF with `v4l2_buffer.memory = 0` (setup calls use MMAP correctly); v4l2loopback's `vidioc_dqbuf`/`vidioc_qbuf` reject `memory != V4L2_MEMORY_MMAP` with EINVAL, so TRTC loops on `camera.is.busy` ~30×/s and shows black. The shim rewrites `memory` to `V4L2_MEMORY_MMAP` for `/dev/video*` fds. Without it wemeet's camera is always black with v4l2loopback. Set `WEMEET_V4L2FIX_LOG=/path/log` to trace fixups. Rebuild: `gcc -O2 -shared -fPIC -o wemeet-v4l2fix.so wemeet-v4l2fix.c -ldl`.
- **`wechat.sh`** — Same pattern for WeChat. Tries `wechat`, `wechat-bin`, flatpak, and `/opt` paths.
- **`install-desktop.sh`** — Symlinks `vcam-toggle.desktop`, `vcam-on.desktop`, `vcam-off.desktop` into `~/.local/share/applications/`.
- **`v4l2loopback-shared-capture.patch`** — Kernel driver patch for `/usr/src/v4l2loopback-0.15.4` (apply + `dkms build/install --force`). v4l2loopback 0.15's token model allows only ONE capture-side owner: apps that probe on one fd and capture on another (guvcview) get EBUSY, and two apps can't share the camera. The patch lets extra CAPTURE consumers proceed tokenless while a producer streams (S_FMT/REQBUFS/STREAMON/DQBUF/poll/read gates), and lets consumers map the whole allocated pool (max_buffers) instead of clamping to the producer's count. Survives kernel updates via DKMS; lost only if the `v4l2loopback-dkms` package is reinstalled — re-apply then.
- **`v4l2loopback-gst.sh`** — The canonical feed pipeline (installs to `~/.local/bin/`, run by the service).
- **`systemd/v4l2loopback-camera.service`** — User unit for the feed; deliberately not enabled (LED stays off until toggled).
- **`wireplumber/51-disable-libcamera.conf`** — Disables PipeWire's libcamera monitor: `libspa-libcamera` SEGVs on the IMX208 in a loop and takes gnome-shell down (looks like a shutdown). Without it the physical camera is reachable only via the gstreamer feed; PipeWire still sees the loopback via V4L2.
- **`imx208-digital-gain-fix.sh`** — Sets IMX208 `digital_gain=3` (installs to `~/.local/bin/`; called by the toggle before the feed starts).

## Camera detection: sysfs names, not lsmod

Inside user namespaces, `lsmod` may not show kernel modules. All scripts detect the virtual camera by scanning `/sys/class/video4linux/*/name` for the exact string `"Virtual Camera"`. Never use `ls /dev/video*` alone to determine if the vcam is active — hardware devices (ipu3-imgu, ipu3-cio2) are always present.

## Video pipeline

```
Hardware camera (IMX208) → CIO2 (raw Bayer) → IMGU input → IMGU output (NV12)
→ gstreamer (libcamerasrc or v4l2src) → videoconvert → YUY2 1280×720@30
→ v4l2loopback sink → /dev/videoXX
→ Apps (wemeet, wechat) read YUYV from v4l2loopback capture side
```

The v4l2loopback module is loaded with `exclusive_caps=0`, `max_buffers=8` and `pixel_formats=NV12,YUYV` so the device accepts the YUYV feed that wemeet's TRTC engine requires. Once a producer is streaming, the driver locks the device format to the producer's — consumers asking for another size get silently coerced, which breaks wemeet (its TRTC engine targets 1280×720 and spins on `camera.is.busy` when the delivered size differs). Keep the feed at 1280×720@30.

## Privilege escalation ordering

`run0` (polkit GUI prompt) → `pkexec` → `sudo`. Don't reorder. `run0` is the most user-friendly on modern systemd desktops.

## Desktop entries

All use hardcoded paths under `/home/arch/virtualcamera/`. `vcam-on.desktop` and `vcam-off.desktop` open a terminal; `wemeet-vcam.desktop` registers `x-scheme-handler/wemeet` MIME type; `wechat-vcam.desktop` uses `Icon=wechat`.

## Logging

All scripts append timestamped lines to `vcam.log`. Feed gstreamer output also goes to `vcam.log`. PID file at `vcam-feed.pid`.

## reasonix.toml

Configuration for the Reasonix AI agent harness (not the virtual camera project itself). Sandboxing, permissions, LSP, and model settings for the agent operating in this directory.
