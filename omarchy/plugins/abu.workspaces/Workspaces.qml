import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      // Desktops span monitors: workspace N, N+10, N+20... are desktop N.
      var d = id > 0 ? ((id - 1) % 10) + 1 : 0
      if (d > 0 && ids.indexOf(d) === -1) ids.push(d)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function desktopOf(id) { return id > 0 ? ((id - 1) % 10) + 1 : 0 }

  function desktopOccupied(d) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++)
      if (desktopOf(values[i].id) === d && values[i].toplevels.values.length > 0) return true
    return false
  }

  // Switch every screen to desktop N (see ~/dotfiles/hypr/desktops.lua).
  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("(function() dotfiles_desktops.go(" + id + ") end)"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: root.desktopOccupied(modelData)
        readonly property bool focused: Hyprland.focusedWorkspace !== null && root.desktopOf(Hyprland.focusedWorkspace.id) === modelData

        bar: root.bar
        text: focused ? "\uDB85\uDCFB" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }
      }
    }
  }
}
