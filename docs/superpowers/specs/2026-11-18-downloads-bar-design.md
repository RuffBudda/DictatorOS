# Downloads in the bar

## Why
Web apps (Outlook, SharePoint, Teams) run as Chromium `--app` windows without a toolbar.
Thus the Chromium download bubble does not show. You cannot see that a download started,
its progress, or that it is complete.

## Goals
- A bar icon (as in `abu.printjobs`) with a small animation while a download runs.
- A click on the icon opens a panel. For each download, the panel shows:
  - The name, a progress bar, the bytes received and the total bytes, the speed and the time left.
  - Pause, Resume and Cancel while the download runs.
  - Open and Show in folder when the download is complete.
- The icon stays for about 10 minutes after the last download stops. Thus you can open the
  recent items. A Clear button removes them.
- Keep the "Download complete" notification. The real Chromium state must control it. A
  cancelled download must not show "complete".

## Non-goals
Firefox or other browsers. Download history from before this session. Changes to the
location where the files go.

## Approaches
1. **Watch only ~/Downloads.** This gives no total size, thus no ETA, and no reliable
   cancel. Rejected.
2. **A Chromium extension and a native messaging host (selected).** `chrome.downloads` gives
   the totals, the ETA, and pause, resume and cancel. It also covers app windows, because
   they use the same profile. It agrees with the current `--load-extension` pattern in
   `~/.config/chromium-flags.conf`.
3. **The Chromium remote debugging port.** This opens the full browser on a local port.
   Rejected because of security.

## Design
- `chromium/downloads-bridge/`: an MV3 extension with a fixed `key` (a stable ID).
  - Its background service worker connects to the native host `dev.abu.downloads`.
  - At each `chrome.downloads` change, it sends a full snapshot of the active and recent
    downloads. While a download runs, it sends a maximum of about one snapshot each second.
  - It does the `pause|resume|cancel|open|show|clear` commands that it gets.
- `bin/downloads-host`: the native messaging host (Python).
  - It writes the snapshot to `$XDG_RUNTIME_DIR/abu-downloads/state.json` in one atomic
    operation.
  - It gets commands from the bar through a Unix socket in the same 0700 directory. It sends
    on only the approved actions with integer ids.
  - It sends the completion notification.
- `omarchy/plugins/abu.downloads`: the bar widget, made as `abu.printjobs` is. It reads the
  state file.
- Remove the earlier inotify `download-notify` service. The host replaces it.

## Left to the builder
The visuals follow `abu.printjobs`. The animation is a down-arrow that moves up and down
slowly.
