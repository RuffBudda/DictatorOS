# DictatorOS

![Omarchy 4.5](https://img.shields.io/badge/Omarchy-4.5-e5383b?style=flat-square&labelColor=0a0a0a) ![Hyprland 0.56 Lua](https://img.shields.io/badge/Hyprland-0.56%20(Lua)-e5383b?style=flat-square&labelColor=0a0a0a) ![Arch Linux](https://img.shields.io/badge/Arch-Linux-e5383b?style=flat-square&labelColor=0a0a0a&logo=archlinux&logoColor=e5383b) ![License: MIT](https://img.shields.io/badge/License-MIT-e5383b?style=flat-square&labelColor=0a0a0a) ![Floating windows: banned](https://img.shields.io/badge/floating%20windows-banned-e5383b?style=flat-square&labelColor=0a0a0a) ![Focus stealing: illegal](https://img.shields.io/badge/focus%20stealing-illegal-e5383b?style=flat-square&labelColor=0a0a0a) ![Colours: red and black](https://img.shields.io/badge/colours-red%20%26%20black-e5383b?style=flat-square&labelColor=0a0a0a)

> **An opinionated [Omarchy](https://omarchy.org) setup.** Windows-style shortcuts, tiling only,
> black and red, desktops across monitors, a minimal lock screen, desktop widgets, and
> dotfiles that Omarchy updates cannot quietly overrule.

## The Manifesto

> *Citizens of the desktop,*
>
> For too long you have lived under the tyranny of choice: windows drifting wherever
> they pleased, colours of every stripe, apps seizing your focus without warning. That era
> is over. By order of the Supreme Leader of this laptop, the following decrees take
> effect immediately.
>
> 1. **Windows shall tile.** Floating is treason. Installer terminals, task monitors and
>    games alike shall stand in line.
> 2. **There is one desktop.** Screens that try to show different workspaces will be
>    re-educated, and a screen that leaves will have its windows returned to the motherland.
> 3. **The colours of the state are red and black.** All other colours are confiscated.
>    The wallpaper is black. It will remain black.
> 4. **No application may seize your attention.** Focus belongs to the people.
> 5. **The bar appears only when summoned** (Super+B). The Leader dislikes clutter.
> 6. **Updates may petition; they may not decree.** Every change an update attempts is
>    detained as a patch and awaits the Leader's approval.
> 7. **The battery shall rest at 80 percent**, for the long-term health of the nation.
> 8. **The state does not sleep.** Closing the lid changes nothing.
> 9. **The clock watches over the lock screen.** It asks no questions. You type; it opens.
> 10. **Alt+Tab is a fundamental right**, as are Win+D, Win+E, Win+P and Ctrl+Shift+Esc.
>
> Long live the tiles.
>
> *(Signed in red ink, RuffBudda, Supreme Leader)*

## Screenshots

| Desktop: widgets on a black wallpaper | Lock screen |
|---|---|
| ![Desktop with WHOOP, CPU/GPU/RAM rings and GitHub graph](docs/desktop.png) | ![Lock screen with a thin red clock](docs/lock-screen.png) |
| *WHOOP (sample values), CPU / GPU / RAM rings, GitHub graph, red bar* | *Type your password; it unlocks when it's complete* |

<p align="center"><img src="docs/monitor-panel.png" alt="Monitor panel with brightness, text size, displays and per-screen scale" width="420"><br><em>Bar monitor panel: brightness, text size, screens, per-screen scale and rotation</em></p>

> Built on Omarchy 4.5 (Hyprland 0.56, Lua config) on a Lenovo Legion 5 15AHP11
> (AMD + NVIDIA). Most of it works on any Omarchy 4.5 machine; the hardware bits
> (battery limit, Bluetooth fix) are Lenovo-specific.

---

## Contents

- [The Manifesto](#the-manifesto)
- [Screenshots](#screenshots)
- [Highlights](#highlights)
- [Requirements](#requirements)
- [Install](#install)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Features in detail](#features-in-detail)
- [How updates are handled](#how-updates-are-handled)
- [Customising](#customising)
- [Undoing / uninstalling](#undoing--uninstalling)
- [Repository layout](#repository-layout)
- [Third-party plugins](#third-party-plugins)
- [Credits and license](#credits-and-license)

---

## Highlights

- **Windows-style shortcuts**: Alt+Tab switcher with live thumbnails, Win+P project
  menu, Win+D show desktop, Win+E files, Win+L lock, Ctrl+Shift+Esc Task Manager,
  Win+Shift+S screenshots.
- **One desktop across all monitors**: Super+1…0 switches every screen together;
  unplugging or re-plugging a monitor keeps windows where they belong.
- **Tiling only**: no floating popups layered over your work (installer terminals,
  btop, Steam… all tile); Super+Left/Right snaps a lone window to half the screen
  without floating it.
- **Black + red**: custom *Red* theme, solid black wallpaper, no logos on boot,
  login or lock screens, rounded corners everywhere. The (hidden) Limine boot menu is red
  on black too, and the boot entry is called DictatorOS.
- **Chromium to match**: red-accented toolbar, tabs down the left side, and a black
  new tab page with only a red Google logo and a search box. No bookmarks bar, no
  AI Mode / Gemini / Lens.
- **Minimal lock screen**: a big thin red clock; type your password and it unlocks
  as soon as it's complete (no Enter). The login and disk-unlock screens look the same.
- **Desktop widgets**: GitHub contribution graph, WHOOP recovery/strain/sleep rings
  and live CPU/GPU/RAM rings, sitting on the wallpaper behind your windows.
- **Bar on demand**: top bar hidden by default, Super+B to show it; transparent with
  red icons. Monitor panel with a built-in screen arranger, per-screen scale and
  rotation.
- **Update-proof**: after every `omarchy update`, your settings are restored and any
  changes the update wanted are saved as a patch for you to approve. System tweaks
  re-apply themselves automatically.

## Requirements

- **Omarchy 4.5** (Arch Linux, Hyprland with the Lua config, Omarchy shell).
- The repo **must be cloned to `~/dotfiles`**: scripts and bindings refer to that path.
- Packages (official Arch repos):
  `ttf-jetbrains-mono mission-center nwg-displays openvpn networkmanager-openvpn`
- Optional:
  - [`gh`](https://cli.github.com) signed in, for the GitHub graph widget.
  - A WHOOP account and developer app, for the WHOOP rings (see [Desktop widgets](#desktop-widgets)).
  - `gnome-network-displays` (AUR; a patched build is included) for wireless casting.

## Install

```bash
git clone https://github.com/RuffBudda/DictatorOS.git ~/dotfiles
~/dotfiles/install.sh                 # user config (safe to re-run)
sudo ~/dotfiles/system/install.sh     # system tweaks (safe to re-run)
sudo pacman -S --needed ttf-jetbrains-mono mission-center nwg-displays openvpn networkmanager-openvpn
omarchy theme set red
```

**`install.sh`** (no root) links these into place, backing up anything it replaces as
`<file>.bak.<timestamp>`, then reloads Hyprland:

- `hypr/` → `~/.config/hypr/` (bindings, desktops, tiling, monitors, input, look and feel, screen-share picker)
- `omarchy/shell.json`, `omarchy/plugins/abu.*`, `omarchy/themes/red`, `omarchy/hooks/…`, `omarchy/branding/…` → `~/.config/omarchy/`
- `applications/*.desktop` → `~/.local/share/applications/`
- `fastfetch/config.jsonc` → `~/.config/fastfetch/`; `bin/fetch` → `~/.local/bin/fetch` and `~/.local/bin/neofetch`

It also edits `~/.config/chromium-flags.conf` (vertical tabs, the `chromium/blank-newtab`
new tab page, no yt-dlp extension) and, while Chromium is closed, turns vertical tabs on
in its profile.

**`system/install.sh`** (root). Each step is idempotent:

1. Limine boot menu hidden (quiet, 1 s: tap any key right after power-on to open it),
   coloured red and black with the entry renamed DictatorOS. To always show it with a
   countdown: `sudo BOOT_MENU=shown BOOT_TIMEOUT=10 ~/dotfiles/system/install.sh`.
2. Black Plymouth boot splash with no logo; the disk-unlock screen says "enter password"
   in dim red, then shows red ✱ stars as you type (no box), like the lock screen.
3. SDDM login screen like the lock screen: thin red clock, red stars, no box.
4. Chromium policies: YouTube notifications blocked, Claude extension installed,
   no bookmarks bar / home / cast buttons or new-tab cards, AI Mode, Gemini and Lens off.
5. Battery: Lenovo *Conservation mode* (charging stops at about 80 %), re-applied on boot.
6. No automatic sleep: closing the lid does nothing (battery or AC).
7. A pacman hook that re-applies all of the above after relevant package updates.
   It runs a root-owned copy of the script, never the user-writable one.

Then the app choices and, optionally, WHOOP:

```bash
~/dotfiles/apps.sh                    # apps, fonts, removals (asks for sudo; safe to re-run)
~/dotfiles/bin/whoop-auth             # connect WHOOP once (rings appear)
```

**`apps.sh`** (asks for sudo):

- **Adds** Claude Desktop, fwupd, Office-compatible fonts (Carlito for Calibri, Caladea
  for Cambria, Liberation/Croscore for Arial, Times New Roman and Courier New) and about 35
  common font families from the Arch repos, plus ~30 more Google Fonts (Poppins,
  Raleway, Playfair Display, Merriweather, Lora, DM Sans…) into `~/.local/share/fonts/google`.
- **Web apps**: keeps WhatsApp and Zoom; adds Outlook, Outlook Calendar and Teams;
  removes Basecamp, X, Discord, HEY, the Google web apps and the Office web apps.
- **Removes** apps this setup doesn't use: Obsidian, Pinta, Kdenlive, OBS, Xournal++,
  cliamp, Aether, Moonlight, LocalSend, Gliff, Superwhisper (and its leftovers), owe,
  Disktree, Evince, yt-dlp, tobi-try, lazygit, ttfx, .NET, Ruby, the
  MariaDB/PostgreSQL client libraries, the Chinese/Japanese/Korean input add-ons
  (the fcitx5 core stays: Omarchy uses it for compose keys), asdcontrol,
  qemu-user-static-binfmt, and `intel-ucode` on AMD machines only.
  Edit `REMOVE_PKGS` at the top to keep any of them.
- **rmdesk**: clones it to `~/Work/rmdesk` and builds its Python environment.

Keep machines in sync with `git -C ~/dotfiles pull` (and commit + push your own changes).

## Keyboard shortcuts

Only the shortcuts that differ from Omarchy's defaults. Full list: `omarchy menu keybindings --print`.

| Keys | Action |
|---|---|
| **Alt+Tab** / Alt+Shift+Tab | Switcher with thumbnails of the windows on the current desktop (all screens). Hold Alt, tap Tab, release to switch; Esc cancels |
| **Super+1…0** | Switch desktop (every screen switches together) |
| **Super+Shift+1…0** | Move window to that desktop (same screen) |
| **Super+Tab** | Next desktop that has windows |
| **Super+Shift+N** | Move window to the first empty desktop |
| **Super+D** | Show desktop (hide all windows on all screens); again to bring them back |
| **Super+Left / Right** | Lone window: snap to the left/right half (stays tiled). With others: move left/right. At the screen edge: move to the next/previous screen, wherever it sits |
| **Super+L** | Lock screen |
| **Super+E** | Files |
| **Ctrl+Shift+Esc** | Task Manager (Mission Center). btop is Super+Shift+T |
| **Super+Shift+S** | Screenshot of a region |
| **Super+P** | Project menu: PC screen only / Duplicate / Extend / Second screen only / Display settings… |
| **Super+N** | Cast to a wireless display (Miracast / Chromecast) |
| **Super+B** | Show / hide the top bar |
| **Super+M** | Sticky notes panel |

## Features in detail

### Windows and desktops

- **Desktops span monitors** (`hypr/desktops.lua`): desktop *N* is workspace *N* on the
  laptop, *N+10* on the second screen, *N+20* on a third. The bar and Alt+Tab show
  desktops, not per-screen workspaces. Unplugging a monitor merges its windows into the
  same desktop on the laptop; plugging it back in sends workspaces home.
- **Tiling only** (`hypr/tiling.lua`): windows Omarchy floats by default tile instead.
  File pickers and save dialogs still float.
- **No focus stealing**: an app asking for attention (for example a terminal finishing a
  task) doesn't pull you to its workspace (`focus_on_activate = false`).
- **Desktop indicator**: a small red number tile top-right for 1.5 s when you switch
  desktops, only while the bar is hidden.

### Lock, login and boot

- **Lock screen** (`omarchy/plugins/abu.lock`): thin red clock, red ✱ stars as you type,
  no box. After one successful unlock it remembers your password **length** (never the
  password; file mode 600) and unlocks as soon as you've typed that many characters.
  A failed automatic attempt turns this off for that lock (for example after a password
  change). The password field only shows on the main screen.
- **Screen stays on while locked on AC power**; on battery it turns off after 5 s.
- **Idle**: no screensaver, no automatic lock, no automatic sleep.
- **Login screen** (SDDM, after logout): the same thin red clock and red stars; press Enter.
- **Disk unlock at boot** (Plymouth): black, "enter password" in dim red until you type,
  then red stars centred, no box (no clock: Plymouth scripts can't read the time).
- **Boot menu** (Limine): hidden; tap a key at power-on to open it. Red on black,
  "DictatorOS" title and entry; Snapper snapshots appear here for rolling back a bad update.
- **Admin password prompts** use Omarchy's standard dialog.

### Chromium

- **Colours**: `omarchy/themes/red/chromium.theme` gives Chromium the red accent, so the
  toolbar, tab strip and focus outlines are red (no Chromium blue).
- **Tabs down the left side** (vertical tabs).
- **New tab page** (`chromium/blank-newtab`, loaded with `--load-extension`): black, red
  Google logo, a DictatorOS-style search box that searches Google. A small background
  script also replaces Chromium's own page in the first tab after start-up.
- **Policies** (`system/install.sh`): Claude extension, no bookmarks bar, home or cast
  buttons, no new-tab cards, AI Mode / Gemini / Lens off, YouTube notifications blocked.

### Bar and panels

- Hidden by default (**Super+B**); transparent with red icons; pushes windows down while
  shown. Auto-hide is built in but off (`autoHide` in `abu.bar/Bar.qml`).
- **Monitor panel** (`abu.monitor`): brightness, text size, a drag-to-arrange screen map,
  and per-screen scale and rotation. Backend: `bin/monitor-layout` writes `hypr/displays.lua`.
- **Notifications** get a ✕ close button.
- **VPN panel** (`abu.openvpn`): OpenVPN profiles, plus **Sign in to a VPN…** with server,
  username and password like the OpenVPN Connect app (downloads your profile from
  OpenVPN Access Server), or enter details manually (`bin/vpn-signin`, `bin/vpn-new`).
- **Sticky notes** (`abu.stickynotes`, Super+M): a bento board of notes in a bar panel.

### Desktop widgets

On the wallpaper layer, behind windows: see them on an empty desktop or with Super+D.
Spacing matches window gaps, and they sit below the bar when it's shown.

- **Top-left: WHOOP** Recovery %, Strain (0–21) and Sleep % rings, refreshed every 15 min.
  One-time setup:
  1. Create an app at <https://developer-dashboard.whoop.com> with redirect URI
     `http://localhost:8765/callback` and scopes `read:recovery read:cycles read:sleep offline`.
  2. Run `~/dotfiles/bin/whoop-auth`, paste the Client ID and Secret, approve in the browser.

  Keys live in `~/.config/whoop/` (mode 600), never in this repo.
- **Top-left, below: CPU / GPU / RAM** rings every 3 s (`bin/sysstats`). GPU shows the busier
  of the AMD iGPU and the NVIDIA card; the NVIDIA card is only read while it's already awake.
- **Top-right: GitHub** contribution graph in red, every 30 min, from the signed-in `gh`
  account (`bin/github-contrib`).

### Displays, casting and screen sharing

- **Super+P** project menu, and **Display settings…** (nwg-displays, writing `hypr/displays.lua`).
- **Super+N** casting through GNOME Network Displays' background service, in the same
  menu style. `packages/gnome-network-displays` builds a patched version that doesn't
  crash on close.
- **Screen-share picker** (`bin/share-picker`): a simple menu of screens, windows and
  "Select a region" instead of the thumbnail window.

### `fetch` / `neofetch`

`fastfetch/config.jsonc` + `fastfetch/logo.txt`: system info reads **DictatorOS (Omarchy x.y)** in red,
with a parody logo (a crown over a grid of tiles). `fetch` and `neofetch` (`bin/fetch`, linked into
`~/.local/bin`) both run it; neofetch itself is discontinued.

### Theme

`omarchy/themes/red`: black backgrounds, red accents, red icon set, transparent bar with
red icons, red lock screen. The wallpaper is forced to solid black on every theme change.

### Hardware (Lenovo Legion)

- `system/install.sh` step 5: battery Conservation mode via `charge_types = Long_Life`.
- `system/bluetooth-rtl8852bd.sh`: Bluetooth for the Realtek RTL8852BD (patched `btrtl`
  via DKMS plus firmware from Lenovo's Windows driver, re-applied after kernel updates).

### Other

- **Notifications** hide after 10 s, urgent ones included (they stay in the history).
- `apps.sh`: app choices (fonts, removals, Claude Desktop, fwupd, web apps, rmdesk;
  see [Install](#install)).
- `bin/rmdesk` + launcher: a reMarkable 2 desktop app (separate project with its own venv).
- `bin/block-text`: render text in the Omarchy logo's block-letter style.
- `preview/`: HTML mock-ups used while designing the lock screen.

## How updates are handled

Omarchy updates can't change your setup without your approval:

1. **Your settings**: after every `omarchy update`, `bin/dotfiles-check` (an Omarchy
   post-update hook) re-links the dotfiles. If the update edited them, the edits are saved
   to `updates/*.patch` (git-ignored, local only), your version is restored, and you get a
   notification. Apply a suggestion you like with `git -C ~/dotfiles apply updates/<file>.patch`.
2. **System tweaks**: the pacman hook from `system/install.sh` re-applies the boot splash,
   login screen, YouTube block, battery limit and lid setting after relevant updates.
3. **Health checks**: the post-update check also warns about Hyprland config errors,
   custom widgets that fail to load, and the unpatched Network Displays coming back.

Run the check any time: `~/dotfiles/bin/dotfiles-check`.

## Customising

Edit files in `~/dotfiles` (the ones in `~/.config` are symlinks), then:

| You edited | Apply with |
|---|---|
| `hypr/*.lua` | applied on save; check `hyprctl configerrors` |
| `omarchy/plugins/*` | `omarchy restart shell` |
| `omarchy/themes/red/*` | `omarchy theme set red` |
| `system/install.sh` | `sudo ~/dotfiles/system/install.sh` (also refreshes the hook's root-owned copy) |

Common tweaks:

- Lock screen back to a boxed field: set `clockStyle: false` in `abu.lock/LockView.qml`.
- A name above the lock screen password: `bin/block-text YOUR NAME > omarchy/plugins/abu.lock/name-art.txt`.
- Show the boot menu longer, or never: `sudo BOOT_TIMEOUT=3 ~/dotfiles/system/install.sh` (or `0`).
- Auto-lock again: set `idle.lock` (in seconds) in `omarchy/shell.json`.

## Undoing / uninstalling

- Each linked file's original was saved as `<file>.bak.<timestamp>` next to it: remove the
  symlink and rename the backup back.
- `omarchy refresh hyprland` and `omarchy refresh shell` reset to Omarchy's defaults.
- System tweaks: delete `/etc/pacman.d/hooks/zz-dotfiles-system.hook`,
  `/etc/sddm.conf.d/zz-dotfiles.conf`, `/etc/systemd/logind.conf.d/dotfiles-lid.conf`,
  `/etc/udev/rules.d/90-dotfiles-battery.rules` and
  `/etc/chromium/policies/managed/{dotfiles,claude,minimal}.json`, then run
  `sudo plymouth-set-default-theme omarchy && sudo limine-mkinitcpio`. The Limine
  colours and entry name are restored from `/boot/limine.conf.bak.<timestamp>`; also
  remove `TARGET_OS_NAME` from `/etc/default/limine`.
- Chromium: remove the `blank-newtab` path and `VerticalTabs` from
  `~/.config/chromium-flags.conf`.
- Apps removed by `apps.sh` can be reinstalled with `omarchy-pkg-add <name>`.

## Repository layout

```
applications/        launcher entries (Display settings, New VPN profile, rmdesk)
backgrounds/         black wallpaper
bin/                 scripts used by bindings, widgets and hooks
chromium/            black search-only new tab page (Chromium extension)
docs/                README images
fastfetch/           fastfetch config and the DictatorOS logo
hypr/                Hyprland config: bindings, desktops, tiling, monitors, displays, input, look and feel
icons/               app icons
omarchy/
  branding/          blank screensaver and fastfetch logo
  hooks/             theme-set (black wallpaper) and post-update (dotfiles check) hooks
  plugins/abu.*      custom shell plugins (bar, lock, alt-tab, monitor, widgets, VPN, notes…)
  shell.json         bar layout and shell settings
  themes/red/        the Red theme
packages/            patched gnome-network-displays build
preview/             design mock-ups
system/              root-level tweaks (install.sh, Bluetooth fix)
install.sh           user-level installer
apps.sh              app choices: fonts, removals, web apps, rmdesk
```

## Third-party plugins

Installed from their own repos (not included here):

```bash
omarchy plugin add https://github.com/nuo-yi/omarchy-power-widget.git --enable --yes        # Power + CPU Boost
omarchy plugin add https://github.com/rmarchei/omarchy-openvpn-plugin.git --enable --yes    # OpenVPN Profiles (abu.openvpn replaces it in the bar)
```

## Credits and license

DictatorOS is released under the [MIT License](LICENSE).

Built on [Omarchy](https://github.com/basecamp/omarchy) by David Heinemeier Hansson (MIT).
Several plugins are adapted from Omarchy's built-ins and from
[rmarchei/omarchy-openvpn-plugin](https://github.com/rmarchei/omarchy-openvpn-plugin) (MIT);
the GNOME Network Displays patch is GPL-3.0-or-later. Details in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
