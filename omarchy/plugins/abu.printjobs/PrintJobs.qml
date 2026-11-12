import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A printer icon that appears in the bar while CUPS has jobs queued
// (`lpstat -o`, checked every 2 s) and disappears when they're done.
// Left click: the print queue. Right click: printer settings.
BarWidget {
  id: root
  moduleName: "abu.printjobs"

  property int jobCount: 0
  property var printers: []

  visible: jobCount > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Printer names come from the system's CUPS config; keep them plain and short.
  function clean(s) { return String(s).replace(/[^\w .()-]/g, "").slice(0, 48) }

  function parse(text) {
    const lines = text.split("\n").filter(l => l.trim() !== "").slice(0, 500)
    const names = []
    for (const l of lines) {
      // "<printer>-<job id> <user> <size> <date>"
      const id = l.trim().split(/\s+/)[0] || ""
      const p = clean(id.replace(/-\d+$/, "").replace(/_/g, " "))
      if (p && names.indexOf(p) < 0) names.push(p)
    }
    root.printers = names
    root.jobCount = lines.length
  }

  Process {
    id: lpstat
    command: ["lpstat", "-o"]
    stdout: StdioCollector { onStreamFinished: root.parse(this.text) }
    onExited: function(code) { if (code !== 0) root.jobCount = 0 }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!lpstat.running) lpstat.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐪"
    slotSize: Style.bar.statusSlot
    tooltipText: (root.jobCount === 1 ? "Printing 1 job" : "Printing " + root.jobCount + " jobs")
                 + (root.printers.length ? " on " + root.printers.join(", ") : "")
                 + "\nClick: print queue · Right-click: printers"
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.bar.run("system-config-printer")
      else root.bar.run("xdg-open http://localhost:631/jobs/")
    }
  }
}
