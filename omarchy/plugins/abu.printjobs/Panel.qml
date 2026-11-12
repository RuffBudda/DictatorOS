import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Print queue in the bar. The printer icon appears while CUPS has jobs
// (`lpstat -o`, every 2 s) and opens a panel listing them: title, printer,
// state, size and age, with pause/resume and cancel per job, cancel all, and
// each printer's status. Job titles come from whatever sent them, so every
// text here is plain text.
Panel {
  id: root
  moduleName: "abu.printjobs"
  ipcTarget: "abu.printjobs"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string helper: String(Qt.resolvedUrl("scripts/printjobs")).replace(/^file:\/\//, "")

  property int queued: 0            // from lpstat (cheap, always on)
  property var jobs: []             // from the helper (only while the panel is open)
  property var printers: []
  property string errorText: ""
  property int confirmCancelAll: 0  // 0 = not asked, 1 = asked once

  visible: queued > 0 || opened
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function refresh() {
    if (!listProc.running) listProc.running = true
  }
  function act(args) {
    if (actProc.running) return
    actProc.command = [root.helper].concat(args)
    actProc.running = true
  }
  function ago(sec) {
    if (sec < 60) return "just now"
    if (sec < 3600) return Math.floor(sec / 60) + " min ago"
    return Math.floor(sec / 3600) + " h ago"
  }
  // 0..1 when the driver reports pages, -1 when it doesn't (show an
  // indeterminate bar while printing), null when there's nothing to show.
  function progress(job) {
    if (job.pagesTotal > 0) return Math.min(1, job.pagesDone / job.pagesTotal)
    return job.state === "printing" ? -1 : null
  }
  function progressText(job) {
    const parts = []
    if (job.pagesTotal > 0) parts.push("Page " + Math.min(job.pagesDone + (job.state === "printing" ? 1 : 0), job.pagesTotal)
                                       + " of " + job.pagesTotal + " · " + Math.round(100 * job.pagesDone / job.pagesTotal) + "%")
    else if (job.pagesDone > 0) parts.push(job.pagesDone + (job.pagesDone === 1 ? " page done" : " pages done"))
    const msg = job.status || printerMessage(job.printer)
    if (msg) parts.push(msg)
    return parts.join(" · ")
  }
  function printerMessage(name) {
    for (const p of root.printers) if (p.name === name) return p.message || ""
    return ""
  }
  readonly property bool anyPrinting: jobs.some(j => j.state === "printing")
  function size(kb) { return kb >= 1024 ? (kb / 1024).toFixed(1) + " MB" : kb + " KB" }
  function printerLabel(name) {
    for (const p of root.printers) if (p.name === name) return p.info || name
    return String(name).replace(/_/g, " ")
  }
  function stateLabel(s) {
    return ({ printing: "Printing", pending: "Waiting", held: "Paused", stopped: "Stopped" })[s] || s
  }

  onOpenedChanged: { confirmCancelAll = 0; if (opened) refresh() }

  // Bar icon: count queued jobs (lines of `lpstat -o`).
  Process {
    id: lpstat
    command: ["lpstat", "-o"]
    stdout: StdioCollector {
      onStreamFinished: root.queued = this.text.split("\n").filter(l => l.trim() !== "").length
    }
    onExited: function(code) { if (code !== 0) root.queued = 0 }
  }
  Timer {
    interval: root.opened && root.anyPrinting ? 1000 : 2000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: {
      if (!lpstat.running) lpstat.running = true
      if (root.opened) root.refresh()
    }
  }

  Process {
    id: listProc
    command: [root.helper, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const r = JSON.parse(this.text)
          if (r.ok) { root.jobs = r.jobs || []; root.printers = r.printers || []; root.errorText = "" }
          else root.errorText = String(r.error || "Couldn't read the print queue")
        } catch (e) { root.errorText = "Couldn't read the print queue" }
      }
    }
  }
  Process {
    id: actProc
    stdout: StdioCollector {
      onStreamFinished: {
        try { const r = JSON.parse(this.text); root.errorText = r.ok ? "" : String(r.error || "") } catch (e) {}
      }
    }
    onExited: { root.refresh(); if (!lpstat.running) lpstat.running = true }
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: "󰐪"
    slotSize: Style.bar.statusSlot
    tooltipText: root.opened ? "" : (root.queued === 1 ? "1 print job" : root.queued + " print jobs")
    onPressed: function(b) {
      if (b === Qt.RightButton && root.bar) root.bar.run("system-config-printer")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(400))
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

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property int count: root.jobs.length
            readonly property bool busy: actProc.running

            PanelHero {
              id: hero
              width: parent.width
              title: header.count === 0 ? "Nothing printing" : (header.count === 1 ? "1 print job" : header.count + " print jobs")
              meta: header.count === 0 ? "The queue is empty"
                    : root.stateLabel(root.jobs[0].state) + " on " + root.printerLabel(root.jobs[0].printer)
                      + (root.jobs[0].pagesTotal > 0 ? " · " + Math.round(100 * root.jobs[0].pagesDone / root.jobs[0].pagesTotal) + "%" : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󰐪"
                  color: root.foreground
                  font.family: hero.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                PanelActionButton {
                  visible: header.count > 1
                  enabled: !header.busy
                  iconText: "󰅙"
                  tooltipText: root.confirmCancelAll ? "Click again to cancel all " + header.count + " jobs" : "Cancel all jobs"
                  foreground: root.confirmCancelAll ? root.urgent : hero.foreground
                  fontFamily: hero.fontFamily
                  onClicked: {
                    if (root.confirmCancelAll) { root.confirmCancelAll = 0; root.act(["cancel-all"]) }
                    else root.confirmCancelAll = 1
                  }
                }
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

          PanelSeparator { width: parent.width; foreground: root.foreground; visible: root.jobs.length > 0 }

          PanelSectionHeader {
            visible: root.jobs.length > 0
            text: "QUEUE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.jobs

            CursorSurface {
              id: jobItem
              required property var modelData
              width: content.width
              implicitHeight: jobRow.implicitHeight + Style.space(12)
              current: modelData.state === "printing"
              foreground: root.foreground

              RowLayout {
                id: jobRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: jobItem.modelData.state === "held" ? "󰏤" : jobItem.modelData.state === "printing" ? "󰐪" : "󰔟"
                  color: jobItem.modelData.state === "printing" ? root.foreground : root.dim
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
                    text: jobItem.modelData.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: jobItem.modelData.state === "printing"
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.stateLabel(jobItem.modelData.state) + " · " + root.printerLabel(jobItem.modelData.printer)
                          + " · " + root.size(jobItem.modelData.sizeKb) + " · " + root.ago(jobItem.modelData.age)
                    color: jobItem.modelData.state === "stopped" ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  // Progress: a bar (filled to the page count, or a sliding segment
                  // when the driver doesn't report pages) plus "Page 2 of 5 · 40%"
                  // and/or the printer's own status message.
                  Item {
                    id: bar
                    readonly property var value: root.progress(jobItem.modelData)
                    visible: value !== null
                    Layout.fillWidth: true
                    Layout.topMargin: Style.space(4)
                    implicitHeight: Style.space(4)
                    Rectangle {
                      anchors.fill: parent
                      radius: height / 2
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                    }
                    Rectangle {
                      visible: bar.value !== null && bar.value >= 0
                      width: parent.width * Math.max(0, bar.value || 0)
                      height: parent.height
                      radius: height / 2
                      color: root.foreground
                      Behavior on width { NumberAnimation { duration: Style.duration(250); easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                      id: slider
                      visible: bar.value === -1
                      width: parent.width * 0.3
                      height: parent.height
                      radius: height / 2
                      color: root.foreground
                      NumberAnimation on x {
                        running: slider.visible && root.opened && Style.duration(1000) > 0
                        loops: Animation.Infinite
                        from: -slider.width
                        to: bar.width
                        duration: 1400
                      }
                    }
                    clip: true
                  }
                  Text {
                    readonly property string line: root.progressText(jobItem.modelData)
                    visible: line !== ""
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: line
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  enabled: !actProc.running && jobItem.modelData.state !== "printing"
                  iconText: jobItem.modelData.state === "held" ? "󰐊" : "󰏤"
                  tooltipText: jobItem.modelData.state === "held" ? "Resume" : "Pause"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act([jobItem.modelData.state === "held" ? "release" : "hold", String(jobItem.modelData.id)])
                }
                PanelActionButton {
                  enabled: !actProc.running
                  iconText: "󰅖"
                  tooltipText: "Cancel"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act(["cancel", String(jobItem.modelData.id)])
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)
            PanelSectionHeader {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: "PRINTERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            PanelActionButton {
              iconText: "󰒓"
              tooltipText: "Printer settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.alignment: Qt.AlignVCenter
              onClicked: { root.close(); if (root.bar) root.bar.run("system-config-printer") }
            }
          }

          Repeater {
            model: root.printers
            RowLayout {
              required property var modelData
              width: content.width
              spacing: Style.space(8)
              Text {
                textFormat: Text.PlainText
                text: "󰐪"
                color: modelData.state === "stopped" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                Layout.leftMargin: Style.space(8)
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: modelData.info
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.state === "stopped" ? "Stopped" + (modelData.message ? ": " + modelData.message : "")
                      : !modelData.accepting ? "Not accepting jobs"
                      : modelData.state === "printing" ? "Printing" : "Ready"
                color: modelData.state === "stopped" || !modelData.accepting ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                Layout.maximumWidth: content.width * 0.45
                Layout.rightMargin: Style.space(6)
              }
            }
          }
        }
      }
    }
  }
}
