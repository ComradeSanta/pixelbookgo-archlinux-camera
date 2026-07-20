# IMX208 摄像头修复指南

## 问题概述

你的设备使用 **Intel IPU3 + Sony IMX208** 方案，摄像头无法被系统识别。

根因有两个：
1. **libcamera 缺少 IMX208 的 sensor helper** → 导致 IPU3 IPA 初始化失败
2. **内核 imx208 驱动缺少 `get_selection` pad op** → 导致 libcamera 无法获取 sensor crop 信息

## 已提供的 Patch

| 文件 | 说明 |
|------|------|
| `libcamera-add-imx208-helper.patch` | 为 libcamera 添加 IMX208 支持 |
| `kernel-imx208-add-get_selection.patch` | 为内核驱动添加 V4L2 selection 支持 |

---

## 第一部分：编译安装 libcamera

### 1. 安装编译依赖

```bash
sudo dnf install -y meson ninja-build gcc-c++ git \
    libgnutls-devel openssl-devel libtiff-devel \
    libyaml-devel python3-yaml python3-ply \
    libglib2.0-devel gstreamer1-plugins-base-devel \
    qt5-qtbase-devel libepoxy-devel boost-devel \
    python3-pybind11 libevent-devel
```

### 2. 获取源码

系统上已经下载了 libcamera-0.7.1 的源码包。如果没有，执行：

```bash
cd /tmp
dnf download --source libcamera
rpm2cpio libcamera-0.7.1-1.fc44.src.rpm | cpio -idmv
tar -xjf libcamera-v0.7.1.tar.bz2
```

### 3. 应用 Patch

```bash
cd /tmp/libcamera-v0.7.1
patch -p1 < ~/桌面/libcamera-add-imx208-helper.patch
```

如果 patch 命令提示找不到文件（因为 patch 是基于行号估算的），可以手动编辑：

**编辑 `src/ipa/libipa/camera_sensor_helper.cpp`**

在 `REGISTER_CAMERA_SENSOR_HELPER("imx219", CameraSensorHelperImx219)` 之后添加：

```cpp
class CameraSensorHelperImx208 : public CameraSensorHelper
{
public:
	CameraSensorHelperImx208()
	{
		/* IMX208 uses the same analogue gain model as IMX219 */
		gain_ = AnalogueGainLinear{ 0, 256, -1, 256 };
	}
};
REGISTER_CAMERA_SENSOR_HELPER("imx208", CameraSensorHelperImx208)
```

**编辑 `src/libcamera/sensor/camera_sensor_properties.cpp`**

在 `"imx208"` 条目处（如果不存在则在 `"imx258"` 之前）添加：

```cpp
		{ "imx208", {
				.unitCellSize = { 1120, 1120 },
				.testPatternModes = {
					{ controls::draft::TestPatternModeOff, 0 },
					{ controls::draft::TestPatternModeSolidColor, 1 },
					{ controls::draft::TestPatternModeColorBars, 2 },
					{ controls::draft::TestPatternModeColorBarsFadeToGray, 3 },
					{ controls::draft::TestPatternModePn9, 4 },
				},
				.sensorDelays = {
					.exposureDelay = 2,
					.gainDelay = 2,
					.vblankDelay = 2,
					.hblankDelay = 2
				},
			} },
```

### 4. 编译并安装

```bash
cd /tmp/libcamera-v0.7.1
meson setup build --buildtype=release \
    -Dgstreamer=enabled \
    -Dpipelines=auto \
    -Dipas=auto \
    -Dv4l2=true \
    -Dcam=enabled \
    -Dqcam=enabled \
    -Ddocumentation=disabled \
    -Dtests=disabled

ninja -C build
sudo ninja -C build install
sudo ldconfig
```

### 5. 重启 PipeWire

```bash
systemctl --user restart pipewire wireplumber
```

然后检查摄像头是否出现：

```bash
pw-cli ls Node | grep -i camera
```

---

## 第二部分：编译内核模块（可选但推荐）

如果你仍然看到内核驱动相关的 warning（如 `Unable to get rectangle`），需要修补内核驱动。

### 1. 安装内核开发包

```bash
sudo dnf install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r)
```

### 2. 获取 imx208.c 源码

```bash
cd /tmp
# 从当前运行内核的源码树复制
cp /usr/src/kernels/$(uname -r)/drivers/media/i2c/imx208.c ./imx208.c 2>/dev/null || \
curl -L -o imx208.c "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/media/i2c/imx208.c?h=v$(uname -r | cut -d. -f1-2)"
```

