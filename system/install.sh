#!/bin/bash
# System-level tweaks. Run with:  sudo ~/dotfiles/system/install.sh
#  1. Limine boot menu: shown for 10 s (with countdown) in DictatorOS colours (black, red title,
#     red highlight bar). Snapshots appear there for rolling back updates.
#  2. Boot splash (Plymouth / disk-unlock screen): black, no Omarchy logo.
#  3. Login screen (SDDM, only seen after logout): black, no Omarchy logo.
#  Both match the lock screen: no box, red ✱ stars (SDDM also gets the thin red clock).
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
  grep -q '^interface_branding: DictatorOS' /boot/limine.conf 2>/dev/null || ok=0
  grep -q 'name.sprite\|entry.y = Window.GetHeight() / 2' /usr/share/plymouth/themes/omarchy-black/omarchy-black.script 2>/dev/null || ok=0
  (( ok )) && { echo "dotfiles: system settings intact"; exit 0; }
  echo "dotfiles: re-applying system settings reset by the update"
fi

BOOT_TIMEOUT="${BOOT_TIMEOUT:-10}"   # seconds the menu waits; 0 = boot straight away
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
  # set_key <key> <value>: replace the global option, or add it at the top.
  set_key() {
    if grep -q "^$1:" "$conf"; then sed -i "s|^$1:.*|$1: $2|" "$conf"; else sed -i "1i $1: $2" "$conf"; fi
  }
  set_key quiet no
  # DictatorOS colours (from omarchy/themes/red/colors.toml)
  set_key interface_branding DictatorOS
  set_key interface_branding_color e5383b
  set_key interface_help_color 8a5a5d
  set_key interface_help_color_bright e5383b
  set_key backdrop 000000
  set_key term_background 000000
  set_key term_foreground e5383b     # red text; the highlighted entry is drawn inverted (red bar, black text)
  set_key term_palette '0a0a0a;e5383b;d9534f;ff7b54;e5383b;ba181b;c9184a;e8d5d6'
  set_key term_palette_bright '5c1a1e;ff4d4f;f26a6d;ff9a76;ff595e;e01e37;ff4d6d;fff2f2'
  sed -i 's/^# Terminal colors (Tokyo Night palette)/# Terminal colors (DictatorOS red palette)/' "$conf"
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
# Lock-screen look: no box, red ✱ stars centred on screen (no clock: Plymouth
# scripts cannot read the time).
magick -size 286x48 xc:none "$DST/entry.png"
magick -background none -fill '#e5383b' -font DejaVu-Sans -pointsize 40 label:$'✱' \
  -trim +repage -resize 22x22 -gravity center -extent 22x22 "$DST/bullet.png"
perl -0pi -e 's/bullet\.image\.Scale\(7, 7\)/bullet.image/;
  s/fun position_bullet\(index\) \{.*?\n\}/fun position_bullet(index) {\n  step = bullet.image.GetWidth() + 12;\n  bullet.sprites[index].SetPosition(Window.GetWidth() \/ 2 - (global.bullet_count * step - 12) \/ 2 + index * step, entry.y + entry.image.GetHeight() \/ 2 - bullet.image.GetHeight() \/ 2, 10002);\n}/s;
  s/(  for \(index = 0; index < bullets_to_show; index\+\+\) \{)/  global.bullet_count = bullets_to_show;\n$1/;
  s/(      position_bullet\(index\);\n    \}\n)/    }\n    position_bullet(index);\n/' "$DST/omarchy-black.script"
plymouth-set-default-theme omarchy-black
echo "Rebuilding initramfs…"
if command -v limine-mkinitcpio >/dev/null; then limine-mkinitcpio; else mkinitcpio -P; fi

# ── 3. SDDM ────────────────────────────────────────────────
S_SRC=/usr/share/sddm/themes/omarchy
S_DST=/usr/share/sddm/themes/omarchy-black
if [[ -d $S_SRC ]]; then
  rm -rf "$S_DST"; cp -r "$S_SRC" "$S_DST"
  # Same look as the lock screen: black, big thin red clock, red ✱ stars under
  # it, no box. Enter logs in; a wrong password shows a short red message.
  cat >"$S_DST/Main.qml" <<'QML'
import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
  id: root
  width: 640
  height: 480
  color: "#000000"

  property string currentUser: userModel.lastUser
  property bool loginFailed: false
  property bool checking: false
  property string clockText: Qt.formatTime(new Date(), "HH:mm")
  property int sessionIndex: {
    for (var i = 0; i < sessionModel.rowCount(); i++) {
      var name = (sessionModel.data(sessionModel.index(i, 0), Qt.DisplayRole) || "").toString()
      if (name.indexOf("uwsm") !== -1)
        return i
    }
    return sessionModel.lastIndex
  }

  Timer {
    interval: 1000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.clockText = Qt.formatTime(new Date(), "HH:mm")
  }

  Connections {
    target: sddm
    function onLoginFailed() {
      root.checking = false
      root.loginFailed = true
      password.text = ""
      password.forceActiveFocus()
    }
    function onLoginSucceeded() { root.loginFailed = false }
  }

  Text {
    id: clock
    text: root.clockText
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: field.top
    anchors.bottomMargin: 24
    color: "#e5383b"
    font.family: "JetBrains Mono"
    font.pixelSize: Math.round(root.width * 0.12)
    font.weight: Font.ExtraLight
    font.letterSpacing: -Math.round(root.width * 0.002)
  }

  Item {
    id: field
    width: 381
    height: 67
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.verticalCenter: parent.verticalCenter
    anchors.verticalCenterOffset: Math.round((clock.height + clock.anchors.bottomMargin) / 2)

    TextInput {
      id: password
      anchors.fill: parent
      anchors.leftMargin: 18
      anchors.rightMargin: 18
      verticalAlignment: TextInput.AlignVCenter
      horizontalAlignment: TextInput.AlignHCenter
      echoMode: TextInput.Password
      passwordCharacter: "✱"
      passwordMaskDelay: 0
      color: "#e5383b"
      selectionColor: "#3a0d10"
      selectedTextColor: "#e8d5d6"
      font.family: "JetBrains Mono"
      font.pixelSize: 29
      font.letterSpacing: text.length > 0 ? 13 : 0
      cursorDelegate: Item {}
      clip: true
      focus: true
      readOnly: root.checking
      onTextChanged: if (text.length > 0) root.loginFailed = false

      Keys.onPressed: {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (password.text.length > 0) {
            root.checking = true
            sddm.login(root.currentUser, password.text, root.sessionIndex)
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          password.text = ""
          event.accepted = true
        }
      }
    }

    Text {
      anchors.fill: parent
      visible: password.text.length === 0 && (root.checking || root.loginFailed)
      text: root.checking ? "Checking…" : "Wrong password"
      color: root.checking ? "#e8d5d6" : "#ff4d4f"
      font.family: "JetBrains Mono"
      font.pixelSize: 22
      font.italic: root.loginFailed
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
  }

  Component.onCompleted: password.forceActiveFocus()
}
QML
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
