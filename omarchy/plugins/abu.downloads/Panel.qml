import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Chromium downloads in the bar, web-app windows included (they have no
// toolbar, so no download bubble). The chromium/downloads-bridge extension
// streams chrome.downloads to bin/downloads-host, which writes
// $XDG_RUNTIME_DIR/abu-downloads/state.json; this reads it every second and
// sends pause/resume/cancel/open/show/clear through `downloads-host ctl`.
// The icon bobs while something downloads and stays 10 minutes after the last
// one finishes. File names are untrusted, so every text here is plain text.
Panel {
  id: root
  moduleName: "abu.downloads"
  ipcTarget: "abu.downloads"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int recentMs: 10 * 60 * 1000

  property var downloads: []
  property real now: Date.now()
  property string errorText: ""

  readonly property var shown: downloads.filter(d => d.state === "in_progress" || (d.ended > 0 && now - d.ended < recentMs))
  readonly property var running: shown.filter(d => d.state === "in_progress")
  readonly property bool active: running.some(d => !d.paused)
  readonly property bool anyFinished: shown.some(d => d.state !== "in_progress")

  visible: shown.length > 0 || opened
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function refresh() { if (!readProc.running) readProc.running = true }
  function act(args) {
    if (actProc.running) return
    actProc.command = ["downloads-host", "ctl"].concat(args)
    actProc.running = true
  }
  function size(b) {
    if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB"
    if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB"
    if (b >= 1024) return Math.round(b / 1024) + " KB"
    return b + " B"
  }
  function timeLeft(s) {
    if (s < 60) return s + " s left"
    if (s < 3600) return Math.round(s / 60) + " min left"
    return Math.floor(s / 3600) + " h " + Math.round((s % 3600) / 60) + " min left"
  }
  function ago(ms) {
    const sec = Math.max(0, Math.floor((now - ms) / 1000))
    if (sec < 60) return "just now"
    if (sec < 3600) return Math.floor(sec / 60) + " min ago"
    return Math.floor(sec / 3600) + " h ago"
  }
  function caption(d) {
    if (d.state === "complete") return size(d.received || d.total) + " · " + ago(d.ended)
    if (d.state === "interrupted") return d.error === "USER_CANCELED" ? "Cancelled" : "Failed: " + (d.error || "unknown error").replace(/_/g, " ").toLowerCase()
    const parts = []
    if (d.paused) parts.push("Paused")
    parts.push(d.total > 0 ? size(d.received) + " of " + size(d.total) : size(d.received))
    if (!d.paused && d.speed > 0) parts.push(size(d.speed) + "/s")
    if (!d.paused && d.eta >= 0) parts.push(timeLeft(d.eta))
    return parts.join(" · ")
  }
  function glyph(d) {
    if (d.state === "complete") return "󰄬"
    if (d.state === "interrupted") return "󰅚"
    return d.paused ? "󰏤" : "󰇚"
  }
  readonly property string overall: {
    const known = running.filter(d => d.total > 0)
    const total = known.reduce((a, d) => a + d.total, 0)
    const got = known.reduce((a, d) => a + d.received, 0)
    const speed = running.reduce((a, d) => a + (d.paused ? 0 : d.speed), 0)
    const parts = []
    if (total > 0) parts.push(Math.floor(100 * got / total) + "%")
    if (speed > 0) parts.push(size(speed) + "/s")
    if (!active) parts.push("Paused")
    return parts.join(" · ")
  }

  onOpenedChanged: if (opened) { errorText = ""; refresh() }

  Process {
    id: readProc
    command: ["sh", "-c", "cat \"$XDG_RUNTIME_DIR/abu-downloads/state.json\" 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.now = Date.now()
        try {
          const r = JSON.parse(this.text)
          root.downloads = Array.isArray(r.downloads) ? r.downloads : []
        } catch (e) { root.downloads = [] }
      }
    }
  }
  Process {
    id: actProc
    stdout: StdioCollector {
      onStreamFinished: {
        try { const r = JSON.parse(this.text); root.errorText = r.ok ? "" : String(r.error || "") }
        catch (e) { root.errorText = "Couldn't reach the downloads helper" }
      }
    }
    onExited: root.refresh()
  }
  Timer {
    interval: 1000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: "󰇚"
    slotSize: Style.bar.statusSlot
    tooltipText: root.opened ? "" : (root.running.length === 1 ? "1 download"
                 : root.running.length > 1 ? root.running.length + " downloads" : "Downloads")
    onPressed: function(b) { root.toggle() }

    // The downloading motion: the arrow drops a few pixels and springs back.
    transform: Translate { id: bob }
    SequentialAnimation {
      running: root.active && Style.duration(1000) > 0
      loops: Animation.Infinite
      onRunningChanged: if (!running) bob.y = 0
      NumberAnimation { target: bob; property: "y"; from: -1.5; to: 2; duration: 650; easing.type: Easing.InQuad }
      NumberAnimation { target: bob; property: "y"; from: 2; to: -1.5; duration: 650; easing.type: Easing.OutQuad }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(420))
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
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.running.length === 0 ? "Downloads"
                   : root.running.length === 1 ? "Downloading 1 file" : "Downloading " + root.running.length + " files"
            meta: root.running.length > 0 ? root.overall
                  : root.shown.length > 0 ? "All done" : "Nothing downloading"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󰇚"
                color: root.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                visible: root.anyFinished
                enabled: !actProc.running
                iconText: "󰎟"
                tooltipText: "Clear finished"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: root.act(["clear"])
              }
            }
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

          PanelSeparator { width: parent.width; foreground: root.foreground; visible: root.shown.length > 0 }

          PanelSectionHeader {
            visible: root.shown.length > 0
            text: "DOWNLOADS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.shown

            CursorSurface {
              id: row
              required property var modelData
              readonly property bool isRunning: modelData.state === "in_progress"
              width: content.width
              implicitHeight: rowLayout.implicitHeight + Style.space(12)
              current: isRunning
              foreground: root.foreground

              RowLayout {
                id: rowLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.glyph(row.modelData)
                  color: row.modelData.state === "interrupted" ? root.urgent : row.isRunning && !row.modelData.paused ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: row.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: row.isRunning
                    elide: Text.ElideMiddle
                  }

                  // Progress: filled to received/total, or a sliding segment
                  // when the server didn't say how big the file is.
                  Item {
                    id: progress
                    readonly property bool known: row.modelData.total > 0
                    readonly property real value: known ? Math.min(1, row.modelData.received / row.modelData.total) : 0
                    visible: row.isRunning
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(4)
                    implicitHeight: Style.space(4)
                    clip: true
                    Rectangle {
                      anchors.fill: parent
                      radius: height / 2
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                    }
                    Rectangle {
                      visible: progress.known
                      width: parent.width * progress.value
                      height: parent.height
                      radius: height / 2
                      color: row.modelData.paused ? root.dim : root.foreground
                      Behavior on width { NumberAnimation { duration: Style.duration(250); easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                      id: slider
                      visible: !progress.known && !row.modelData.paused
                      width: parent.width * 0.3
                      height: parent.height
                      radius: height / 2
                      color: root.foreground
                      NumberAnimation on x {
                        running: slider.visible && progress.visible && root.opened && Style.duration(1000) > 0
                        loops: Animation.Infinite
                        from: -slider.width
                        to: progress.width
                        duration: 1400
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.caption(row.modelData)
                    color: row.modelData.state === "interrupted" && row.modelData.error !== "USER_CANCELED" ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  visible: row.isRunning
                  enabled: !actProc.running && (!row.modelData.paused || row.modelData.canResume)
                  iconText: row.modelData.paused ? "󰐊" : "󰏤"
                  tooltipText: row.modelData.paused ? "Resume" : "Pause"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act([row.modelData.paused ? "resume" : "pause", String(row.modelData.id)])
                }
                PanelActionButton {
                  visible: row.isRunning
                  enabled: !actProc.running
                  iconText: "󰅖"
                  tooltipText: "Cancel"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act(["cancel", String(row.modelData.id)])
                }
                PanelActionButton {
                  visible: row.modelData.state === "complete"
                  enabled: !actProc.running
                  iconText: "󰈔"
                  tooltipText: "Open"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: { root.act(["open", String(row.modelData.id)]); root.close() }
                }
                PanelActionButton {
                  visible: row.modelData.state === "complete"
                  enabled: !actProc.running
                  iconText: "󰉋"
                  tooltipText: "Show in folder"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: { root.act(["show", String(row.modelData.id)]); root.close() }
                }
              }
            }
          }
        }
      }
    }
  }
}
