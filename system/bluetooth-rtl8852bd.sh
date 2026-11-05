#!/bin/bash
# Bluetooth for the Legion 5 15AHP11's Realtek RTL8852BD (USB 0bda:b853,
# rom_version=3). The stock kernel never brings hci0 up ("No default controller
# available"); this needs the "eco4" firmware from Lenovo's Windows Bluetooth
# driver plus a patched btrtl module.
#
#   sudo ~/dotfiles/system/bluetooth-rtl8852bd.sh ~/Downloads/<lenovo-bt-driver>.exe
#   sudo ~/dotfiles/system/bluetooth-rtl8852bd.sh --uninstall
#
# Driver .exe: pcsupport.lenovo.com -> 83Q7 -> Drivers & Software -> Bluetooth
# (2026-11-02 it was 71l5037f6macd1k0.exe). It is proprietary, so it is not kept here.
#
# Upstream: https://github.com/mihaits/rtl8852bd-bt-linux, pinned to the reviewed
# commit below. Upstream's kernel-update hook uses /etc/kernel/postinst.d, which
# Arch never runs, so this also adds a pacman hook (zz-* runs after 70-dkms-install).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

REPO=https://github.com/mihaits/rtl8852bd-bt-linux
COMMIT=0af62b8
SRC=/home/${SUDO_USER:-$USER}/.local/src/rtl8852bd-bt-linux
PACMAN_HOOK=/etc/pacman.d/hooks/zz-rtl8852bd-bt.hook
RUNNER=/usr/local/bin/rtl8852bd-bt-rebuild

if [[ ${1:-} == --uninstall ]]; then
  rm -f "$PACMAN_HOOK" "$RUNNER"
  [[ -x $SRC/uninstall.sh ]] && "$SRC/uninstall.sh"
  exit 0
fi
[[ $# -eq 1 && -f $1 ]] || { echo "usage: sudo $0 /path/to/lenovo-bt-driver.exe"; exit 1; }

pacman -S --needed --noconfirm innoextract dkms git

if [[ ! -d $SRC/.git ]]; then
  sudo -u "${SUDO_USER:-root}" git clone -q "$REPO" "$SRC"
fi
sudo -u "${SUDO_USER:-root}" git -C "$SRC" fetch -q origin || true
sudo -u "${SUDO_USER:-root}" git -C "$SRC" checkout -q "$COMMIT"

"$SRC/install.sh" "$1"

install -d /etc/pacman.d/hooks
cat > "$RUNNER" <<'EOF'
#!/bin/sh
# pacman passes changed paths (usr/lib/modules/<kver>/vmlinuz) on stdin.
while read -r path; do
  kver=$(echo "$path" | cut -d/ -f4)
  [ -n "$kver" ] && [ -d "/usr/lib/modules/$kver/build" ] && \
    /etc/kernel/postinst.d/zz-rtl8852bd-bt "$kver"
done
exit 0
EOF
chmod 755 "$RUNNER"

cat > "$PACMAN_HOOK" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Re-installing RTL8852BD Bluetooth module for new kernel...
When = PostTransaction
Exec = $RUNNER
NeedsTargets
EOF

echo "Pacman hook installed: $PACMAN_HOOK"
echo "Check: bluetoothctl show   (should list a controller with a real address)"
