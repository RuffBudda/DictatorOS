#!/bin/bash
# System-level tweaks. Run with:  sudo ~/dotfiles/system/install.sh
#  1. Hide the Limine boot menu (quiet + 1s timeout: invisible, but tapping any
#     key right after power-on still shows it, so snapshots stay reachable).
#  2. Boot splash (Plymouth / disk-unlock screen): black, no Omarchy logo.
#  3. Login screen (SDDM, only seen after logout): black, no Omarchy logo.
#  Password boxes on both get rounded corners and a red border.
#  4. Chromium: block YouTube notifications.  5. Battery: stop charging at ~80%.
#  6. No automatic sleep (lid close ignored).
#  7. A pacman hook re-applies all of this after relevant updates (root-owned copy).
# Safe to re-run (e.g. after an `omarchy update` that resets anything).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

# Run from the pacman hook after updates: do nothing if all is still in place.
if [[ ${1:-} == --from-hook ]]; then
  ok=1
  [[ $(plymouth-set-default-theme 2>/dev/null) == omarchy-black ]] || ok=0
  [[ -f /etc/sddm.conf.d/zz-dotfiles.conf ]] || ok=0
  [[ -f /etc/chromium/policies/managed/dotfiles.json ]] || ok=0
  [[ -f /etc/udev/rules.d/90-dotfiles-battery.rules ]] || ok=0
  [[ -f /etc/systemd/logind.conf.d/dotfiles-lid.conf ]] || ok=0
  grep -q '^quiet: yes' /boot/limine.conf 2>/dev/null || ok=0
  grep -q 'name.sprite\|entry.y = Window.GetHeight() / 2' /usr/share/plymouth/themes/omarchy-black/omarchy-black.script 2>/dev/null || ok=0
  (( ok )) && { echo "dotfiles: system settings intact"; exit 0; }
  echo "dotfiles: re-applying system settings reset by the update"
fi

BOOT_TIMEOUT="${BOOT_TIMEOUT:-1}"   # seconds; 0 = never show menu at all
LOCK_NAME="${LOCK_NAME:-}"  # optional name above the boot password box; empty = no name (matches lock screen)

# Rounded password box (matches the 8px window rounding and red theme).
# rounded_box <out.png> <width> <height> <border-colour>
rounded_box() {
  magick -size "$2x$3" xc:none -fill '#0a0a0a' -stroke "$4" -strokewidth 2 \
    -draw "roundrectangle 1,1 $(($2-2)),$(($3-2)) 8,8" "$1"
}

# ── 1. Limine ──────────────────────────────────────────────
for conf in /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf; do
  [[ -f $conf ]] || continue
  cp "$conf" "$conf.bak.$(date +%s)"
  if grep -q '^timeout:' "$conf"; then
    sed -i "s/^timeout:.*/timeout: $BOOT_TIMEOUT/" "$conf"
  else
    sed -i "1i timeout: $BOOT_TIMEOUT" "$conf"
  fi
  grep -q '^quiet:' "$conf" && sed -i 's/^quiet:.*/quiet: yes/' "$conf" || sed -i '1i quiet: yes' "$conf"
  echo "Updated $conf"
done

# ── 2. Plymouth ────────────────────────────────────────────
SRC=/usr/share/plymouth/themes/omarchy
DST=/usr/share/plymouth/themes/omarchy-black
rm -rf "$DST"; cp -r "$SRC" "$DST"
mv "$DST/omarchy.plymouth" "$DST/omarchy-black.plymouth"
mv "$DST/omarchy.script"   "$DST/omarchy-black.script"
sed -i -e 's|themes/omarchy$|themes/omarchy-black|' \
       -e 's|themes/omarchy/|themes/omarchy-black/|g' \
       -e 's|omarchy.script|omarchy-black.script|' \
       -e 's|^ConsoleLogBackgroundColor=.*|ConsoleLogBackgroundColor=0x000000|' -e 's|^Name=.*|Name=Omarchy Black|' "$DST/omarchy-black.plymouth"
sed -i 's/SetBackground\(Top\|Bottom\)Color([^)]*)/SetBackground\1Color(0, 0, 0)/' "$DST/omarchy-black.script"
# Same-size transparent logo keeps the password box in the same place.
size=$(magick identify -format '%wx%h' "$SRC/logo.png")
magick -size "$size" xc:none "$DST/logo.png"
rm -rf "$DST/logos"

