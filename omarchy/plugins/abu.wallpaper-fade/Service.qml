import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// DictatorOS wallpaper. Draws the current Omarchy background itself on the
// Background layer (omarchy.background is disabled in shell.json), so the
// desktop widgets on the layer above are never affected.
//  - A desktop with windows: the wallpaper is out of sight (plain black).
//  - An empty desktop (or everything minimized): it's drawn in from the bottom up.
// Minimized windows live on a special workspace, so they don't count.
Item {
  id: root

  readonly property int revealMs: 1600  // desktop empties: wallpaper is drawn upwards
  readonly property int edge: 220       // height of the fading leading edge (px)
  readonly property int hideMs: 250     // a window appears: wallpaper drops away
  readonly property string backgroundLink: Quickshell.env("HOME") + "/.local/state/omarchy/current/background"
  property int version: 0               // bumps when the background changes

  // Follow `omarchy theme bg set` (it repoints the background symlink).
  FileView {
    path: root.backgroundLink
    watchChanges: true
    printErrors: false
    onFileChanged: root.version++
  }

  // Hyprland's own window counts, refreshed on window/workspace events.
  // (Quickshell's live toplevel lists can keep closed windows around.)
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
      id: panel
      required property var modelData
      screen: modelData

      readonly property var monitor: Hyprland.monitorFor(modelData)
      readonly property var workspace: monitor ? monitor.activeWorkspace : null
      readonly property bool hasWindows: !!workspace && !!workspace.lastIpcObject
        && Number(workspace.lastIpcObject.windows || 0) > 0

      anchors { top: true; bottom: true; left: true; right: true }
      color: "#000000"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "abu-wallpaper"
      mask: Region {}

      // The picture stays still; it is uncovered from the bottom up behind a
      // soft fading edge, so the stripes look like they're being drawn upwards.
      Item {
        id: reveal
        property real progress: 0   // 0 = hidden, 1 = whole wallpaper visible
        anchors.bottom: parent.bottom
        width: parent.width
        height: Math.round(parent.height * progress)
        clip: true

        Image {
          width: panel.width
          height: panel.height
          y: reveal.height - panel.height   // pinned to the screen, not the box
          source: "file://" + root.backgroundLink + "?v=" + root.version
          cache: false
          asynchronous: true
          fillMode: Image.PreserveAspectCrop
          sourceSize: Qt.size(panel.width * panel.devicePixelRatio, panel.height * panel.devicePixelRatio)
        }

        // The leading edge fades into black; it shrinks away as the reveal completes.
        Rectangle {
          anchors.top: parent.top
          width: parent.width
          height: Math.round(root.edge * (1 - reveal.progress))
          gradient: Gradient {
            GradientStop { position: 0.0; color: "#000000" }
            GradientStop { position: 1.0; color: "#00000000" }
          }
        }

        states: State {
          name: "shown"
          when: !panel.hasWindows
          PropertyChanges { target: reveal; progress: 1 }
        }
        transitions: [
          Transition {
            to: "shown"
            NumberAnimation { property: "progress"; duration: root.revealMs; easing.type: Easing.InOutSine }
          },
          Transition {
            from: "shown"
            NumberAnimation { property: "progress"; duration: root.hideMs; easing.type: Easing.InQuad }
          }
        ]
      }
    }
  }
}
