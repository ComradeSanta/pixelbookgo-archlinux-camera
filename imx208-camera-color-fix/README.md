# Pixelbook Go — IMX208 摄像头修复

## 适用设备

- Google Pixelbook Go (Atlas)
- 其它使用 Intel IPU3 CIO2 + Sony IMX208 sensor 的笔记本
- Arch Linux (libcamera >= 0.7.0, pipewire, wireplumber)

## 症状

1. 摄像头画面极其昏暗/全黑（像素值仅 ~11%）
2. 色彩异常

## 根因

**两个叠加的问题：**

1. **libcamera 缺少 IMX208 的 IPA 调优文件** — fallback 到 `uncalibrated.yaml`（空壳），AGC 算法盲跑，曝光策略错误
2. **libcamera IPU3 AGC 不控制 digital_gain** — IMX208 的 analog gain 开到上限（224）也只对应约 2x 真实增益，根本不够室内使用。digital gain 可以提供 2x/4x/8x/16x，但 libcamera 从未触碰这个寄存器

## 修复内容

### 1. `imx208.yaml` — AGC 调优
- luminance target: 0.35（默认仅 0.16）
- 曝光时间与增益的分段映射，最高 16x
- 安装路径: `/usr/share/libcamera/ipa/ipu3/`

### 2. `set-digital-gain.sh` — 手动推 digital gain 到 8x
- libcamera 不会动的寄存器，我们手动设
- 自动发现 IMX208 sensor 节点（适配设备号变化）
- 等待 sensor 上电后再写入

### 3. Systemd 服务 + 休眠钩子
- `imx208-dgain.service` — 开机/登录后自动执行
- `/usr/lib/systemd/system-sleep/imx208-dgain.sh` — 休眠唤醒后重新写入

## 安装

```bash
sudo ./install.sh
```

或者手动分步安装：

```bash
# 1. 调优文件
sudo cp imx208.yaml /usr/share/libcamera/ipa/ipu3/

# 2. Digital gain 脚本
cp set-digital-gain.sh ~/.local/bin/
chmod +x ~/.local/bin/set-digital-gain.sh

# 3. 开机自动执行
cp imx208-dgain.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now imx208-dgain.service

# 4. 休眠唤醒后重新执行
sudo cp sleep-hook.sh /usr/lib/systemd/system-sleep/imx208-dgain.sh
sudo chmod +x /usr/lib/systemd/system-sleep/imx208-dgain.sh
```

## 验证

```bash
# 确认调优文件生效
cam -c1 -I 2>&1 | grep "Using tuning file"
# 应输出: Using tuning file /usr/share/libcamera/ipa/ipu3/imx208.yaml

# 确认 digital gain 已设置
SENSOR=$(media-ctl -p 2>/dev/null | grep -A2 imx208 | grep "device node" | awk '{print $NF}')
v4l2-ctl -d "$SENSOR" --get-ctrl=digital_gain
# 应输出: digital_gain: 3 (8 0x8)
```

## 已知限制

- 如果 PipeWire/Wireplumber 重启，systemd 服务会重新设 digital gain（没问题）
- 如果长时间不用摄像头，sensor 可能被 PM 挂起，下次打开时 digital gain 可能掉回 0；关掉重开相机 app 即可触发 systemd 服务
- 这是 workaround，不是 upstream fix。真正解决需要给 libcamera 加 IMX208 的 digital gain 支持

## 文件列表

```
imx208-camera-fix/
├── README.md
├── install.sh              # 一键安装
├── imx208.yaml             # libcamera IPA 调优
├── set-digital-gain.sh     # digital gain 设置脚本
├── imx208-dgain.service    # systemd 用户服务
└── sleep-hook.sh           # 休眠唤醒钩子
```