# Match the lock screen: name in red above a centred password box, no padlock.
perl -0pi -e 's/entry\.y = logo\.sprite\.GetY\(\) \+ logo\.image\.GetHeight\(\) \+ 40;/entry.y = Window.GetHeight() \/ 2 - entry.image.GetHeight() \/ 2;/' "$DST/omarchy-black.script"
# No padlock icon (the lock screen has none).
perl -0pi -e 's/fun show_password_dialog\(\) \{\n  lock\.sprite\.SetOpacity\(1\);/fun show_password_dialog() {/' "$DST/omarchy-black.script"
if [[ -n $LOCK_NAME ]]; then
perl -0pi -e 's/fun show_password_dialog\(\) \{/fun show_password_dialog() {\n  name.sprite.SetOpacity(1);/' "$DST/omarchy-black.script"
perl -0pi -e 's/fun hide_password_dialog\(\) \{\n  lock\.sprite\.SetOpacity\(0\);/fun hide_password_dialog() {\n  lock.sprite.SetOpacity(0);\n  name.sprite.SetOpacity(0);/' "$DST/omarchy-black.script"
cat >>"$DST/omarchy-black.script" <<PLY

#----------------------------------------- Name (dotfiles) ------------------------
name.image = Image.Text("$LOCK_NAME", 0.898, 0.220, 0.231, 1, "Cantarell Bold 20");
name.sprite = Sprite(name.image);
name.sprite.SetPosition(Window.GetWidth() / 2 - name.image.GetWidth() / 2, entry.y - name.image.GetHeight() - 24, 10001);
name.sprite.SetOpacity(0);
PLY
fi
rounded_box "$DST/entry.png" 286 48 '#e5383b'
plymouth-set-default-theme omarchy-black
echo "Rebuilding initramfs…"
if command -v limine-mkinitcpio >/dev/null; then limine-mkinitcpio; else mkinitcpio -P; fi

# ── 3. SDDM ────────────────────────────────────────────────
S_SRC=/usr/share/sddm/themes/omarchy
S_DST=/usr/share/sddm/themes/omarchy-black
if [[ -d $S_SRC ]]; then
  rm -rf "$S_DST"; cp -r "$S_SRC" "$S_DST"
  magick -size 1x1 xc:none "$S_DST/logo.png"
  rounded_box "$S_DST/entry.png" 286 48 '#e5383b'
  rounded_box "$S_DST/entry-failed.png" 286 48 '#ff4d4f'
  sed -i '0,/color: "#[0-9a-fA-F]*"/s//color: "#000000"/' "$S_DST/Main.qml"
  printf '[Theme]\nCurrent=omarchy-black\n' > /etc/sddm.conf.d/zz-dotfiles.conf
  echo "SDDM theme: omarchy-black"
fi

# ── 4. Chromium: block YouTube notifications (all windows and web apps) ──
mkdir -p /etc/chromium/policies/managed
cat >/etc/chromium/policies/managed/dotfiles.json <<'JSON'
{
  "NotificationsBlockedForUrls": ["https://www.youtube.com", "https://youtube.com", "https://m.youtube.com", "https://music.youtube.com"]
}
JSON
echo "Chromium: YouTube notifications blocked"

# ── 5. Battery: Lenovo Conservation mode (stops charging at ~80%) ─────
# BAT1 offers charge_types "Fast Standard Long_Life"; Long_Life is Lenovo's
# Conservation mode. Set it now and on every boot / battery re-detect.
cat >/etc/udev/rules.d/90-dotfiles-battery.rules <<'RULES'
ACTION=="add|change", SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{charge_types}=="*Long_Life*", ATTR{charge_types}="Long_Life"
RULES
for b in /sys/class/power_supply/BAT*; do
  [[ -w $b/charge_types ]] && grep -q Long_Life "$b/charge_types" && echo Long_Life >"$b/charge_types"
done
udevadm control --reload-rules
echo "Battery: $(cat /sys/class/power_supply/BAT*/charge_types 2>/dev/null | head -1)"

# ── 6. No automatic sleep: closing the lid does nothing (battery or AC) ──
# Nothing else suspends automatically (Omarchy idle only locks).
mkdir -p /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/dotfiles-lid.conf <<'CONF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
CONF
systemctl kill -s HUP systemd-logind   # reload config without ending the session
echo "Lid close: ignore (no automatic sleep)"

# ── 7. Re-apply all of this automatically after relevant package updates ──
# The hook runs a root-owned copy (never the user-writable file in ~/dotfiles).
self=$(readlink -f "$0"); copy=/usr/local/lib/dotfiles/system-install.sh
[[ $self == "$copy" ]] || install -D -m 755 -o root -g root "$self" "$copy"   # skip when run as the copy (from the hook)
mkdir -p /etc/pacman.d/hooks
cat >/etc/pacman.d/hooks/zz-dotfiles-system.hook <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy
Target = plymouth
Target = sddm
Target = limine
Target = limine-*
Target = chromium
Target = systemd

[Action]
Description = Re-applying dotfiles system settings (boot splash, login, battery, lid…)
When = PostTransaction
Exec = /usr/local/lib/dotfiles/system-install.sh --from-hook
HOOK
echo "Auto re-apply after updates: /etc/pacman.d/hooks/zz-dotfiles-system.hook"

echo "System tweaks applied. Reboot to see them."
