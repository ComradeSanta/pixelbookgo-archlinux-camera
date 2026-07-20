#!/bin/sh
# Pixelbook Go IMX208 camera fix — one-shot installer
# Run: sudo ./install.sh
set -e

if [ "$(id -u)" != "0" ]; then
    echo "Need root. Re-running with sudo..."
    exec sudo "$0" "$@"
fi

echo "=== Installing IMX208 camera fix ==="

# 1. libcamera tuning file
cp imx208.yaml /usr/share/libcamera/ipa/ipu3/
echo "[1/4] Tuning file installed"

# 2. Digital gain script
USER_HOME=$(getent passwd 1000 | cut -d: -f6)
mkdir -p "$USER_HOME/.local/bin"
cp set-digital-gain.sh "$USER_HOME/.local/bin/"
chmod +x "$USER_HOME/.local/bin/set-digital-gain.sh"
chown 1000:1000 "$USER_HOME/.local/bin/set-digital-gain.sh"
echo "[2/4] Digital gain script installed"

# 3. Systemd user service
mkdir -p "$USER_HOME/.config/systemd/user"
cp imx208-dgain.service "$USER_HOME/.config/systemd/user/"
chown -R 1000:1000 "$USER_HOME/.config/systemd/user/imx208-dgain.service"
echo "[3/4] Systemd service installed"

# 4. Sleep hook
cp sleep-hook.sh /usr/lib/systemd/system-sleep/imx208-dgain.sh
chmod +x /usr/lib/systemd/system-sleep/imx208-dgain.sh
echo "[4/4] Sleep hook installed"

# Enable the service
echo ""
echo "=== Enabling service ==="
systemctl --machine=1000@ --user enable imx208-dgain.service --now 2>/dev/null || \
    echo "NOTE: Log in as user and run: systemctl --user enable --now imx208-dgain.service"

echo ""
echo "Done. Camera should be brighter immediately."
echo "If not, restart PipeWire: systemctl --user restart wireplumber"
