# desktop-mcp

desktop-mcp is an MCP server (stdio). It lets AI agents see and use a Hyprland desktop.
The agents do not move your pointer or type into your windows.

## Function

- **Each agent has its own desktop.** This is the default. The server starts a nested sway desktop for
  each agent session. This desktop shows as a tiled window on your screen. It does not float.
- **The agent desktop has its own pointer, keyboard focus and clipboard.** The agent does not move your
  pointer. The agent does not type into your windows.
- **The agent desktop continues to work when you go to a different workspace.**
- **The agent can use your desktop when it asks for it** (`desktop: "host"`). For each click, the server
  moves your pointer for a short time. Then the server moves your pointer back.
- **On your desktop, the agent types only into the window that it clicked or focused.** If you
  focus a different window, the server refuses the input.
- **Clicks on your desktop agree with the last screenshot.** If you change the workspace after the
  screenshot, the server refuses the clicks. The agent must then take a new screenshot.
- **Each agent has a cursor with a name and a color.** A click-through overlay shows the cursor. The
  overlay also shows a ripple for each click.
- **The cursor shows only where and when the agent works.** On your desktop, the cursor stays on the
  workspace where the agent put it. The cursor goes out of view when the agent stops for 10 seconds.
  The next pointer action shows it again.
- **The server always hides credentials from the agent.** Refer to [Credential protection](#credential-protection).
- **The agent can ask for your help.** Refer to [Alerts](#alerts).

## Requirements

- Hyprland 0.56 or newer. (The server uses the Lua dispatch syntax. It uses the old syntax if the Lua
  syntax is not available.)
- sway, quickshell, grim, wtype and wl-clipboard.
- ydotool. The `ydotoold` daemon must run, and your user must have write access to `/dev/uinput`.
- tesseract and `tesseract-data-eng` (OCR).
- python-gobject and at-spi2-core (password-field detection).
- Node.js 20 or newer.

In DictatorOS, these scripts install and set up all of the requirements:

1. `apps.sh` installs the packages and starts the ydotool user service.
2. `sudo system/install.sh` (step 6d) loads `uinput` at boot. It gives only your user write access to
   `/dev/uinput`.
3. `install.sh` installs the Node.js dependencies (`npm ci`). It also registers the server with
   Claude Code, Codex and OpenCode.

## Manual registration

Use these commands only if you do not use `install.sh`:

```sh
claude mcp add --scope user desktop -e DESKTOP_MCP_LABEL=Claude -- node ~/dotfiles/desktop-mcp/server.js
opencode mcp add --global --env DESKTOP_MCP_LABEL=OpenCode desktop -- node ~/dotfiles/desktop-mcp/server.js
```

For Codex, add a `[mcp_servers.desktop]` table to `~/.codex/config.toml`.

## Settings

| Environment variable | Function |
|---|---|
| `DESKTOP_MCP_LABEL` | The name on the cursor and in the bar. The default is `Agent`. |
| `DESKTOP_MCP_COLOR` | The cursor color, as `#rrggbb`. The default is a different color for each session. |
| `DESKTOP_MCP_DEFAULT` | Set to `host` to make your desktop the default. The default is `sandbox`. |
| `DESKTOP_MCP_CURSOR_IDLE_MS` | The time without a tool call before the cursor goes out of view, in milliseconds. The default is `10000`. Set to `0` to keep the cursor in view. |
| `DESKTOP_MCP_KEEP_SANDBOX` | Set to `1` to keep the agent desktop open after the agent session stops. |

## Tools

| Tool | Function |
|---|---|
| `sandbox_start`, `sandbox_stop`, `sandbox_status` | Start, stop or examine the agent desktop. The server starts it automatically when the agent first uses it. |
| `screenshot` | Get a PNG of a desktop, with the credentials hidden. The pointer tools use the pixel coordinates of this screenshot. |
| `click`, `move_mouse`, `drag`, `scroll` | Use the pointer. |
| `type_text`, `key` | Use the keyboard. For example: `"ctrl+shift+t"`, `"super+1"`, `"Return"`. |
| `list_windows`, `focus_window`, `close_window`, `list_monitors`, `switch_workspace`, `launch_app` | Control windows and apps. |
| `clipboard_read`, `clipboard_write` | Use the clipboard. The agent desktop has its own clipboard. The server removes credentials from the text that it reads. |
| `request_user_input`, `check_user_input`, `clear_user_input` | Ask for your help. The agent can wait until you push **Done**. |
| `cursor_position`, `wait` | Get the pointer position. Wait for a time. |

All tools accept `desktop: "sandbox"` or `desktop: "host"`.

NOTE: In the agent desktop, give each browser its own profile, for example
`chromium --user-data-dir=/tmp/agent-chromium`. If you do not do this, the browser opens in the browser
that is already open on your desktop.

## Credential protection

This protection is always on. You cannot set it to off. The server applies it to each screenshot and to
each text result before the agent gets them:

1. **Sensitive apps.** The server makes password managers, keyring prompts, polkit prompts, pinentry
   prompts and lock screens black. It refuses clicks and keyboard input into these windows. It tells the
   agent to use `request_user_input`, and it gives you an alert.
2. **Password fields.** The server makes black all password fields that AT-SPI reports. (Accessibility
   is always on for apps in the agent desktop.)
3. **OCR.** Tesseract reads each window separately. The server makes black all text that looks like a
   credential. Examples are API keys, tokens, `password: …` lines, `SECRET=…` lines, credentials in
   URLs, private keys, JWTs and long random strings.
4. **Text.** The server removes credentials from clipboard text, window titles and messages. It refuses
   clipboard text that a password manager copied.

If the OCR step fails, the server does not send the screenshot.

CAUTION: THIS PROTECTION IS NOT COMPLETE. OCR CAN MISS TEXT IN UNUSUAL FONTS OR VERY SMALL TEXT. IT CAN
ALSO MISS A PASSWORD THAT HAS NO LABEL AND NO KNOWN FORMAT. ON YOUR DESKTOP, CHROMIUM AND ELECTRON APPS
DO NOT SHOW ACCESSIBILITY DATA BY DEFAULT. FOR THESE APPS, ONLY OCR GIVES PROTECTION.

## Alerts

When an agent needs your help, the server shows an alert:

- A pill shows near the clock in the bar: `󰂞 Claude needs you`. When agents work and do not need you,
  the pill shows the number of agents. When no agents work, the pill is not shown.
- A desktop notification shows.
- If the bar is hidden (Super+B), or a fullscreen window covers it, a banner shows above all windows.
  The banner also shows above fullscreen video.

To answer an alert:

1. Click the pill or the banner.
2. Push **Show** to go to the agent desktop.
3. Do the task that the agent asked for.
4. Push **Done**. The agent then continues.

To close an agent desktop, push **×**.

## Bar widget

The bar widget is `omarchy/plugins/abu.agent-desk`. It is in the `center` group of the bar, after the
clock. It uses `bin/desktop-mcp-ctl` (`list`, `alert`, `ack`, `show` and `stop`).

## Files

| File | Function |
|---|---|
| `server.js` | The MCP tools |
| `backends.js` | The host desktop and the agent desktop |
| `redact/` | The credential protection |
| `overlay/shell.qml` | The agent cursors and the banner above all windows |
| `status.js`, `bin/desktop-mcp-ctl` | The connection to the bar widget |

## Tests

Do the unit tests and the redaction tests:

```sh
node --test test/unit.mjs test/redact.mjs
```

Do all of the tests:

```sh
npm test
```

NOTE: `npm test` also does a live smoke test. This test opens an agent desktop on your screen and then
closes it.
