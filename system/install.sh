#!/bin/bash
# System-level tweaks. Run with:  sudo ~/dotfiles/system/install.sh
#  1. Limine boot menu: 10 s countdown in DictatorOS colours, entries DictatorOS,
#     Windows 1 and Windows 2 (DictatorOS is one line, no kernel tree);
#     no Snapshots submenu; Limine first in
#     the firmware boot order.
#  2. Boot splash (Plymouth / disk-unlock screen): black, no Omarchy logo.
#  3. Login screen (SDDM, only seen after logout): black, no Omarchy logo.
#  Both match the lock screen: no box, red ✱ stars (SDDM also gets the thin red clock).
#  4. Chromium: block YouTube notifications, Claude extension, minimal toolbar,
#     AI features off.  5. Battery: stop charging at ~80%.
#  6. No automatic sleep (lid close ignored).  6b. Miracast firewall rules.
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
  [[ -f /etc/chromium/policies/managed/minimal.json && -f /etc/chromium/policies/managed/claude.json ]] || ok=0
  [[ -f /etc/udev/rules.d/90-dotfiles-battery.rules ]] || ok=0
  [[ -f /etc/systemd/logind.conf.d/dotfiles-lid.conf ]] || ok=0
  ! command -v ufw >/dev/null || ufw status | grep -q 'miracast-rtsp' || ok=0
  grep -q '^interface_branding: DictatorOS' /boot/limine.conf 2>/dev/null || ok=0
  grep -q '^/+\?DictatorOS$' /boot/limine.conf 2>/dev/null || ok=0
  for win in "Windows 1|2e9498e0-b9be-4682-8990-82ce3384b6f9" "Windows 2|f1ce4f0a-d1de-4739-9935-179251042b54"; do
    lsblk -no PARTUUID | grep -qx "${win##*|}" || continue
    grep -qx "/${win%%|*}" /boot/limine.conf 2>/dev/null || ok=0
  done
  ! systemctl is-enabled -q limine-snapper-sync.service 2>/dev/null || ok=0
  grep -q 'name.sprite\|entry.y = Window.GetHeight() / 2' /usr/share/plymouth/themes/omarchy-black/omarchy-black.script 2>/dev/null || ok=0
  (( ok )) && { echo "dotfiles: system settings intact"; exit 0; }
  echo "dotfiles: re-applying system settings reset by the update"
fi

