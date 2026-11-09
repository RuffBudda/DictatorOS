# Bluetooth for the RTL8852BD radio (Legion 5 15AHP11)

The Bluetooth half of this laptop's Realtek card (USB `0bda:b853`, reports
`rom_version 3`) has no firmware patch in linux-firmware, so it never starts:
`bluetoothctl` says "No default controller available". Windows works because its
driver carries the patch.

`install.sh` makes it work:

- **Firmware:** extracted from Lenovo's own Windows Bluetooth driver, which you
  download (pcsupport.lenovo.com → 83Q7 → Drivers & Software → Bluetooth; in Nov 2026
  it was `71l5037f6macd1k0.exe`, Realtek BT 8852BE 18.4032.0.3008). It's repacked
  by `extract-firmware.py`. No firmware is stored in this repo.
- **Module:** `src/btrtl.c` is the stock Linux 7.2.15 `drivers/bluetooth/btrtl.c`
  with one addition: the "eco4" multi-record firmware loader for this chip, from
  [mihaits/rtl8852bd-bt-linux](https://github.com/mihaits/rtl8852bd-bt-linux)
  (GPL-2.0, see `LICENSE`). It's built with DKMS as `rtl8852bd-bt`.
- **Kernel updates:** a pacman hook (`/etc/pacman.d/hooks/zz-rtl8852bd-bt.hook`)
  puts the module back after every kernel update. DKMS on its own won't replace the
  in-tree module of the same name.

```bash
sudo ~/dotfiles/system/bluetooth-rtl8852bd/install.sh ~/Downloads/<driver>.exe
sudo ~/dotfiles/system/bluetooth-rtl8852bd/install.sh --uninstall   # back to stock
```

The module is unsigned, so it taints the kernel. That's harmless: this kernel
doesn't enforce module signatures, and Secure Boot is off.

Tested on 2026-11-09 with linux-omarchy 7.2.15: `RTL8852BD eco4 firmware loaded (3 records)`.
The controller came up and a scan found nearby devices. The old
`system/bluetooth-rtl8852bd.sh` now just calls this installer.
