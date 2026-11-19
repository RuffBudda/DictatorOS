# Bluetooth for the RTL8852BD radio (Legion 5 15AHP11)

The Realtek card of this laptop has a Bluetooth part (USB `0bda:b853`, it reports
`rom_version 3`). linux-firmware has no firmware patch for it. Thus it does not start, and
`bluetoothctl` shows "No default controller available". Windows works because its driver
contains the patch.

`install.sh` makes the radio work:

- **Firmware:** The script takes the firmware from the Lenovo Windows Bluetooth driver.
  - Download the driver from pcsupport.lenovo.com → 83Q7 → Drivers & Software → Bluetooth.
    In Nov 2026, the file was `71l5037f6macd1k0.exe` (Realtek BT 8852BE 18.4032.0.3008).
  - `extract-firmware.py` puts the firmware into the correct format.
  - This repository contains no firmware.
- **Module:** `src/btrtl.c` is the standard Linux 7.2.15 `drivers/bluetooth/btrtl.c` with
  one addition: the "eco4" multi-record firmware loader for this chip. The loader comes from
  [mihaits/rtl8852bd-bt-linux](https://github.com/mihaits/rtl8852bd-bt-linux)
  (GPL-2.0, refer to `LICENSE`). DKMS builds the module as `rtl8852bd-bt`.
- **Kernel updates:** A pacman hook (`/etc/pacman.d/hooks/zz-rtl8852bd-bt.hook`) installs
  the module again after each kernel update. DKMS alone does not replace the in-tree module
  with the same name.

```bash
sudo ~/dotfiles/system/bluetooth-rtl8852bd/install.sh ~/Downloads/<driver>.exe
sudo ~/dotfiles/system/bluetooth-rtl8852bd/install.sh --uninstall   # back to stock
```

The module has no signature, thus it taints the kernel. This causes no problem: this kernel
does not enforce module signatures, and Secure Boot is off.

Test result on 2026-11-09 with linux-omarchy 7.2.15: `RTL8852BD eco4 firmware loaded (3 records)`.
The controller started, and a scan found devices near the laptop. The old
`system/bluetooth-rtl8852bd.sh` now only starts this installer.