BOOT_TIMEOUT="${BOOT_TIMEOUT:-10}"   # seconds before booting the default entry
BOOT_MENU="${BOOT_MENU:-shown}"      # "hidden" = quiet (tap a key at power-on to see it)
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
  [[ $BOOT_MENU == shown ]] && set_key quiet no || set_key quiet yes
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
  # Menu entry name: Omarchy → DictatorOS (entries are matched by machine-id,
  # and TARGET_OS_NAME below keeps kernel/snapshot updates using the new name).
  sed -i 's|^/\(+\?\)Omarchy$|/\1DictatorOS|' "$conf"
  # Windows installs: chainload each one's own boot manager from its EFI partition.
  # name|EFI partition PARTUUID (skipped on machines without that partition)
  for win in "Windows 1|2e9498e0-b9be-4682-8990-82ce3384b6f9" \
             "Windows 2|f1ce4f0a-d1de-4739-9935-179251042b54"; do
    name=${win%%|*}; guid=${win##*|}
    lsblk -no PARTUUID | grep -qx "$guid" || continue
    # Already listed (perhaps under an older name): make sure it's called $name.
    if grep -qF "guid($guid)" "$conf"; then
      awk -v g="guid($guid)" -v n="/$name" '
        { line[NR] = $0; if ($0 ~ /^\/[^\/]/) head = NR }
        index($0, g) && head { line[head] = n }
        END { for (i = 1; i <= NR; i++) print line[i] }' "$conf" >"$conf.tmp" &&
        cat "$conf.tmp" >"$conf" && rm -f "$conf.tmp"
      continue
    fi
    printf '\n/%s\n    comment: Windows Boot Manager on its own EFI partition (dotfiles)\n    protocol: efi\n    path: guid(%s):/EFI/Microsoft/Boot/bootmgfw.efi\n' \
      "$name" "$guid" >>"$conf"
    echo "Limine: added $name"
  done
  echo "Updated $conf"
done
# Snapshots stay out of the boot menu. Disabling this service is not enough on
# its own: snapper-cleanup and the Snapper plugin also run limine-snapper-sync,
# which re-adds the Snapshots submenu; the limine-flatten post hook (above)
# strips it again every time. (Snapper still takes snapshots.)
systemctl disable --now limine-snapper-sync.service 2>/dev/null || true
# Remove snapshot entries already in the menu: the "Snapshots" submenu and the
# "<n> │ <date>" snapshot entries it also nests under each kernel.
if command -v limine-entry-tool >/dev/null; then
  limine-entry-tool --tree 2>/dev/null | python3 -I -c '
import re, sys
stack, out = [], []
for line in sys.stdin:
    line = line.rstrip("\n")
    m = re.match(r"^((?:[│ ]  )*)(?:[├└]─ )?(.+)$", line)
    if not m or not m.group(2).strip(): continue
    depth = len(m.group(1)) // 3 + (1 if re.search(r"[├└]─ ", line) else 0)
    name = m.group(2).strip()
    stack = stack[:depth] + [name]
    if name == "Snapshots" or re.match(r"^\d+ │ ", name):
        path = "/".join(stack)
        if not any(path.startswith(o + "/") for o in out): out.append(path)
print("\n".join(out))' | while IFS= read -r entry; do
    if [[ -n $entry ]] && limine-entry-tool --remove-entry "$entry" 0 >/dev/null; then
      echo "Limine: removed $entry"
    fi
  done
fi
if [[ -f /etc/default/limine ]]; then
  if grep -q '^TARGET_OS_NAME=' /etc/default/limine; then
    sed -i 's/^TARGET_OS_NAME=.*/TARGET_OS_NAME="DictatorOS"/' /etc/default/limine
  else
    echo 'TARGET_OS_NAME="DictatorOS"' >> /etc/default/limine
  fi
fi

# DictatorOS as one boot line (no kernel tree under it). limine-entry-tool
# rebuilds the tree on every kernel update, so a post hook flattens it again.
HOOK=/etc/boot/hooks/post.d/zz-dotfiles-limine-flatten
install -D -m 755 -o root -g root "$(dirname "$(readlink -f "$0")")/limine-flatten" "$HOOK"
for conf in /boot/limine.conf /boot/limine/limine.conf /boot/EFI/limine/limine.conf; do
  [[ -f $conf ]] && "$HOOK" "$conf"
done

# Firmware boot order: Limine first. Windows moves its boot manager to the top
# every time it starts; windows/install-limine-first.ps1 fixes that from the
# Windows side, and this service re-checks at every Linux boot as a safety net.
if command -v efibootmgr >/dev/null; then
  src="$(dirname "$(readlink -f "$0")")/limine-first"
  [[ $src -ef /usr/local/lib/dotfiles/limine-first ]] || install -D -m 755 -o root -g root "$src" /usr/local/lib/dotfiles/limine-first
  cat >/etc/systemd/system/dotfiles-limine-first.service <<'UNIT'
[Unit]
Description=Keep Limine first in the firmware boot order (DictatorOS)
ConditionPathExists=/sys/firmware/efi

[Service]
Type=oneshot
ExecStart=/usr/local/lib/dotfiles/limine-first

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable dotfiles-limine-first.service >/dev/null 2>&1
  /usr/local/lib/dotfiles/limine-first
fi

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
magick -size 286x48 xc:none PNG32:"$DST/entry.png"
magick -background none -fill '#e5383b' -font DejaVu-Sans -pointsize 40 label:$'✱' \
  -trim +repage -resize 22x22 -gravity center -extent 22x22 PNG32:"$DST/bullet.png"
perl -0pi -e 's/bullet\.image\.Scale\(7, 7\)/bullet.image/;
  s/fun position_bullet\(index\) \{.*?\n\}/fun position_bullet(index) {\n  step = bullet.image.GetWidth() + 12;\n  bullet.sprites[index].SetPosition(Window.GetWidth() \/ 2 - (global.bullet_count * step - 12) \/ 2 + index * step, entry.y + entry.image.GetHeight() \/ 2 - bullet.image.GetHeight() \/ 2, 10002);\n}/s;
  s/(  for \(index = 0; index < bullets_to_show; index\+\+\) \{)/  global.bullet_count = bullets_to_show;\n$1/;
  s/(      position_bullet\(index\);\n    \}\n)/    }\n    position_bullet(index);\n/' "$DST/omarchy-black.script"
# With no clock there, say what the screen wants: "enter password" in dim red
# where the stars go, hidden as soon as you start typing.
magick -background none -fill 'rgba(229,56,59,0.75)' -font JetBrains-Mono-Regular -pointsize 26 \
  label:'enter password' PNG32:"$DST/prompt.png"
