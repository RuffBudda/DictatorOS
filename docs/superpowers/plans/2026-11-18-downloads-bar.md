# Downloads in the bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bar icon that shows an animation while Chromium downloads. It has a panel that shows the progress, the speed and the ETA, with pause, resume, cancel and open.

**Architecture:** An MV3 Chromium extension reads `chrome.downloads`. It sends snapshots through native messaging to a Python host. The host writes a state file and operates a Unix control socket. A Quickshell bar widget reads the file. It sends commands through `downloads-host ctl`.

**Tech Stack:** Chromium MV3 extension (JS), Python 3 stdlib, Quickshell/QML (Omarchy shell plugin).

**Spec:** `docs/superpowers/specs/2026-11-18-downloads-bar-design.md`

## Global Constraints
- The native host name is `dev.abu.downloads`. The runtime directory is `$XDG_RUNTIME_DIR/abu-downloads/` (mode 0700). It contains `state.json` and `ctl.sock`.
- The approved control actions are `pause|resume|cancel|open|show` (these require an integer id) and `clear` (no id). For all other actions, the reply is `{"ok":false,"error":...}`.
- The recent items stay visible for 10 minutes after `ended`.
- All text that the user sees is plain text. File names are not trusted.

## Data contract — `state.json`
`{"connected": true, "updated": <ms>, "downloads": [ {"id": int, "name": str, "path": str, "state": "in_progress"|"complete"|"interrupted", "paused": bool, "canResume": bool, "received": int, "total": int (0 = unknown), "speed": number (B/s), "eta": int (s, -1 unknown), "error": str, "started": ms, "ended": ms (0 if running)} ]}`. The newest download is first.

Control CLI: `downloads-host ctl <action> [id]` prints one JSON line `{"ok":bool,"error"?:str}`. The exit code is 0 if the result is ok, and 1 if not.

## Review Focus
- Chromium does not run (no host): the widget is hidden. `ctl` returns `{"ok":false,"error":"Chromium isn't running"}`.
- The total size is not known (`total` 0): the progress bar is indeterminate and there is no ETA. The bytes and the speed still show.
- File names with spaces, quotes, `$()` and newlines: send them only as argv. Never send them through a shell.
- A cancelled download (`USER_CANCELED`) must not send a "complete" or "failed" notification.
- Chromium starts the host again while the widget runs: the host replaces the old socket file and writes the state again.

---

### Task 1: Native host (`bin/downloads-host`)
**Files:** Create `bin/downloads-host` (Python, executable) and `bin/tests/test_downloads_host.py`.
**Interfaces — Produces:** `read_message(stream)->dict|None`, `write_message(stream, obj)`, `validate_command(obj)->(ok:bool, err:str)`, `transitions(prev:dict[int,str], downloads:list)->list[(kind:"complete"|"failed", item)]`, `apply_clear(downloads, cleared:set)->set`, `main(argv)`. If argv[1] is "ctl", the program operates as a client. If not, it operates as the host (Chromium gives the origin as argv[1]).
- [ ] Tests: Framing gives the same message back (4-byte native-endian length and UTF-8 JSON). `validate_command({"action":"rm","id":1})` is false. `{"action":"pause","id":"1"}` is false (the id must be an int). `clear` without an id is true. `transitions` reports complete only for ids that were `in_progress` before. It reports failed for an interrupted download with an error that is not `USER_CANCELED`. It reports nothing for a cancelled download.
- [ ] Implement. Host mode: a stdin reader thread, a socket server thread, and an atomic state write (tmp file, then rename). Send the notification through `omarchy-notification-send` with the actions Open and Show folder (argv only). On stdin EOF, remove the state file and the socket.
- [ ] Run `python3 -m unittest bin/tests/test_downloads_host.py -v`. All tests must pass.

### Task 2: Extension (`chromium/downloads-bridge/`)
**Files:** `manifest.json` (MV3, `key`, permissions `downloads` and `nativeMessaging`), `background.js`, and the `chromium/NativeMessagingHosts/dev.abu.downloads.json` template.
- [ ] Connect on load, on startup and on install. After a disconnect, connect again with backoff.
  - The snapshot is `downloads.search({orderBy:["-startTime"], limit:20})`, with only the last 24 h, mapped to the data contract.
  - Send it on onCreated, onChanged and onErased, and every 1 s while a download is in_progress.
  - Calculate the speed from consecutive snapshots (EMA). Calculate the ETA from `estimatedEndTime`. If that is not available, use (total-received)/speed.
- [ ] Handle `{"action": pause|resume|cancel, "id"}` from the host.
- [ ] Verify manually: Load the extension in Chromium. Start a large download. Make sure that `cat $XDG_RUNTIME_DIR/abu-downloads/state.json` changes each second.

### Task 3: Bar widget (`omarchy/plugins/abu.downloads/`)
**Files:** `manifest.json`, and `Panel.qml` made as `abu.printjobs` is.
- [ ] Read state.json (FileView or a 1 s poll).
  - The widget is visible if a download is in_progress, if a download `ended` in the last 10 minutes, or if the panel is open.
  - The icon 󰇚 moves up and down while a download runs.
  - Each row shows the name and a progress bar. The bar is indeterminate when total is 0.
  - Each row shows text such as "12.0 of 40.0 MB · 2.1 MB/s · 18 s left".
  - While a download runs, the row has Pause/Resume and Cancel. When it is complete, the row has Open and Show folder. When it is interrupted, the row shows the error text.
  - The Clear button in the header sends `ctl clear`.
- [ ] Verify manually in the bar with a real download.

### Task 4: Install wiring + retire `download-notify`
- [ ] `install.sh`: Link the host to `~/.local/bin/downloads-host`. Write the NativeMessagingHosts manifest with the absolute path. Add the extension to `--load-extension`. Copy the plugin. Remove the download-notify service lines. Remove `bin/download-notify` and `systemd/download-notify.service`, and disable the unit.
- [ ] Verify: Run `./install.sh` again. Start Chromium again. Download a file. Make sure that the icon shows, that the notification shows on completion, and that cancel works.
