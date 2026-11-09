#!/bin/bash
# Bluetooth for the RTL8852BD radio (USB 0bda:b853, rom_version 3) in the
# Legion 5 15AHP11. linux-firmware has no patch for this chip revision, so it
# never starts. This installs:
#   - the firmware, repacked from Lenovo's Windows Bluetooth driver (.exe you
#     download yourself; nothing is redistributed here)
#   - btrtl from *this kernel's own source* plus the "eco4" multi-record loader
#     from github.com/mihaits/rtl8852bd-bt-linux (GPL-2.0), built with DKMS
#   - a pacman hook that re-lands the module after kernel updates
#
#   sudo ./install.sh ~/Downloads/<lenovo-bluetooth-driver>.exe
#   sudo ./install.sh --uninstall
set -euo pipefail
PKG=rtl8852bd-bt VER=1.0 FW=/usr/lib/firmware/rtl_bt/rtl8852bd_eco4.bin
HOOK=/etc/pacman.d/hooks/zz-rtl8852bd-bt.hook
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }

reload() {
  systemctl stop bluetooth 2>/dev/null || true
  modprobe -r btusb btrtl 2>/dev/null || true; sleep 1
  modprobe btusb; sleep 4
  systemctl start bluetooth 2>/dev/null || true; sleep 2
}

if [[ ${1:-} == --uninstall ]]; then
  rm -f "$HOOK" "$FW"
  dkms remove -m $PKG -v $VER --all 2>/dev/null || true
  rm -rf /usr/src/$PKG-$VER
  depmod -a; reload
  echo "Removed; the stock btrtl is back."; exit 0
fi

EXE=${1:?usage: sudo ./install.sh <lenovo-bluetooth-driver.exe>}
[[ -f $EXE ]] || { echo "no such file: $EXE"; exit 1; }
# (read the log into a variable first: `journalctl | grep -q` trips pipefail)
KLOG=$(journalctl -k -b --no-pager)
[[ $KLOG == *"rom_version status=0 version=3"* ]] \
  || { echo "This chip doesn't report rom_version 3; this fix is not for it."; exit 1; }

echo "==> Packages"
pacman -S --needed --noconfirm innoextract dkms "$(pacman -Qqo /usr/lib/modules/$(uname -r)/vmlinuz)-headers" >/dev/null

echo "==> Firmware"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
innoextract -s -d "$WORK/x" "$EXE" >/dev/null
DAT=$(find "$WORK/x" -iname 'rtl8852bd_mp_chip_new.dat' -print -quit)
[[ -n $DAT ]] || { echo "rtl8852bd_mp_chip_new.dat not in that installer -- wrong driver?"; exit 1; }
python3 -I "$HERE/extract-firmware.py" "$DAT" -o "$WORK/fw.bin"
install -Dm644 "$WORK/fw.bin" "$FW"

echo "==> Module (DKMS)"
dkms remove -m $PKG -v $VER --all >/dev/null 2>&1 || true
rm -rf /usr/src/$PKG-$VER; install -d /usr/src/$PKG-$VER
cp "$HERE"/src/* /usr/src/$PKG-$VER/
dkms add -m $PKG -v $VER >/dev/null
dkms install -m $PKG -v $VER --force
depmod -a

echo "==> Kernel-update hook"
# dkms builds our btrtl on a kernel update but won't install it over the
# in-tree module of the same name, so force it in after dkms's own hook.
install -Dm644 /dev/stdin "$HOOK" <<'HK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Re-installing the RTL8852BD Bluetooth module...
When = PostTransaction
Exec = /bin/sh -c 'for d in /usr/lib/modules/*/build; do k=$(basename "$(dirname "$d")"); dkms uninstall -m rtl8852bd-bt -v 1.0 -k "$k" >/dev/null 2>&1; dkms install -m rtl8852bd-bt -v 1.0 -k "$k" --force >/dev/null 2>&1; done; true'
Depends = dkms
HK

echo "==> Reloading Bluetooth"
rfkill unblock bluetooth 2>/dev/null || true
reload
journalctl -k -b --no-pager | grep -E "RTL8852BD|eco4" | tail -3 || true
SHOW=$(bluetoothctl show 2>/dev/null || true)
if [[ $SHOW == *Controller* ]]; then
  echo "Bluetooth is up: ${SHOW%%$'\n'*}"
else
  echo "Controller not up yet -- see journalctl -k -b | grep -i hci0"
fi