### 3. 编写补丁或手动修改

由于内核版本差异，自动 patch 可能不生效。建议手动在 `imx208.c` 中：

**A. 在文件中找到 `imx208_enum_frame_size` 函数，在其后添加：**

```c
static int imx208_get_selection(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *sd_state,
				struct v4l2_subdev_selection *sel)
{
	struct imx208 *imx208 = to_imx208(sd);

	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = imx208->mode->width;
		sel->r.height = imx208->mode->height;
		return 0;
	case V4L2_SEL_TGT_NATIVE_SIZE:
		/* Native pixel array size */
		sel->r.left = 0;
		sel->r.top = 0;
		sel->r.width = 1936;
		sel->r.height = 1096;
		return 0;
	default:
		return -EINVAL;
	}
}
```

**B. 找到 `imx208_pad_ops` 结构体，在 `.get_fmt` 行后添加：**

```c
static const struct v4l2_subdev_pad_ops imx208_pad_ops = {
	.enum_mbus_code = imx208_enum_mbus_code,
	.enum_frame_size = imx208_enum_frame_size,
	.get_fmt = imx208_get_fmt,
	.get_selection = imx208_get_selection,  /* <-- 添加这一行 */
	.set_fmt = imx208_set_fmt,
};
```

### 4. 编译模块

创建一个简单的 Makefile：

```bash
cat > /tmp/imx208/Makefile << 'EOF'
KVER := $(shell uname -r)
KDIR := /lib/modules/$(KVER)/build

obj-m += imx208.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
EOF
```

然后编译：

```bash
cd /tmp/imx208
make
```

### 5. 安装模块

```bash
sudo cp imx208.ko /lib/modules/$(uname -r)/kernel/drivers/media/i2c/
sudo xz -f /lib/modules/$(uname -r)/kernel/drivers/media/i2c/imx208.ko
sudo depmod -a
```

由于 Fedora 使用 Secure Boot 内核签名，新编译的未签名模块可能无法加载。你有两个选择：

**选项 A：禁用 Secure Boot（最简单）**
进入 BIOS/UEFI 设置，关闭 Secure Boot。

**选项 B：给模块签名**
```bash
sudo /usr/src/kernels/$(uname -r)/scripts/sign-file sha256 \
    /var/lib/dkms/mok.key /var/lib/dkms/mok.pub \
    /lib/modules/$(uname -r)/kernel/drivers/media/i2c/imx208.ko.xz
```

如果这是你第一次给模块签名，需要先创建 MOK 密钥并注册到 UEFI：
```bash
sudo mokutil --import /var/lib/dkms/mok.pub
# 设置密码，重启后在 MOK 管理界面中 enroll 该密钥
```

### 6. 加载新模块

```bash
sudo modprobe -r imx208
sudo modprobe imx208
```

---

## 第三部分：验证修复

```bash
# 检查 PipeWire 是否识别了摄像头
pw-cli ls Node | grep -i camera

# 检查 libcamera 是否能识别传感器
libcamera-hello --list-cameras 2>/dev/null || cam --list 2>/dev/null

# 或者用 v4l2-ctl 测试（安装 v4l-utils）
v4l2-ctl --list-devices
```

---

## 注意事项

1. **增益模型是推断的**：IMX208 的 `AnalogueGainLinear{ 0, 256, -1, 256 }` 是基于它与 IMX219 使用相同寄存器地址（0x0204）推断的。如果实际画面亮度异常（过曝/欠曝），可能需要根据数据手册调整参数。

2. **内核模块签名**：Fedora 默认启用 Secure Boot，自己编译的模块需要签名或禁用 Secure Boot。

3. **保留原始文件**：建议先备份：
   - `/usr/lib64/libcamera/ipa/ipa_ipu3.so`
   - `/lib/modules/$(uname -r)/kernel/drivers/media/i2c/imx208.ko.xz`

4. **如果只想快速恢复**：直接外接一个 USB 摄像头即可绕过此问题。

---

## 参考链接

- [libcamera 源码](https://git.libcamera.org/libcamera/libcamera.git/)
- [Linux 内核 imx208.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/media/i2c/imx208.c)
- [libcamera IPU3 Sensor Helper 机制](https://libcamera.org/api-html/classlibcamera_1_1ipa_1_1CameraSensorHelper.html)
