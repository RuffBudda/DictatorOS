#!/bin/bash
# User-level dotfiles installer. Safe to re-run any time.
# Existing files are backed up to <file>.bak.<timestamp> before being linked.
# For boot/login-screen changes run:  sudo ~/dotfiles/system/install.sh
set -euo pipefail
DOT="$(cd "$(dirname "$0")" && pwd)"
ts=$(date +%s)

link() {  # link <source-in-dotfiles> <target>
  local src="$DOT/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L $dst && $(readlink "$dst") == "$src" ]]; then return; fi
  if [[ -e $dst || -L $dst ]]; then mv "$dst" "$dst.bak.$ts"; echo "backed up $dst"; fi
  ln -s "$src" "$dst"; echo "linked $dst"
}

link hypr/bindings.lua                         ~/.config/hypr/bindings.lua
link hypr/monitors.lua                         ~/.config/hypr/monitors.lua
link hypr/input.lua                            ~/.config/hypr/input.lua
link hypr/looknfeel.lua                        ~/.config/hypr/looknfeel.lua
link hypr/hyprland.lua                         ~/.config/hypr/hyprland.lua
link hypr/tiling.lua                           ~/.config/hypr/tiling.lua
link hypr/desktops.lua                         ~/.config/hypr/desktops.lua
link hypr/contain.lua                          ~/.config/hypr/contain.lua
link applications/nwg-displays.desktop          ~/.local/share/applications/nwg-displays.desktop
link applications/vpn-new.desktop               ~/.local/share/applications/vpn-new.desktop
link applications/rmdesk.desktop                ~/.local/share/applications/rmdesk.desktop
link icons/rmdesk.svg                           ~/.local/share/icons/hicolor/scalable/apps/rmdesk.svg
link hypr/xdph.conf                            ~/.config/hypr/xdph.conf
link omarchy/shell.json                        ~/.config/omarchy/shell.json
link omarchy/branding/about.txt                ~/.config/omarchy/branding/about.txt
link omarchy/branding/screensaver.txt          ~/.config/omarchy/branding/screensaver.txt
link omarchy/hooks/theme-set.d/black-background ~/.config/omarchy/hooks/theme-set.d/black-background
link omarchy/hooks/post-update.d/dotfiles-check.hook ~/.config/omarchy/hooks/post-update.d/dotfiles-check.hook
link omarchy/plugins/abu.notifications         ~/.config/omarchy/plugins/abu.notifications
link omarchy/plugins/abu.alttab              ~/.config/omarchy/plugins/abu.alttab
link omarchy/plugins/abu.lock                ~/.config/omarchy/plugins/abu.lock
link omarchy/plugins/abu.workspaces          ~/.config/omarchy/plugins/abu.workspaces
link omarchy/plugins/abu.bar                 ~/.config/omarchy/plugins/abu.bar
link omarchy/plugins/abu.monitor             ~/.config/omarchy/plugins/abu.monitor
link omarchy/plugins/abu.github-graph        ~/.config/omarchy/plugins/abu.github-graph
link omarchy/plugins/abu.openvpn             ~/.config/omarchy/plugins/abu.openvpn
link omarchy/plugins/abu.desktop-osd         ~/.config/omarchy/plugins/abu.desktop-osd
link omarchy/plugins/abu.stickynotes         ~/.config/omarchy/plugins/abu.stickynotes
link omarchy/plugins/abu.power             ~/.config/omarchy/plugins/abu.power
link omarchy/plugins/abu.wallpaper-fade      ~/.config/omarchy/plugins/abu.wallpaper-fade
link omarchy/themes/red                      ~/.config/omarchy/themes/red
link fastfetch/config.jsonc                    ~/.config/fastfetch/config.jsonc
link bin/fetch                                ~/.local/bin/fetch
link bin/fetch                                ~/.local/bin/neofetch

chmod +x "$DOT"/bin/*

# ── Chromium: tabs on the left + black search-only new tab page ──
# (Colours come from the Red theme's chromium.theme; policies from system/install.sh.)
FLAGS=~/.config/chromium-flags.conf
if [[ -f $FLAGS ]]; then
  # Omarchy's yt-dlp extension needs yt-dlp, which apps.sh removes.
  sed -i 's#,/usr/share/omarchy/default/chromium/extensions/yt-dlp##' "$FLAGS"
  grep -q '^--enable-features=' "$FLAGS" || echo '--enable-features=VerticalTabs' >>"$FLAGS"
  sed -i '/^--enable-features=/{/VerticalTabs/!s/$/,VerticalTabs/}' "$FLAGS"
  grep -q '^--load-extension=' "$FLAGS" || echo "--load-extension=$DOT/chromium/blank-newtab" >>"$FLAGS"
  grep -q "$DOT/chromium/blank-newtab" "$FLAGS" || sed -i "s#^--load-extension=.*#&,$DOT/chromium/blank-newtab#" "$FLAGS"
  grep -q "$DOT/chromium/outlook-red" "$FLAGS" || sed -i "s#^--load-extension=.*#&,$DOT/chromium/outlook-red#" "$FLAGS"
  echo "Chromium flags: vertical tabs, new tab page"
fi
# Turn vertical tabs on in the profile (only while Chromium is closed, as it
# rewrites its Preferences file on exit).
PREFS=~/.config/chromium/Default/Preferences
if [[ -f $PREFS ]] && ! pgrep -x chromium >/dev/null; then
  python3 -I - "$PREFS" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.setdefault("vertical_tabs", {})["enabled"] = True
ntp = d.setdefault("ntp", {})
ntp["shortcust_visible"] = False          # (sic) Chromium's pref name
ntp["animated_doodles_enabled"] = False
json.dump(d, open(p, "w"), separators=(",", ":"))
PY
  echo "Chromium: vertical tabs on"
fi

# ── Obsidian: "Ask the Vault" (local AI over your notes, via Ollama) ──
# Linked into every vault Obsidian knows about, and enabled there.
if [[ -f ~/.config/obsidian/obsidian.json ]]; then
  while IFS= read -r vault; do
    [[ -d $vault/.obsidian ]] || continue
    mkdir -p "$vault/.obsidian/plugins"
    ln -sfn "$DOT/obsidian/vault-ask" "$vault/.obsidian/plugins/dictatoros-vault-ask"
    python3 -I - "$vault/.obsidian/community-plugins.json" <<'PY2'
import json, os, sys
p = sys.argv[1]; d = json.load(open(p)) if os.path.exists(p) else []
if "dictatoros-vault-ask" not in d: d.append("dictatoros-vault-ask")
json.dump(d, open(p, "w"))
PY2
    echo "Obsidian: Ask the Vault in $vault"
  done < <(jq -r '.vaults | values[].path' ~/.config/obsidian/obsidian.json 2>/dev/null)
fi

# Apply now
omarchy-theme-bg-set "$DOT/backgrounds/red-stripes.png" || true
if command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null && hyprctl configerrors
fi
echo "Done. Run 'omarchy restart shell' if toast changes don't show up."

