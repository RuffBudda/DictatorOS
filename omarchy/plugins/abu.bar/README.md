# Omarchy bar

This is the Quickshell implementation of the Omarchy status bar. It is a first-party plugin of
[`omarchy-shell`](../../README.md), the shell host that runs for the full session. The host
starts the bar at startup. The bar stays in the shell for the full session.

- `manifest.json` declares the plugin (`id: omarchy.bar`, `kind: bar`). Its entry point is `Bar.qml`.
- `Bar.qml` is the bar engine code that Omarchy owns. The omarchy-shell host loads it. Do not change it directly.
- `widgets/` contains simple first-party bar widgets, each with a manifest next to it.
- Feature plugins, for example `../panels/audio/`, `../panels/network/`, `../panels/power/` and `../agents/`, supply bar plugins with larger popups.
- The host shell gives the bar its configuration as a `barConfig` property. The host loads it from `~/.config/omarchy/shell.json`. If the user has no file, it uses `config/omarchy/shell.json`.
- `omarchy bar position` changes only the shell.json file of the user.

## Customizing

The bar configuration is below the `bar:` key of [`~/.config/omarchy/shell.json`](../../README.md#shelljson-shape).
By default, the shell uses [`config/omarchy/shell.json`](../../../config/omarchy/shell.json).
After you change a setting with the bar gestures, with `omarchy bar ...` or directly in
shell.json, your file is the only source. There is no deep-merge.

You configure the bar directly on the bar:

- To move the bar to a different screen edge, drag empty bar space (or click and hold).
- To change the transparency, double-click with the left button on empty space in the center
  of the bar.
- To change the order of the widgets, drag them.

If `"locked": true` is set on the `bar` object in `shell.json`, you cannot drag widgets and the
double-click does not change the transparency.

The `omarchy bar position`, `omarchy bar transparent`, `omarchy bar move` and `omarchy bar set`
commands do the same from scripts. To enable or disable widgets, use `omarchy plugin enable` and
`omarchy plugin disable`. `omarchy plugin list` shows the widget ids.

Example `shell.json` (only the bar part shows):

```json
{
  "version": 1,
  "bar": {
    "position": "top",
    "transparent": false,
    "centerAnchor": "omarchy.clock",
    "layout": {
      "left": [
        { "id": "omarchy.menu" },
        { "id": "omarchy.spacer", "size": 12 },
        { "id": "omarchy.workspaces" }
      ],
      "center": [
        { "id": "omarchy.media" },
        { "id": "omarchy.clock", "format": "HH:mm" }
      ],
      "right": [
        { "id": "omarchy.audio" },
        { "id": "omarchy.power" }
      ]
    }
  }
}
```

`centerAnchor` attaches one center module to the exact horizontal and vertical center. The
other modules go on each side of it. To disable the anchor, set it to an empty string. Then the
center list is centered as a group.

## Module catalogue

### First-party interactive widgets

| Name | Function | Interactions |
|---|---|---|
| `omarchy.menu` | Starts the Omarchy menu | left = menu · right = terminal |
| `omarchy.workspaces` | Changes the Hyprland workspace | left = focus workspace |
| `omarchy.clock` | A date and time label, and a popup with a month grid, ISO week numbers and month steps | left = popup · right = next label format · middle = timezone selector |
| `omarchy.media` | MPRIS now playing: a scrolling track and artist, and a popup with the cover art | left = play/pause · middle = next · scroll = prev/next · right = popup |
| `omarchy.indicators` | Manual state indicators | left = indicator action |
| `omarchy.system-update` | Shows that an update is available | left = update |
| `omarchy.tray` | The system tray | hover = show drawer · right on chevron = manage |
| `omarchy.weather` | A weather icon and a popup with the forecast | left = popup · right = full notification |
| `omarchy.microphone` | A microphone icon, and scroll to change the volume | left = mute on/off · middle = audio panel · scroll = source volume |

| `omarchy.audio` | A volume icon and a popup with a master slider, an output-device picker and a mixer for each app | left = popup · right = mute · middle = popup · scroll = volume |
| `omarchy.network` | A Wi-Fi or Ethernet icon and a popup with Wi-Fi scan, signal, connect and DNS provider selection | left = popup |
| `omarchy.tailscale` | The Tailscale status, a connection switcher, a machine browser and copy actions | left = popup · right = on/off · middle = refresh |
| `omarchy.agents` | The limits of AI coding agents, with pace, today, last week and an all-time model breakdown | left = panel · right = start agent · middle = next subscription |
| `omarchy.power` | A battery or AC icon and a popup with battery data, power profiles and system data | left = popup · right = show/hide percentage |
| `omarchy.bluetooth` | A Bluetooth icon and a popup with a device list, connect/disconnect and battery | left = popup · right = radio on/off |
| `omarchy.monitor` | Brightness and laptop display controls | left = popup |

The `omarchy.indicators` widget loads each bar indicator from `indicators/`.

- To show all indicators in the default order, do not set `items`, or set it to an empty array.
- To show only some indicators, set `items` to a subset, for example `["Dnd", "Reminder", "NightLight"]`.
- By default, inactive indicators show only when the pointer is on the widget. To always show
  them, set `alwaysShow` to `true`.
- You can use more than one `omarchy.indicators` instance. Thus different sections can show
  different subsets.

## Orientation

All widgets operate in the `top`, `bottom`, `left` and `right` positions. Popups attach on the
side opposite the bar edge and move into the workspace. Vertical bars are 28px wide. Widgets
that show text then use compact forms with only an icon. For example, `media` hides its
scrolling label.

## Custom user modules

The schema accepts module ids that you supply. Set `type` to `command` for output from a shell
command, or to `qml` for a custom QML widget. Both go below `bar.layout.<section>` in
`shell.json`.

Command module:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "omarchy.tray" },
        { "id": "vpn", "type": "command", "exec": "~/.config/omarchy/bar/scripts/vpn-status", "interval": 5, "tooltip": "VPN", "onClick": "nm-connection-editor" },
        { "id": "omarchy.audio" }
      ]
    }
  }
}
```

The command can print plain text or JSON in the Waybar style. For example:

```json
{"text":"󰌆","tooltip":"Work VPN","class":"active"}
```

QML module:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "gpu", "type": "qml" },
        { "id": "omarchy.audio" }
      ]
    }
  }
}
```

