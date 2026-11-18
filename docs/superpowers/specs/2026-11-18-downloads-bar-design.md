# Downloads in the bar

## Why
Web apps (Outlook, SharePoint, Teams) run as Chromium `--app` windows with no toolbar,
so Chromium's download bubble never shows. There's no sign a download started, how far
along it is, or that it finished.

## Goals
- Bar icon (like `abu.printjobs`) with a small downloading animation while anything downloads.
- Click opens a panel: per download name, progress bar, bytes done/total, speed, time left;
  Pause / Resume / Cancel while running; Open / Show in folder once finished.
- Icon stays ~10 minutes after the last download ends so recent items can be opened; a Clear button.
- Keep the "Download complete" notification, driven by real Chromium state (no false
  "complete" for cancelled downloads).

## Non-goals
Firefox or other browsers; download history beyond this session; changing where files save.

## Approaches
1. **Watch ~/Downloads only** — no total size, so no ETA, and no reliable cancel. Rejected.
2. **Chromium extension + native messaging host (picked)** — `chrome.downloads` gives
   totals, ETA, pause/resume/cancel, and covers app windows because they share the profile.
   Fits the existing `--load-extension` pattern in `~/.config/chromium-flags.conf`.
3. **Chromium remote debugging port** — exposes the whole browser on a local port. Rejected for security.

## Design
- `chromium/downloads-bridge/` — MV3 extension with a fixed `key` (stable ID). Background
  service worker connects to native host `dev.abu.downloads`, sends a full snapshot of active
  and recent downloads on every `chrome.downloads` change (throttled ~1/s while running), and
  executes `pause|resume|cancel|open|show|clear` commands it receives.
- `bin/downloads-host` — native messaging host (Python). Writes the snapshot atomically to
  `$XDG_RUNTIME_DIR/abu-downloads/state.json`; accepts commands from the bar over a Unix
  socket in the same 0700 directory and forwards only whitelisted actions with integer ids;
  sends the completion notification.
- `omarchy/plugins/abu.downloads` — bar widget modelled on `abu.printjobs`, reads the state file.
- The inotify `download-notify` service from earlier is removed (the host replaces it).

## Left to the builder
Exact visuals follow `abu.printjobs`; animation is a gently bobbing down-arrow.
