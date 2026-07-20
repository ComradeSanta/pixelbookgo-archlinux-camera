# Pixelbook Go + Arch Linux — Complete Camera Guide

Everything needed to make the **Google Pixelbook Go (Atlas, 2019)** camera work
on a fresh **Arch Linux** install: the built-in IMX208 sensor, correct colors,
and a virtual camera that WeChat and Tencent Meeting (wemeet) accept.

The work is split into three independent layers. Each has its own folder with
details and its own README:

| Layer | Folder | What it fixes |
|-------|--------|---------------|
| 1. Sensor enablement | [`imx208-ipu3-camera-fix/`](imx208-ipu3-camera-fix/) | Camera does not exist at all |
| 2. Image quality | [`imx208-camera-color-fix/`](imx208-camera-color-fix/) | Picture almost black / wrong colors |
| 3. Virtual camera | *(this repo, root)* | WeChat / wemeet can't use the IPU3 camera |

Plus the hard-won app-compatibility knowledge in [§6](#6-app-compatibility--daily-workflow).

---

## 0. Why the camera is broken out of the box

The Pixelbook Go has a **Sony IMX208** sensor behind an **Intel IPU3** ISP.
Out of the box on Arch:

1. **libcamera refuses to initialize the sensor** — no IMX208 sensor-helper or
   properties entry exists upstream, so `cam -l` shows nothing and no app sees
   a camera. (The kernel `imx208`/`ipu3_*` modules themselves load fine.)
2. With the sensor registered, the picture is **nearly black with wrong
   colors** — the IPU3 IPA falls back to an empty `uncalibrated.yaml`, and
   libcamera's AGC never touches the IMX208's `digital_gain` register.
3. Most video-call apps (**WeChat, wemeet**) can't use the IPU3 camera anyway:
   they only understand plain UVC-style `/dev/video*` devices, so a
   **v4l2loopback** virtual camera fed by the real sensor is required — and
   wemeet additionally trips over quirks in v4l2loopback ≥ 0.13 that other
   apps tolerate (see §5).

## 1. Part 1 — make the camera exist (libcamera patch)

Patches libcamera 0.7.1 with the IMX208 sensor helper + properties
(from Peter Lishov's upstream patchwork submission, build-fixed).

```bash
cd imx208-ipu3-camera-fix/arch/libcamera
makepkg -si          # builds and installs the patched libcamera 0.7.1
../../imx208-ipu3-camera-fix/verify-camera.sh   # or: ../verify-camera.sh from inside arch/libcamera
```

`verify-camera.sh` should print all `[ OK ]` and exit 0.

**Important:** tell pacman not to clobber the patched libcamera on upgrades.
Add to `/etc/pacman.conf`:

```
IgnorePkg = libcamera libcamera-ipa libcamera-tools libcamera-debug libcamera-docs gst-plugin-libcamera python-libcamera
```

Details and Fedora/other-distro instructions:
[`imx208-ipu3-camera-fix/README.md`](imx208-ipu3-camera-fix/README.md).

## 2. Part 2 — fix the picture (tuning + digital gain)

The `imx208.yaml` IPA tuning file plus a script that pushes the sensor's
`digital_gain` to 8× (libcamera's AGC doesn't control it).

```bash
cd imx208-camera-color-fix
sudo ./install.sh
```

This installs the tuning file, a user systemd service (`imx208-dgain.service`)
and a suspend/resume hook. Verify:

```bash
cam -c1 -I 2>&1 | grep "Using tuning file"   # .../ipa/ipu3/imx208.yaml
```

Details (Chinese): [`imx208-camera-color-fix/README.md`](imx208-camera-color-fix/README.md).

## 3. Part 3 — virtual camera for WeChat / Tencent Meeting

Apps like WeChat and wemeet read plain `/dev/video*` devices, so we run a
gstreamer feed from the real sensor into a v4l2loopback device.

### 3.1 Install and patch v4l2loopback

```bash
sudo pacman -S v4l2loopback-dkms gstreamer gst-plugins-good gst-plugin-libcamera
```

v4l2loopback 0.15 allows only **one** capture-side owner per device, which
breaks real-world usage (an app that probes the camera on one fd and captures
on another gets `EBUSY`; two apps can't share the camera). This repo ships
[`v4l2loopback-shared-capture.patch`](v4l2loopback-shared-capture.patch) which
relaxes the token gates so multiple capture consumers can read the same feed,
and lets consumers map the whole buffer pool:

```bash
cd /usr/src/v4l2loopback-0.15.4
sudo patch -p1 < /path/to/this/repo/v4l2loopback-shared-capture.patch
sudo dkms build v4l2loopback/0.15.4 -k "$(uname -r)" --force
sudo dkms install v4l2loopback/0.15.4 -k "$(uname -r)" --force
```

DKMS keeps the patched source in `/usr/src`, so **the patch survives kernel
updates automatically**. It is only lost if the `v4l2loopback-dkms` package
itself is reinstalled/upgraded — then re-apply the two commands above.

### 3.2 Load the module at boot

```bash
echo v4l2loopback | sudo tee /etc/modules-load.d/v4l2loopback.conf
echo 'options v4l2loopback devices=1 card_label="Virtual Camera" exclusive_caps=0 max_buffers=8' \
  | sudo tee /etc/modprobe.d/v4l2loopback.conf
sudo modprobe v4l2loopback && sudo chmod 666 /dev/video0
```

(The `pixel_formats=NV12,YUYV` option seen in older guides no longer exists in
0.15.x — passing it is harmless but ignored.)

### 3.3 Install the feed service

The feed pipes the real sensor (1280×720 NV12) through `videoconvert` to
**YUYV 1280×720@30** — the one format wemeet's TRTC engine reliably accepts.

```bash
cp v4l2loopback-gst.sh ~/.local/bin/ && chmod +x ~/.local/bin/v4l2loopback-gst.sh
cp imx208-digital-gain-fix.sh ~/.local/bin/ && chmod +x ~/.local/bin/imx208-digital-gain-fix.sh
cp systemd/v4l2loopback-camera.service ~/.config/systemd/user/
systemctl --user daemon-reload
# Deliberately NOT enabled: a running feed keeps the sensor (and its LED) on.
# Start/stop it with vcam-toggle.sh / the "Toggle Virtual Camera" menu entry.
```

### 3.4 WirePlumber stability fix (required!)

PipeWire's libcamera plugin (`libspa-libcamera`) **segfaults on the IMX208**,
crash-loops wireplumber, and takes gnome-shell down with it (looks like a
shutdown — you land back at the GDM login screen). Disable it — the physical
camera is used via the gstreamer feed instead:

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d
cp wireplumber/51-disable-libcamera.conf ~/.config/wireplumber/wireplumber.conf.d/
systemctl --user restart wireplumber
```

### 3.5 The wemeet shim (required for Tencent Meeting)

wemeet's TRTC engine sends per-frame `DQBUF`/`QBUF` with
`v4l2_buffer.memory = 0`; v4l2loopback rejects anything but
`V4L2_MEMORY_MMAP` with `EINVAL`, and the camera stays black while other apps
work. [`wemeet-v4l2fix.c`](wemeet-v4l2fix.c) is an `LD_PRELOAD` shim that
rewrites the field:

```bash
gcc -O2 -shared -fPIC -o wemeet-v4l2fix.so wemeet-v4l2fix.c -ldl
```

`wemeet.sh` preloads it automatically. The stock 腾讯会议 menu entry is
overridden at user level (`~/.local/share/applications/wemeetapp.desktop`)
with `Exec=env LD_PRELOAD=...wemeet-v4l2fix.so /opt/wemeet/wemeetapp.sh %u`
so the normal icon gets the fix — no separate shortcut.

## 4. Shortcuts and daily use

```bash
./install-desktop.sh    # menu entries: Toggle / Enable / Disable Virtual Camera
```

Daily flow:

1. **开关虚拟摄像头 (Toggle Virtual Camera)** → feed starts, LED lights
   (also applies the digital-gain fix and cycles wireplumber)
2. Open WeChat / 腾讯会议 / any camera app
3. Toggle again to turn it off — LED goes out

`vcam-on.sh` / `vcam-off.sh` (module load/unload + diagnostics) remain as the
full-control variants. `wemeet.sh` / `wechat.sh` are optional wrappers that
warn you (GUI notification) if you forgot to toggle the feed on.

## 5. How it works (architecture)

```
IMX208 ──CIO2──> IPU3 IMGU ──NV12──> libcamera (patched, tuned imx208.yaml + dgain)
                                        │
             gstreamer: libcamerasrc → videoconvert → YUY2 1280×720@30
                                        ▼
                          v4l2loopback (patched) /dev/videoN
                          "Virtual Camera"
                    ┌───────┼──────────────┬─────────────┐
                 WeChat   wemeet        guvcview      Chrome, mpv…
                 (v4l2)  (+LD_PRELOAD   (v4l2)
                          wemeet-v4l2fix)
```

Three pieces had to be fixed at different levels; all three are in this repo:

- **driver** (`v4l2loopback-shared-capture.patch`) — multiple apps can consume
  one loopback; consumers can map the whole buffer pool
- **userspace shim** (`wemeet-v4l2fix.so`) — wemeet's `memory=0` bug
- **feed** (`v4l2loopback-gst.sh`) — YUYV 1280×720@30, the format wemeet wants

## 6. App compatibility & daily workflow

| App | Works? | Notes |
|-----|--------|-------|
| WeChat | ✅ | reads `/dev/videoN` directly; nothing special needed |
| Tencent Meeting (wemeet) | ✅ | only via the `LD_PRELOAD` shim (built into `wemeet.sh` and the stock icon override) |
| guvcview | ✅ | direct V4L2; install `guvcview`. Takes photos/videos |
| Chrome/Chromium | ✅ | uses V4L2 directly |
| mpv/ffplay | ✅ | `mpv av://v4l2:/dev/videoN` for a quick preview |
| OBS Studio | ✅ | add a *Video Capture Device (V4L2)* source |
| **GNOME Camera (Snapshot 50)** | ❌ | broken upstream twice: (1) panics without the GStreamer `pipewiredeviceprovider`, which pipewire ≥ 1.6 no longer ships; (2) its camerabin negotiates formats the locked loopback can't do. Don't use it for now |
| PipeWire-native apps | ⚠️ | PipeWire's libcamera plugin is disabled (it segfaults on the IMX208 — see §3.4). PipeWire sees the *virtual* camera via V4L2 instead |

**Physical camera exclusivity:** libcamera allows exactly one client of the
IMX208 at a time. When the feed runs, the sensor is busy — that's the point of
the loopback: unlimited apps share the virtual device. For a libcamera-native
app (`qcam`, `cam`, gst `libcamerasrc`), toggle the feed **off** first.

**One virtual camera, many apps:** with the driver patch in §3.1, several apps
may read the virtual camera simultaneously. Without it, only one app at a
time could open it.

## 7. Files in this repo (root)

| File | Purpose |
|------|---------|
| `vcam-toggle.sh` / `vcam-toggle.desktop` | daily on/off for the feed (LED follows) |
| `vcam-on.sh` / `vcam-off.sh` (+`.desktop`) | full module load/unload + diagnostics |
| `vcam-feed.sh` | fallback feed daemon (the systemd service is canonical) |
| `v4l2loopback-gst.sh` | the actual gstreamer pipeline (→ `~/.local/bin/`) |
| `systemd/v4l2loopback-camera.service` | user service that runs the feed |
| `imx208-digital-gain-fix.sh` | sensor brightness fix (→ `~/.local/bin/`) |
| `wireplumber/51-disable-libcamera.conf` | stop wireplumber's libcamera SEGV loop |
| `v4l2loopback-shared-capture.patch` | driver patch: shared capture consumers |
| `wemeet.sh`, `wechat.sh` | app wrappers (camera check + shim for wemeet) |
| `wemeet-v4l2fix.c` / `.so` | LD_PRELOAD shim fixing wemeet's black camera |
| `install-desktop.sh` | install the GNOME menu entries |

## 8. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `cam -l` shows no camera | patched libcamera not active (§1); check `IgnorePkg` after upgrades |
| Picture dark/washed out | color fix not applied (§2); check tuning file + `digital_gain` |
| wemeet camera black | launched without the shim — use the stock icon or `./wemeet.sh`; verify with `WEMEET_V4L2FIX_LOG=/tmp/fix.log` |
| App says camera busy | pre-patch v4l2loopback (§3.1) — re-apply the driver patch + dkms |
| Session "shuts down" to login screen | wireplumber's libcamera plugin crash — apply §3.4 |
| guvcview fails to start stream | pre-§3.1 driver; also try `-b` (disable libv4l2) |
| Camera LED always on | feed running — toggle off (`vcam-toggle.sh`); the service is intentionally not auto-enabled |
| Reboot hangs with camera on | stop the feed first (the toggle also restarts wireplumber, which is the component that hangs) |

## License

MIT (project scripts). Upstream patches keep their original licenses
(libcamera patch: Peter Lishov; original Fedora guide: Mason Zhang).
