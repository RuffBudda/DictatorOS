// Desktop widget: GitHub contribution graph on the wallpaper layer (behind
// windows). Data: ~/dotfiles/bin/github-contrib -> ~/.cache/github-contrib.json
// (uses the signed-in GitHub CLI account). Refreshes every 30 minutes.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string cacheFile: home + "/.cache/github-contrib.json"
  readonly property string fetcher: home + "/dotfiles/bin/github-contrib"

  property var weeks: []
  property int total: 0
  property string login: ""
  property int maxCount: 1
  // Spacing matches Hyprland's window gaps: 12 px to the screen edge
  // (gaps_out 10 + 2 px border) and 14 px between windows.
  readonly property int edgeGap: 12
  readonly property int boxGap: 14
  readonly property int pad: 12
  // One red for every widget border (same colour and strength).
  readonly property color borderColor: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.6)

  function load(text) {
    try {
      var d = JSON.parse(text)
      root.weeks = d.weeks || []
      root.total = d.total || 0
      root.login = d.login || ""
      var m = 1
      for (var i = 0; i < root.weeks.length; i++)
        for (var j = 0; j < root.weeks[i].length; j++) m = Math.max(m, root.weeks[i][j].c)
      root.maxCount = m
    } catch (e) {}
  }

  // GitHub-style 5 levels, in the theme's accent (red).
  function cellColor(c) {
    if (c <= 0) return Qt.rgba(1, 1, 1, 0.05)
    var a = Commons.Color.accent
    var r = c / root.maxCount
    var alpha = r > 0.75 ? 1.0 : r > 0.5 ? 0.8 : r > 0.25 ? 0.62 : 0.45
    return Qt.rgba(a.r, a.g, a.b, alpha)
  }

  FileView {
    id: cache
    path: root.cacheFile
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.load(text())
  }

  Process { id: fetchProc; command: [root.fetcher] }

  // WHOOP rings (recovery %, strain 0-21, sleep %). Hidden until connected
  // with ~/dotfiles/bin/whoop-auth. Data: ~/dotfiles/bin/whoop-fetch.
  property var whoop: null
  FileView {
    path: root.home + "/.cache/whoop.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { try { root.whoop = JSON.parse(text()) } catch (e) { root.whoop = null } }
  }
  Process { id: whoopProc; command: [root.home + "/dotfiles/bin/whoop-fetch"] }
  Timer {
    interval: 15 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!whoopProc.running) whoopProc.running = true
  }
  // CPU / GPU / RAM rings under the GitHub graph (~/dotfiles/bin/sysstats).
  property var sys: null
  Process {
    id: sysProc
    command: [root.home + "/dotfiles/bin/sysstats"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.sys = JSON.parse(text) } catch (e) {} }
    }
  }
  Timer {
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sysProc.running) sysProc.running = true
  }
  readonly property int ringGap: 2 * boxGap   // gap between rings (same as WHOOP)

  readonly property bool whoopReady: whoop !== null && (whoop.recovery !== null || whoop.strain !== null || whoop.sleep !== null)

  component Ring: Column {
    id: ring
    property real value: 0      // shown number
    property real fraction: 0   // 0..1 of the ring filled
    property string label: ""
    property string suffix: ""
    property bool hasValue: true
    property real size: 64
    spacing: Math.round(size * 0.1)
    Item {
      width: ring.size; height: ring.size
      anchors.horizontalCenter: parent.horizontalCenter
      Canvas {
        id: canvas
        anchors.fill: parent
        property real f: ring.hasValue ? Math.max(0, Math.min(1, ring.fraction)) : 0
        onFChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d"); ctx.reset()
          var lw = Math.max(4, ring.size * 0.09)
          var c = width / 2, r = c - lw / 2 - 1, a = Commons.Color.accent
          ctx.lineWidth = lw; ctx.lineCap = "round"
          ctx.strokeStyle = Qt.rgba(a.r, a.g, a.b, 0.15)
          ctx.beginPath(); ctx.arc(c, c, r, 0, 2 * Math.PI); ctx.stroke()
          if (f > 0) {
            ctx.strokeStyle = a
            ctx.beginPath(); ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + f * 2 * Math.PI); ctx.stroke()
          }
        }
      }
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: ring.hasValue ? (ring.suffix === "%" ? Math.round(ring.value) + "%" : ring.value.toFixed(1)) : "–"
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Math.round(ring.size * 0.2)
        font.weight: Font.DemiBold
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: ring.label
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: 12        // same format as the GitHub caption
      font.letterSpacing: 1
    }
  }

  Timer {
    interval: 30 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!fetchProc.running) fetchProc.running = true
  }

  // Main screen: the laptop panel if it's on, otherwise the first screen.
  readonly property var mainScreen: {
    var s = Quickshell.screens
    for (var i = 0; i < s.length; i++)
      if (/^(eDP|LVDS|DSI)-/.test(s[i].name)) return s[i]
    return s.length > 0 ? s[0] : null
  }

  // Two desktop widgets, each in its own corner with the same gaps as
  // windows (gaps_out 10 + border 2) and below the bar when it's shown.

  // GitHub graph: top-right corner.
  PanelWindow {
    screen: root.mainScreen
    visible: root.weeks.length > 0 && root.mainScreen !== null
    anchors { top: true; right: true }
    margins { top: root.edgeGap; right: root.edgeGap }
    implicitWidth: rightColumn.width
    implicitHeight: rightColumn.height
    color: "transparent"
    exclusionMode: ExclusionMode.Normal   // respect the bar's space, reserve none
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}   // clicks pass through to the desktop
    WlrLayershell.namespace: "abu-github-graph"

    Column {
      id: rightColumn
      spacing: root.boxGap

    Rectangle {
      id: frame
      width: card.implicitWidth + 2 * root.pad
      height: card.implicitHeight + 2 * root.pad
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.35)
      border.width: 0   // no outline
      border.color: root.borderColor

    ColumnLayout {
      id: card
      anchors.centerIn: parent
      spacing: 10
      readonly property int cell: 11
      readonly property int gap: 3

      Row {
        Layout.alignment: Qt.AlignRight
        spacing: card.gap
        Repeater {
          model: root.weeks
          Column {
            required property var modelData
            spacing: card.gap
            // Partial first/last weeks: pad so weekdays line up (Sunday on top).
            Item { width: card.cell; height: modelData.length > 0 ? modelData[0].w * (card.cell + card.gap) - (modelData[0].w > 0 ? 0 : 0) : 0; visible: height > 0 }
            Repeater {
              model: modelData
              Rectangle {
                required property var modelData
                width: card.cell; height: card.cell; radius: 2
                color: root.cellColor(modelData.c)
              }
            }
          }
        }
      }

      Text {
        Layout.alignment: Qt.AlignRight
        textFormat: Text.PlainText
        text: root.login + "  ·  " + root.total + " contributions in the last year"
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: 12
        font.letterSpacing: 1
      }

    }
    }
    }
  }

  // Top-left: WHOOP rings, and CPU / GPU / RAM rings under them (same sizing).
  PanelWindow {
    screen: root.mainScreen
    visible: (root.whoopReady || root.sys !== null) && root.mainScreen !== null
    anchors { top: true; left: true }
    margins { top: root.edgeGap; left: root.edgeGap }
    implicitWidth: leftColumn.width
    implicitHeight: leftColumn.height
    color: "transparent"
    exclusionMode: ExclusionMode.Normal   // respect the bar's space, reserve none
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}   // clicks pass through to the desktop
    WlrLayershell.namespace: "abu-whoop-rings"

    Column {
      id: leftColumn
      spacing: root.boxGap

    Rectangle {
      id: whoopFrame
      visible: root.whoopReady
      width: ringsRow.implicitWidth + 2 * root.pad
      // Same height as the GitHub box; rings sized to fit (ring + gap + label).
      height: frame.height
      readonly property real ringSize: Math.max(40, Math.floor((frame.height - 2 * root.pad - 16) / 1.1))
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.35)
      border.width: 0   // no outline
      border.color: root.borderColor

      Row {
        id: ringsRow
        anchors.centerIn: parent
        spacing: 2 * root.boxGap
        Ring {
          size: whoopFrame.ringSize
          label: "RECOVERY"; suffix: "%"
          hasValue: root.whoop !== null && root.whoop.recovery !== null && root.whoop.recovery !== undefined
          value: hasValue ? root.whoop.recovery : 0
          fraction: value / 100
        }
        Ring {
          size: whoopFrame.ringSize
          label: "STRAIN"
          hasValue: root.whoop !== null && root.whoop.strain !== null && root.whoop.strain !== undefined
          value: hasValue ? root.whoop.strain : 0
          fraction: value / 21
        }
        Ring {
          size: whoopFrame.ringSize
          label: "SLEEP"; suffix: "%"
          hasValue: root.whoop !== null && root.whoop.sleep !== null && root.whoop.sleep !== undefined
          value: hasValue ? root.whoop.sleep : 0
          fraction: value / 100
        }
      }
    }


    // CPU / GPU / RAM: under WHOOP, same ring size, gap and height.
    Rectangle {
      id: sysFrame
      visible: root.sys !== null
      width: sysRow.implicitWidth + 2 * root.pad
      height: frame.height
      readonly property real ringSize: whoopFrame.ringSize
      radius: Style.cornerRadius
      color: Qt.rgba(0, 0, 0, 0.35)
      border.width: 0   // no outline

      Row {
        id: sysRow
        anchors.centerIn: parent
        spacing: root.ringGap
        Ring {
          size: sysFrame.ringSize
          label: "CPU"; suffix: "%"
          value: root.sys ? root.sys.cpu : 0
          fraction: value / 100
        }
        Ring {
          size: sysFrame.ringSize
          label: "GPU"; suffix: "%"
          value: root.sys ? root.sys.gpu : 0
          fraction: value / 100
        }
        Ring {
          size: sysFrame.ringSize
          label: "RAM"; suffix: "%"
          value: root.sys ? root.sys.ram : 0
          fraction: value / 100
        }
      }
    }
    }
  }
}
