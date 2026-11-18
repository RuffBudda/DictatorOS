# Downloads in the bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bar icon that animates while Chromium downloads, with a panel showing progress/speed/ETA and pause/resume/cancel/open.

**Architecture:** MV3 Chromium extension reads `chrome.downloads` and streams snapshots over native messaging to a Python host. The host writes a state file and serves a Unix control socket; a Quickshell bar widget reads the file and sends commands through `downloads-host ctl`.

**Tech Stack:** Chromium MV3 extension (JS), Python 3 stdlib, Quickshell/QML (Omarchy shell plugin).

**Spec:** `docs/superpowers/specs/2026-11-18-downloads-bar-design.md`

## Global Constraints
- Native host name: `dev.abu.downloads`. Runtime dir: `$XDG_RUNTIME_DIR/abu-downloads/` (mode 0700) holding `state.json` and `ctl.sock`.
- Control actions whitelist: `pause|resume|cancel|open|show` (require integer id) and `clear` (no id). Anything else → `{"ok":false,"error":...}`.
- Recent items stay visible 10 minutes after `ended`.
- All user-visible text is plain text (file names are untrusted).

## Data contract — `state.json`
`{"connected": true, "updated": <ms>, "downloads": [ {"id": int, "name": str, "path": str, "state": "in_progress"|"complete"|"interrupted", "paused": bool, "canResume": bool, "received": int, "total": int (0 = unknown), "speed": number (B/s), "eta": int (s, -1 unknown), "error": str, "started": ms, "ended": ms (0 if running)} ]}` newest first.

Control CLI: `downloads-host ctl <action> [id]` prints one JSON line `{"ok":bool,"error"?:str}`; exit 0 on ok, 1 otherwise.

## Review Focus
- Chromium not running (no host): widget hidden, `ctl` returns `{"ok":false,"error":"Chromium isn't running"}`.
- Unknown total size (`total` 0): indeterminate progress bar, no ETA, still shows bytes + speed.
- File names with spaces, quotes, `$()`, newlines: passed only as argv, never through a shell.
- Cancelled download (`USER_CANCELED`) must not notify "complete" or "failed".
- Host restarted by Chromium while the widget runs: stale socket file is replaced; state rewritten.

---

### Task 1: Native host (`bin/downloads-host`)
**Files:** Create `bin/downloads-host` (Python, executable), `bin/tests/test_downloads_host.py`.
**Interfaces — Produces:** `read_message(stream)->dict|None`, `write_message(stream, obj)`, `validate_command(obj)->(ok:bool, err:str)`, `transitions(prev:dict[int,str], downloads:list)->list[(kind:"complete"|"failed", item)]`, `apply_clear(downloads, cleared:set)->set`, `main(argv)`; argv[1]=="ctl" → client mode, otherwise host mode (Chromium passes the origin as argv[1]).
- [ ] Tests: framing round-trips (4-byte native-endian length + UTF-8 JSON); `validate_command({"action":"rm","id":1})` false; `{"action":"pause","id":"1"}` false (id must be int); `clear` without id true; `transitions` reports complete only for ids previously `in_progress`, reports failed for interrupted with error != `USER_CANCELED`, nothing for cancelled.
- [ ] Implement; host mode: stdin reader thread, socket server thread, atomic state write (tmp + rename), notification via `omarchy-notification-send` with Open/Show folder actions (argv only), remove state + socket on stdin EOF.
- [ ] Run `python3 -m unittest bin/tests/test_downloads_host.py -v` → all pass.

### Task 2: Extension (`chromium/downloads-bridge/`)
**Files:** `manifest.json` (MV3, `key`, permissions `downloads`, `nativeMessaging`), `background.js`; `chromium/NativeMessagingHosts/dev.abu.downloads.json` template.
- [ ] Connect on load/startup/install; reconnect with backoff on disconnect. Snapshot = `downloads.search({orderBy:["-startTime"], limit:20})` filtered to last 24 h, mapped to the data contract; send on onCreated/onChanged/onErased and every 1 s while any is in_progress. Speed from successive snapshots (EMA); ETA from `estimatedEndTime` else (total-received)/speed.
- [ ] Handle `{"action": pause|resume|cancel, "id"}` from host.
- [ ] Verify: manual — load in Chromium, start a large download, `cat $XDG_RUNTIME_DIR/abu-downloads/state.json` updates each second.

### Task 3: Bar widget (`omarchy/plugins/abu.downloads/`)
**Files:** `manifest.json`, `Panel.qml` modelled on `abu.printjobs`.
- [ ] Reads state.json (FileView or 1 s poll). Visible when any in_progress or any `ended` within 10 min, or panel open. Icon 󰇚 bobs while active. Rows: name, progress bar (indeterminate when total 0), "12.0 of 40.0 MB · 2.1 MB/s · 18 s left", Pause/Resume + Cancel while running; Open + Show folder when complete; error text when interrupted. Header Clear button → `ctl clear`.
- [ ] Verify: manual in the bar with a real download.

### Task 4: Install wiring + retire `download-notify`
- [ ] `install.sh`: link host to `~/.local/bin/downloads-host`; write NativeMessagingHosts manifest with absolute path; add extension to `--load-extension`; copy plugin; drop the download-notify service lines. Remove `bin/download-notify`, `systemd/download-notify.service`, disable the unit.
- [ ] Verify: re-run `./install.sh`; restart Chromium; download a file; icon appears, notification on completion, cancel works.
