import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

// A black layer over the wallpaper on each screen. Opaque while the screen's
// current desktop has windows (so only black shows in the gaps); it fades out
// slowly, revealing the wallpaper and desktop widgets, once the desktop is
// empty. Minimized windows live on a special workspace, so they don't count.
Item {
  id: root

  readonly property int hideMs: 200     // windows appear: wallpaper goes quickly
  readonly property int revealMs: 1500  // desktop empties: wallpaper fades in slowly

  readonly property var refreshEvents: ["openwindow", "closewindow", "movewindow", "movewindowv2",
    "workspace", "workspacev2", "focusedmon", "focusedmonv2", "createworkspace", "destroyworkspace",
    "moveworkspace", "activespecial", "activespecialv2", "changefloatingmode"]

  Timer { id: refreshSoon; interval: 60; onTriggered: Hyprland.refreshWorkspaces() }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.refreshEvents.indexOf(event.name) !== -1) refreshSoon.restart()
    }
  }
  Component.onCompleted: Hyprland.refreshWorkspaces()

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: cover
      required property var modelData
      screen: modelData

      readonly property var monitor: Hyprland.monitorFor(modelData)
      readonly property var workspace: monitor ? monitor.activeWorkspace : null
      // Hyprland's own window count for the workspace (refreshed on every
      // window/workspace event below). Quickshell's live toplevel lists can keep
      // closed windows around, so they aren't trusted for this.
      readonly property bool hasWindows: !!workspace && !!workspace.lastIpcObject
        && Number(workspace.lastIpcObject.windows || 0) > 0

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "abu-wallpaper-fade"
      mask: Region {}   // never takes clicks

      Rectangle {
        id: shade
        anchors.fill: parent
        color: "#000000"
        opacity: 1
        // States + transitions (not a Behavior) so each direction gets its own speed.
        states: State {
          name: "revealed"
          when: !cover.hasWindows
          PropertyChanges { target: shade; opacity: 0 }
        }
        transitions: [
          Transition {
            to: "revealed"
            NumberAnimation { property: "opacity"; duration: root.revealMs; easing.type: Easing.InOutQuad }
          },
          Transition {
            from: "revealed"
            NumberAnimation { property: "opacity"; duration: root.hideMs; easing.type: Easing.OutQuad }
          }
        ]
      }
    }
  }
}
