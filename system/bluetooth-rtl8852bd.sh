#!/bin/bash
# Moved: the Bluetooth fix for the Legion 5 15AHP11's RTL8852BD now lives in
# system/bluetooth-rtl8852bd/ (stock-kernel btrtl + the eco4 loader, no
# download at install time). This wrapper keeps the old command working.
#
#   sudo ~/dotfiles/system/bluetooth-rtl8852bd.sh ~/Downloads/<lenovo-bt-driver>.exe
#   sudo ~/dotfiles/system/bluetooth-rtl8852bd.sh --uninstall
exec "$(dirname "$(readlink -f "$0")")/bluetooth-rtl8852bd/install.sh" "$@"
