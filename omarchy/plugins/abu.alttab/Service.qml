// Windows-style Alt+Tab panel. Driven over IPC from Hyprland (see
// ~/dotfiles/hypr/bindings.lua):  omarchy-shell alttab open|next|prev|commit|cancel
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root
  property var shell: null
  property var manifest: null

  readonly property string focusScript: Quickshell.env("HOME") + "/dotfiles/bin/alt-tab-focus"

  property bool active: false      // a switch is in progress
  property bool shown: false       // panel visible (after a short hold, like Windows)
  property int index: 0
  property string pendingDir: "next"
  property var windows: []

  readonly property int cardW: Style.space(220)
  readonly property int thumbH: Style.space(124)

  function open(dir) {
    root.active = true
    root.shown = false
    root.pendingDir = dir || "next"
    root.windows = []
    clientsProc.running = false
    clientsProc.running = true
    showDelay.restart()
  }

  function step(delta) {
    if (!root.active) { root.open(delta < 0 ? "prev" : "next"); return }
    var n = root.windows.length
    if (n === 0) { root.pendingDir = delta < 0 ? "prev" : "next"; return }
    root.index = (root.index + delta + n) % n
    root.shown = true
  }

  function commit() {
    if (!root.active) return
    var w = root.windows[root.index]
    root.finish()
    if (w) Quickshell.execDetached([root.focusScript, w.address])
  }

  function finish() {
    showDelay.stop()
    root.active = false
    root.shown = false
  }

  function iconFor(cls) {
    var entry = null
    try { entry = DesktopEntries.heuristicLookup(cls) } catch (e) {}
    var icon = entry && entry.icon ? entry.icon : cls
    var path = Quickshell.iconPath(icon, true)
    return path.length > 0 ? path : Quickshell.iconPath("application-x-executable", true)
  }

  function toplevelFor(address) {
    var a = String(address).replace(/^0x/, "")
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++)
      if (String(list[i].address).replace(/^0x/, "") === a) return list[i]
    return null
  }

  Timer { id: showDelay; interval: 130; onTriggered: if (root.active) root.shown = true }

  Process {
    id: clientsProc
    // Active workspace of every monitor, then the window list.
    command: ["sh", "-c", "hyprctl monitors -j; printf '\\036'; hyprctl clients -j"]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = [], active = {}
        try {
          var parts = text.split("\u001e")
          JSON.parse(parts[0]).forEach(function(m) { if (m.activeWorkspace) active[m.activeWorkspace.id] = true })
          list = JSON.parse(parts[1])
        } catch (e) {}
        // Only windows on the workspace(s) currently shown on screen.
        list = list.filter(function(c) {
          return c.mapped && c.workspace && active[c.workspace.id] === true
        })
        list.sort(function(a, b) { return a.focusHistoryID - b.focusHistoryID })
        root.windows = list.map(function(c) {
          return {
            address: c.address,
            title: c.title || c.class,
            cls: c.class,
            minimized: c.workspace.name === "special:minimized",
            icon: root.iconFor(c.class)
          }
        })
        var n = root.windows.length
        if (n === 0) { root.finish(); return }
        root.index = n === 1 ? 0 : (root.pendingDir === "prev" ? n - 1 : 1)
      }
    }
  }

  IpcHandler {
    target: "alttab"
    function open(dir: string): string { root.open(dir); return "ok" }
    function next(): string { root.step(1); return "ok" }
    function prev(): string { root.step(-1); return "ok" }
    function commit(): string { root.commit(); return "ok" }
    function cancel(): string { root.finish(); return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.shown && root.windows.length > 0
    screen: {
      var m = Hyprland.focusedMonitor
      var s = Quickshell.screens
      for (var i = 0; m && i < s.length; i++) if (s[i].name === m.name) return s[i]
      return s.length > 0 ? s[0] : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "abu-alttab"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    MouseArea { anchors.fill: parent; onClicked: root.finish() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(flow.implicitWidth, panel.width - Style.space(80)) + padding * 2
      height: flow.implicitHeight + padding * 2
      radius: Style.cornerRadius
      color: Commons.Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.space(14)

      MouseArea { anchors.fill: parent; onClicked: {} }

      Flow {
        id: flow
        x: card.padding; y: card.padding
        width: Math.min(root.windows.length, Math.max(1, Math.floor((panel.width - Style.space(80)) / (root.cardW + spacing)))) * (root.cardW + spacing) - spacing
        spacing: Style.space(10)

        Repeater {
          model: root.windows
          delegate: Rectangle {
            id: tile
            required property var modelData
            required property int index
            readonly property bool selected: index === root.index
            width: root.cardW
            height: col.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: selected ? Commons.Color.menu.selectedBackground : "transparent"
            border.width: selected ? Math.max(2, Style.space(2)) : 0
            border.color: Commons.Color.menu.selectedText

            ColumnLayout {
              id: col
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(8) }
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                Image {
                  Layout.preferredWidth: Style.space(18); Layout.preferredHeight: Style.space(18)
                  source: tile.modelData.icon
                  sourceSize.width: 64; sourceSize.height: 64
                  fillMode: Image.PreserveAspectFit
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: (tile.modelData.minimized ? "▾ " : "") + tile.modelData.title
                  color: tile.selected ? Commons.Color.menu.selectedText : Commons.Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                }
              }

              Item {
                Layout.fillWidth: true
                Layout.preferredHeight: root.thumbH

                ScreencopyView {
                  id: thumb
                  anchors.fill: parent
                  captureSource: { var t = root.toplevelFor(tile.modelData.address); return t ? t.wayland : null }
                  live: false
                  visible: hasContent
                }
                Image {
                  anchors.centerIn: parent
                  visible: !thumb.hasContent
                  width: Style.space(56); height: width
                  source: tile.modelData.icon
                  sourceSize.width: 128; sourceSize.height: 128
                  fillMode: Image.PreserveAspectFit
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.index = tile.index
              onClicked: { root.index = tile.index; root.commit() }
            }
          }
        }
      }
    }
  }
}