perl -0pi -e 's/(  global\.bullet_count = bullets_to_show;\n)/$1  pwhint.sprite.SetPosition(Window.GetWidth() \/ 2 - pwhint.image.GetWidth() \/ 2, entry.y + entry.image.GetHeight() \/ 2 - pwhint.image.GetHeight() \/ 2, 10003);\n  if (bullets_to_show == 0) { pwhint.sprite.SetOpacity(1); } else { pwhint.sprite.SetOpacity(0); }\n/;
  s/(fun hide_password_dialog\(\) \{\n)/$1  pwhint.sprite.SetOpacity(0);\n/' "$DST/omarchy-black.script"
cat >>"$DST/omarchy-black.script" <<'PLY'

#----------------------------------------- Password prompt (dotfiles) -------------
pwhint.image = Image("prompt.png");
pwhint.sprite = Sprite(pwhint.image);
pwhint.sprite.SetOpacity(0);
PLY
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

# Claude extension (from the Chrome Web Store), installed for every profile.
cat >/etc/chromium/policies/managed/claude.json <<'JSON'
{
  "ExtensionSettings": {
    "fcoeoabgfenejglbffodgkkbkcdhcgfn": {
      "installation_mode": "normal_installed",
      "update_url": "https://clients2.google.com/service/update2/crx",
      "toolbar_pin": "default_unpinned"
    }
  }
}
JSON
# Minimal browser: no bookmarks bar, home or cast buttons, no new-tab cards,
# and Google AI Mode / Gemini / Lens switched off.
cat >/etc/chromium/policies/managed/minimal.json <<'JSON'
{
  "BookmarkBarEnabled": false,
  "ShowHomeButton": false,
  "ShowAppsShortcutInBookmarkBar": false,
  "ShowCastIconInToolbar": false,
  "NTPCardsVisible": false,
  "NTPCustomBackgroundEnabled": false,
  "NTPFooterExtensionAttributionEnabled": false,
  "NTPFooterManagementNoticeEnabled": false,
  "AIModeSettings": 1,
  "GeminiSettings": 1,
  "LensOverlaySettings": 1,
  "GenAiDefaultSettings": 2
}
JSON
echo "Chromium: Claude extension, minimal toolbar, AI features off"

# ── 5. Battery: Lenovo Conservation mode (stops charging at ~80%) ─────
# BAT1 offers charge_types "Fast Standard Long_Life"; Long_Life is Lenovo's
# Conservation mode. Set it now and on every boot / battery re-detect. Only on
# "add": writing charge_types emits a "change" uevent, so matching "change" here
# loops forever (upowerd + udev pinned at high CPU).
cat >/etc/udev/rules.d/90-dotfiles-battery.rules <<'RULES'
ACTION=="add", SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{charge_types}=="*Long_Life*", ATTR{charge_types}="Long_Life"
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

# ── 6b. Miracast (SUPER+P → Cast): open the Wi-Fi Direct link in ufw ──────
# gnome-network-displays casts over a Wi-Fi Direct group that NetworkManager
# addresses from 10.42.0.0/16 (dnsmasq). The TV needs DHCP/DNS from us, then
# connects back to our RTSP server on TCP 7236. Scoped to that subnet only.
if command -v ufw >/dev/null; then
  ufw allow from 10.42.0.0/16 to any port 67 proto udp comment 'miracast-dhcp' >/dev/null
  ufw allow from 10.42.0.0/16 to any port 53 comment 'miracast-dns' >/dev/null
  ufw allow from 10.42.0.0/16 to any port 7236 proto tcp comment 'miracast-rtsp' >/dev/null
  echo "Miracast: firewall open on the Wi-Fi Direct link (10.42.0.0/16)"
fi

# ── 7. Re-apply all of this automatically after relevant package updates ──
# The hook runs a root-owned copy (never the user-writable file in ~/dotfiles).
self=$(readlink -f "$0"); copy=/usr/local/lib/dotfiles/system-install.sh
if [[ $self != "$copy" ]]; then   # skip when run as the copy (from the hook)
  install -D -m 755 -o root -g root "$self" "$copy"
  install -D -m 755 -o root -g root "$(dirname "$self")/limine-flatten" /usr/local/lib/dotfiles/limine-flatten
  install -D -m 755 -o root -g root "$(dirname "$self")/limine-first" /usr/local/lib/dotfiles/limine-first
fi
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
