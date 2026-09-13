#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
MODULE_DIR="/usr/lib/modules/${KVER}/updates"

echo "=== DarkHorse USB 2.0 Web Camera (1b17:6101) Driver Installer ==="

if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run with sudo: sudo ./install.sh"
    exit 1
fi

echo "[*] Compiling kernel module for Linux ${KVER}..."
make -C "${SCRIPT_DIR}" clean
make -C "${SCRIPT_DIR}"

echo "[*] Compressing module with zstd..."
zstd -k -f "${SCRIPT_DIR}/vc032x_custom.ko" -o "${SCRIPT_DIR}/vc032x_custom.ko.zst"

echo "[*] Installing module to ${MODULE_DIR}..."
mkdir -p "${MODULE_DIR}"
install -m 644 "${SCRIPT_DIR}/vc032x_custom.ko.zst" "${MODULE_DIR}/vc032x_custom.ko.zst"

echo "[*] Updating module dependency database (depmod)..."
depmod -a

echo "[*] Installing persistent module loading configuration..."
mkdir -p /etc/modules-load.d
cat << "CONF" > /etc/modules-load.d/webcam-1b17.conf
vc032x_custom
CONF

echo "[*] Installing persistent udev rule..."
mkdir -p /etc/udev/rules.d
cat << "RULE" > /etc/udev/rules.d/99-webcam-1b17.rules
# DarkHorse / Vimicro USB 2.0 Web Camera (1b17:6101)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1b17", ATTR{idProduct}=="6101", MODE="0666", RUN+="/usr/bin/modprobe vc032x_custom"
RULE

udevadm control --reload-rules
udevadm trigger --subsystem-match=usb

echo "[*] Reloading module..."
if lsmod | grep -q "vc032x_custom"; then
    rmmod vc032x_custom || true
fi
modprobe vc032x_custom

echo "[+] Installation complete! Checking video node:"
v4l2-ctl --list-devices || true