Then make `~/.config/omarchy/bar/modules/gpu.qml`. To keep it in a different location, add a
`source` path.

A custom QML module must be an `Item` with `implicitWidth` and `implicitHeight`. It can also
declare these properties. The bar sets them after it loads the module:

```qml
import QtQuick

Item {
  property var bar
  property string moduleName
  property var settings

  implicitWidth: 28
  implicitHeight: bar ? bar.barSize : 26

  Text {
    anchors.centerIn: parent
    text: "GPU"
    color: bar ? bar.foreground : "white"
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 12
  }

  MouseArea {
    anchors.fill: parent
    onClicked: if (bar) bar.run("omarchy-launch-or-focus-tui btop")
  }
}
```

## Bar properties available to widgets

When the bar loads a widget, it gives the widget `bar` (the shell root), `moduleName` (a string)
and `settings` (an object). The bar supplies:

- `bar.foreground`, `bar.background`, `bar.urgent`: the theme colors (live updates)
- `bar.fontFamily`: the current monospace family
- `bar.position`: `"top" | "bottom" | "left" | "right"`
- `bar.vertical`: a boolean shortcut
- `bar.barSize`: 26 horizontal, 28 vertical
- `bar.run(command)`: runs a bash command and does not wait for it
- `bar.shellQuote(value)`: puts a string in safe shell quotes
- `bar.showTooltip(target, text)` / `bar.hideTooltip(target)`: the shared tooltip popup
- `bar.requestPopout(owner)` / `bar.releasePopout(owner)`: makes sure that only one popup is open at a time

First-party bar widgets have manifests, as third-party widgets do.

- Simple widgets have a manifest next to them, for example `widgets/Workspaces.manifest.json`.
- Plugins with larger popups are in feature directories, for example `../panels/audio/`,
  `../panels/network/` and `../agents/`.
- Feature plugins, for example `omarchy.menu` and `omarchy.media`, declare their bar-widget
  entry points in their own `manifest.json`.
- Bar layout ids have namespaces, for example `omarchy.audio`, `omarchy.network` and
  `omarchy.clock`. The bar changes older UpperCamelCase ids, for example `AudioPanel` and
  `Clock`, to the new ids. New configurations must use the ids with namespaces.

Third-party widgets are separate plugins in `~/.config/omarchy/plugins/<plugin-id>/`. Each has
its own `manifest.json` that declares `kinds: ["bar-widget"]` and a `barWidget` entry point. For
the manifest schema, refer to [../../README.md](../../README.md). To scan, enable and put
third-party plugins in position, use `omarchy-shell shell rescanPlugins`,
`omarchy plugin enable` and `omarchy bar move`.
