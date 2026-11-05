// Top-right desktop indicator (Windows 11-style tile). Appears briefly on every screen when the
// desktop changes (SUPER+1..0, SUPER+TAB, clicking the bar...).
// Desktops span monitors: workspace N, N+10, N+20 = desktop N
// (see ~/dotfiles/hypr/desktops.lua).
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

  // How long the badge stays up (ms). Set alwaysShow to true to keep it on screen.
  readonly property int showFor: 1500
  readonly property bool alwaysShow: false

  property int desktop: desktopOf(Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1)
  property bool shown: alwaysShow

  function desktopOf(id) { return id > 0 ? ((id - 1) % 10) + 1 : 0 }

  function occupied(d) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++)
      if (desktopOf(values[i].id) === d && values[i].toplevels.values.length > 0) return true
    return false
  }

  function desktops() {
    var list = []
    for (var d = 1; d <= 10; d++) if (d === root.desktop || occupied(d)) list.push(d)
    return list
  }

  // Only needed while the top bar is hidden (SUPER+B); the bar already
  // shows the desktop number.
  onDesktopChanged: {
    if (desktop <= 0) return
    barCheck.running = false
    barCheck.running = true
  }

  Process {
    id: barCheck
    command: ["test", "-e", Quickshell.env("HOME") + "/.local/state/omarchy/toggles/bar-off"]
    onExited: function(code) {
      if (code !== 0) return          // bar is showing
      root.shown = true
      hideTimer.restart()
    }
  }

  Timer { id: hideTimer; interval: root.showFor; onTriggered: if (!root.alwaysShow) root.shown = false }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData
      visible: root.shown && root.desktop > 0
      anchors { top: true; right: true }
      margins { top: Style.space(16); right: Style.space(16) }
      implicitWidth: badge.width
      implicitHeight: badge.height
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "abu-desktop-osd"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {}   // clicks pass straight through

      // Windows 11-style tile: dark, softly rounded, no outline, just the number.
      Rectangle {
        id: badge
        width: Style.space(64)
        height: width
        radius: Style.space(10)
        color: Qt.rgba(0.09, 0.09, 0.09, 0.92)

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.desktop === 10 ? "0" : String(root.desktop)
          color: Commons.Color.accent
          font.family: Style.font.menuFamily
          font.pixelSize: Style.space(30)
          font.weight: Font.DemiBold
        }
      }
    }
  }
}
