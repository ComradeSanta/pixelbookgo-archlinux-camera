#!/bin/bash
set -e

echo "备份旧版本..."
sudo cp /usr/lib64/libcamera/ipa/ipa_ipu3.so /usr/lib64/libcamera/ipa/ipa_ipu3.so.bak.$(date +%s)
sudo cp /lib64/libcamera.so.0.7 /lib64/libcamera.so.0.7.bak.$(date +%s)
sudo cp /lib64/libcamera-base.so.0.7 /lib64/libcamera-base.so.0.7.bak.$(date +%s)

echo "覆盖为新编译版本..."
sudo cp /usr/local/lib64/libcamera/ipa/ipa_ipu3.so /usr/lib64/libcamera/ipa/ipa_ipu3.so
sudo cp /usr/local/lib64/libcamera.so.0.7 /lib64/libcamera.so.0.7
sudo cp /usr/local/lib64/libcamera-base.so.0.7 /lib64/libcamera-base.so.0.7

echo "更新动态链接器缓存..."
sudo ldconfig

echo "重启 PipeWire..."
systemctl --user restart pipewire wireplumber

echo ""
echo "完成！请检查摄像头："
echo "  pw-cli ls Node | grep -i camera"
