#!/bin/bash
# App selection on top of a fresh Omarchy install. Safe to re-run.
# Prompts for sudo for package changes (run it in a terminal).
set -euo pipefail

# ── Packages to remove ─────────────────────────────────────
REMOVE_PKGS=(
  # apps
  kdenlive obs-studio pinta xournalpp cliamp aether
  moonlight-qt localsend gliff superwhisper-bin owe disktree-bin evince yt-dlp
  # terminal / developer extras
  tobi-try lazygit ttfx     # (herdr stays: Omarchy starts its server at login)
  dotnet-runtime ruby rubygems mariadb-libs postgresql-libs
  # Chinese/Japanese/Korean input add-ons (the fcitx5 core stays: Omarchy uses it
  # for Shift+CapsLock compose sequences)
  fcitx5-chewing fcitx5-chinese-addons fcitx5-hangul fcitx5-mozc fcitx5-table-extra
  # hardware helpers this laptop doesn't need
  asdcontrol qemu-user-static-binfmt
)
# Intel microcode is only useless on AMD CPUs; keep it anywhere else.
grep -q AuthenticAMD /proc/cpuinfo && REMOVE_PKGS+=(intel-ucode)

# ── Packages to add ────────────────────────────────────────
ADD_PKGS=(claude-desktop fwupd obsidian)          # claude-desktop comes from the omarchy repo

# rmdesk (reMarkable app) runtime libraries
RMDESK_PKGS=(pyside6 python-paramiko python-keyring python-opencv python-numpy
             python-requests python-websocket-client python-pytest python-pytest-qt)

# Fonts: Office metric-compatible (Calibri → Carlito, Cambria → Caladea,
# Arial/Times/Courier → Liberation + Croscore) and common Google/web fonts.
FONT_PKGS=(
  ttf-carlito ttf-caladea ttf-liberation ttf-croscore ttf-dejavu
  ttf-roboto ttf-roboto-mono ttf-opensans ttf-lato ttf-montserrat ttf-nunito
  ttf-fira-sans ttf-fira-mono ttf-fira-code ttf-ubuntu-font-family ttf-droid
  inter-font ttf-ibm-plex adobe-source-sans-fonts adobe-source-serif-fonts
  adobe-source-code-pro-fonts ttf-sourcecodepro-nerd noto-fonts-extra
  ttf-anonymous-pro ttf-inconsolata ttf-cascadia-code ttf-jetbrains-mono ttf-hack
  gnu-free-fonts tex-gyre-fonts ttf-bitstream-vera ttf-cormorant otf-libertinus
  ttf-linux-libertine
)

# Add first, and mark rmdesk's libraries as explicitly installed, so the
# removals below can't take them out as orphaned dependencies.
omarchy-pkg-add "${ADD_PKGS[@]}" "${RMDESK_PKGS[@]}" "${FONT_PKGS[@]}"
sudo pacman -D --asexplicit "${RMDESK_PKGS[@]}" >/dev/null
omarchy-pkg-drop "${REMOVE_PKGS[@]}"

# Superwhisper leaves a daemon and settings behind after the package is gone.
pkill -x superwhisper 2>/dev/null || true
rm -rf ~/.config/superwhisper ~/.local/share/superwhisper ~/.cache/superwhisper

# ── Google Fonts not packaged in Arch (from github.com/google/fonts) ──
GOOGLE_FONTS=(raleway playfairdisplay merriweather poppins worksans crimsontext oswald
              ptsans ptserif rubik mulish dmsans karla barlow quicksand josefinsans
              librebaskerville ebgaramond lora spacegrotesk manrope bebasneue archivo
              outfit nunitosans firasans sourcesans3 notosans)
GF_DIR=~/.local/share/fonts/google
if [[ -z $(ls -A "$GF_DIR" 2>/dev/null) ]]; then
  tmp=$(mktemp -d)
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/google/fonts.git "$tmp/gf"
  git -C "$tmp/gf" sparse-checkout set "${GOOGLE_FONTS[@]/#/ofl/}"
  mkdir -p "$GF_DIR"
  find "$tmp/gf/ofl" -name '*.ttf' -exec cp {} "$GF_DIR/" \;
  rm -rf "$tmp"
  fc-cache -f >/dev/null
  echo "Google Fonts: $(ls "$GF_DIR" | wc -l) files in $GF_DIR"
fi

# ── Web apps ───────────────────────────────────────────────
REMOVE_WEBAPPS=(Basecamp X Discord HEY "Google Contacts" "Google Maps" "Google Messages" "Google Photos"
                Word PowerPoint Excel SharePoint OneDrive)
for app in "${REMOVE_WEBAPPS[@]}"; do
  [[ -f ~/.local/share/applications/$app.desktop ]] && OMARCHY_REMOVE_NOTIFY=false omarchy-webapp-remove "$app"
done

# Keep Omarchy's WhatsApp and Zoom launchers (copied in if missing).
for app in WhatsApp Zoom; do
  src="/usr/share/omarchy/applications/$app.desktop"
  if [[ -f $src && ! -f ~/.local/share/applications/$app.desktop ]]; then
    cp "$src" ~/.local/share/applications/ && echo "added web app $app"
  fi
done

ICONS=https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png
add_webapp() {  # add_webapp <name> <url> <icon>
  [[ -f ~/.local/share/applications/$1.desktop ]] && return
  omarchy-webapp-install "$1" "$2" "$ICONS/$3.png"
  echo "added web app $1"
}
add_webapp Outlook    "https://outlook.office.com/mail/"          microsoft-outlook
add_webapp "Outlook Calendar" "https://outlook.office.com/calendar/" microsoft-365
add_webapp Teams     "https://teams.microsoft.com/v2/"           microsoft-teams
update-desktop-database ~/.local/share/applications &>/dev/null || true

# ── rmdesk (reMarkable 2 desktop app), used by ~/dotfiles/bin/rmdesk ──
[[ -d ~/Work/rmdesk ]] || { mkdir -p ~/Work && git clone -q https://github.com/RuffBudda/rmdesk.git ~/Work/rmdesk; }
[[ -x ~/.local/share/rmdesk/venv/bin/python ]] || ~/Work/rmdesk/scripts/setup-venv.sh

echo "Done."
