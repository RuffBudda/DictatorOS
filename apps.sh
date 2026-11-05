#!/bin/bash
# App selection on top of a fresh Omarchy install. Safe to re-run.
# Prompts for sudo for package changes (run it in a terminal).
set -euo pipefail

# ── Packages ───────────────────────────────────────────────
REMOVE_PKGS=(kdenlive obs-studio obsidian pinta xournalpp cliamp aether)
ADD_PKGS=(claude-desktop fwupd)          # claude-desktop comes from the omarchy repo

omarchy-pkg-drop "${REMOVE_PKGS[@]}"
omarchy-pkg-add "${ADD_PKGS[@]}"

# ── Web apps ───────────────────────────────────────────────
REMOVE_WEBAPPS=(Basecamp X Discord HEY "Google Contacts" "Google Maps" "Google Messages" "Google Photos"
                Word PowerPoint Excel SharePoint OneDrive)
for app in "${REMOVE_WEBAPPS[@]}"; do
  [[ -f ~/.local/share/applications/$app.desktop ]] && OMARCHY_REMOVE_NOTIFY=false omarchy-webapp-remove "$app"
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

echo "Done."
