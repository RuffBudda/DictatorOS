import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "abu.optimizer"
  ipcTarget: "abu.optimizer"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helper: String(Qt.resolvedUrl("scripts/optimizer")).replace(/^file:\/\//, "")

  property var items: []
  property var mem: ({ total: 0, used: 0, available: 0 })
  property string errorText: ""
  property string infoText: ""
  property bool busy: freeProc.running || listProc.running || actProc.running || stoppingBatch
  property bool showProtected: true
  property string sortMode: "mem" // "mem" | "name"
  property string confirmPid: ""
  property var selected: ({})
  property var stopQueue: []
  property bool stoppingBatch: false

  readonly property var protectedPatterns: [
    "hyprland", "quickshell", "omarchy", "sddm", "greetd", "dbus", "systemd",
    "polkit", "networkmanager", "pipewire", "wireplumber", "xwayland",
    "containerd", "dockerd", "login", "seatd"
  ]

  function isProtected(item) {
    if (!item) return false
    var hay = (String(item.comm||"") + " " + String(item.args||"") + " " + String(item.unit||"")).toLower()
    for (var i = 0; i < protectedPatterns.length; i++) {
      if (hay.indexOf(protectedPatterns[i]) >= 0) return true
    }
    if (String(item.user||"") === "root" && String(item.unit||"").indexOf("user@") !== 0 && String(item.pid) === "1") return true
    return false
  }

  readonly property var visibleItems: {
    var arr = (items || []).slice()
    if (!showProtected) arr = arr.filter(function(it){ return !isProtected(it) })
    if (sortMode === "name") {
      arr.sort(function(a,b){ return String(a.comm||"").localeCompare(String(b.comm||"")) })
    } else {
      arr.sort(function(a,b){ return Number(b.rssKb||0) - Number(a.rssKb||0) })
    }
    return arr
  }

  function isSelected(pid) { return !!selected[String(pid)] }
  function selectedCount() { return Object.keys(selected || {}).length }
  function allVisibleSelected() {
    var v = visibleItems || []
    if (v.length === 0) return false
    for (var i = 0; i < v.length; i++) if (!isSelected(v[i].pid)) return false
    return true
  }
  function toggleSelected(pid) {
    var s = Object.assign({}, selected || {})
    var k = String(pid)
    if (s[k]) delete s[k]; else s[k] = true
    selected = s
  }
  function clearSelection() { selected = ({}) }
  function toggleSelectAllVisible() {
    var v = visibleItems || []
    if (allVisibleSelected()) { clearSelection(); return }
    var s = {}
    for (var i = 0; i < v.length; i++) s[String(v[i].pid)] = true
    selected = s
  }

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function fmtBytes(b) {
    var n = Number(b)
    if (!isFinite(n) || n < 0) n = 0
    var gib = n / (1024 * 1024 * 1024)
    if (gib >= 1) return gib.toFixed(1) + " GiB"
    var mib = n / (1024 * 1024)
    if (mib >= 1) return mib.toFixed(0) + " MiB"
    return Math.round(n / 1024) + " KiB"
  }
  function fmtKb(kb) { return fmtBytes(Number(kb) * 1024) }

  function refresh() {
    if (listProc.running) return
    listProc.command = [root.helper, "list"]
    listProc.running = true
  }

  function freeRam() {
    if (freeProc.running) return
    root.errorText = ""; root.infoText = "Freeing RAM…"
    freeProc.command = ["sudo", "-n", root.helper, "free-ram"]
    freeProc.running = true
  }

  function commandForItem(item) {
    if (item.unit && item.unit !== "") {
      return ["sudo", "-n", root.helper, "stop-unit", item.unit]
    }
    return [root.helper, "kill", String(item.pid), "TERM"]
  }

  function stopItem(item) {
    if (actProc.running) return
    root.errorText = ""; root.infoText = ""
    actProc.command = commandForItem(item)
    actProc.running = true
  }

  function stopSelected() {
    if (actProc.running || stoppingBatch) return
    var map = {}
    var v = items || []
    for (var i = 0; i < v.length; i++) map[String(v[i].pid)] = v[i]
    var q = []
    var keys = Object.keys(selected || {})
    for (var j = 0; j < keys.length; j++) { if (map[keys[j]]) q.push(map[keys[j]]) }
    if (q.length === 0) { infoText = "No processes selected"; return }
    stopQueue = q
    stoppingBatch = true
    errorText = ""
    infoText = "Stopping selected (0/" + q.length + ")…"
    startNextStop()
  }

  property int stopDoneCount: 0
  function startNextStop() {
    if (!stoppingBatch) return
    if (stopQueue.length === 0) {
      stoppingBatch = false
      infoText = "Stopped " + stopDoneCount + " selected process(es)"
      stopDoneCount = 0
      clearSelection()
      refresh()
      return
    }
    var item = stopQueue[0]
    stopQueue = stopQueue.slice(1)
    actProc.command = commandForItem(item)
    actProc.running = true
  }

  onOpenedChanged: { root.confirmPid = ""; root.clearSelection(); root.stoppingBatch = false; root.stopQueue = []; if (opened) { root.infoText = ""; root.errorText = ""; refresh() } }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(this.text)
          if (r.ok) {
            root.items = r.items || []
            root.mem = r.mem || ({ total: 0, used: 0, available: 0 })
            root.errorText = ""
          } else root.errorText = String(r.error || "Failed to list processes")
        } catch (e) { root.errorText = "Failed to read process list" }
      }
    }
  }

  Process {
    id: freeProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(this.text || "{}")
          if (r.ok) { root.infoText = "RAM caches cleared" } else { root.errorText = String(r.error || "Failed to free RAM") ; root.infoText = "" }
        } catch (e) { root.infoText = "RAM caches cleared" }
      }
    }
    onExited: function(code) {
      if (code !== 0 && root.infoText === "Freeing RAM…") { root.errorText = "Failed to free RAM (auth?)"; root.infoText = "" }
      root.refresh()
    }
  }

  Process {
    id: actProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var r = JSON.parse(this.text || "{}")
          if (!r.ok) root.errorText = String(r.error || "Failed to stop")
          else if (!root.stoppingBatch) root.infoText = "Stop signal sent"
        } catch (e) {}
      }
    }
    onExited: {
      if (root.stoppingBatch) {
        root.stopDoneCount += 1
        var total = root.stopDoneCount + root.stopQueue.length
        root.infoText = "Stopping selected (" + root.stopDoneCount + "/" + total + ")…"
        root.startNextStop()
      } else {
        root.refresh()
      }
    }
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    slotSize: Style.bar.statusSlot
    opacity: root.busy ? 0.6 : 1.0
    tooltipText: root.opened ? "" : "Optimizer: free RAM & manage processes"
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(460))
    contentHeight: popup.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Optimizer"
            meta: root.mem.total > 0 ? ("Used " + root.fmtBytes(root.mem.used) + " / " + root.fmtBytes(root.mem.total) + " · " + root.fmtBytes(root.mem.available) + " available") : "Memory & running processes"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text { textFormat: Text.PlainText; text: "󰍛"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.display }
            }
            trailingControl: Component {
              PanelActionButton {
                enabled: !freeProc.running
                iconText: "󰃢"
                tooltipText: "Free RAM (drop caches)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.freeRam()
              }
            }
          }

          Text {
            visible: root.infoText !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.infoText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Text {
            visible: root.errorText !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "PROCESSES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PanelActionButton {
              iconText: sortMode === "mem" ? "󰘚" : "󰒺"
              tooltipText: sortMode === "mem" ? "Sort: memory (click for name)" : "Sort: name (click for memory)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.sortMode = (root.sortMode === "mem" ? "name" : "mem")
            }
            PanelActionButton {
              iconText: root.showProtected ? "󰈈" : "󰈉"
              tooltipText: root.showProtected ? "Showing protected/critical items (click to hide)" : "Hiding protected/critical items (click to show)"
              foreground: root.showProtected ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              onClicked: { root.showProtected = !root.showProtected; root.confirmPid = "" }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            CheckBox {
              id: selectAllBox
              checked: root.allVisibleSelected()
              text: "Select all"
              onClicked: root.toggleSelectAllVisible()
              palette.windowText: root.foreground
              palette.text: root.foreground
            }
            Item { Layout.fillWidth: true }
            Button {
              text: root.selectedCount() > 0 ? ("Stop selected (" + root.selectedCount() + ")") : "Stop selected"
              enabled: root.selectedCount() > 0 && !root.stoppingBatch
              onClicked: root.stopSelected()
            }
          }

          Text {
            visible: !root.showProtected
            width: parent.width
            textFormat: Text.PlainText
            text: "Protected items (e.g. Hyprland, quickshell, system services) are highlighted. Use the eye button to hide them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.visibleItems
            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool prot: root.isProtected(modelData)
              readonly property bool armed: root.confirmPid === String(modelData.pid)
              width: content.width
              height: row.implicitHeight + Style.space(10)
              radius: Style.radius.sm
              color: prot ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.08) : "transparent"

              RowLayout {
                id: row
                anchors.fill: parent
                anchors.margins: Style.space(4)
                spacing: Style.space(8)

                CheckBox {
                  checked: root.isSelected(modelData.pid)
                  onClicked: root.toggleSelected(modelData.pid)
                  palette.windowText: root.foreground
                  palette.text: root.foreground
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 2
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: String(modelData.comm || "") + "  (" + root.fmtKb(modelData.rssKb) + ")" + (prot ? "  [protected]" : "")
                    color: prot ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: "PID " + modelData.pid + " · " + String(modelData.user || "") + (modelData.unit ? (" · " + modelData.unit) : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  iconText: armed ? "󰄬" : "󰅙"
                  tooltipText: prot ? (armed ? "Click again to STOP protected process" : "Protected: click twice to stop") : (armed ? "Click again to confirm stop" : (modelData.unit ? ("Stop " + modelData.unit) : ("Terminate PID " + modelData.pid)))
                  foreground: (prot || armed) ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                  enabled: !actProc.running
                  onClicked: {
                    if (root.confirmPid === String(modelData.pid)) {
                      root.confirmPid = ""
                      root.stopItem(modelData)
                    } else {
                      root.confirmPid = String(modelData.pid)
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.visibleItems.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: listProc.running ? "Loading…" : (root.items.length === 0 ? "No processes found" : "No non-protected processes shown")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
