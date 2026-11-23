// desktop-mcp overlay: draws labeled agent cursors on a click-through layer.
// One instance per Wayland display. Control it by writing JSON lines to the
// Unix socket in $DMCP_SOCKET:
//   {"op":"move","id":"a1","x":100,"y":200,"label":"Claude","color":"#d97757"}
//   {"op":"click","id":"a1","x":100,"y":200}        // move + ripple
//   {"op":"hide","id":"a1"}                          // fade out until the next move/click (agent is idle)
//   {"op":"remove","id":"a1"}
//   {"op":"suspend"} / {"op":"resume"}               // hide everything (for screenshots)
//   {"op":"ping"}
// Coordinates are global logical compositor coordinates.
// On the host, a cursor belongs to the workspace it was put on: it is not drawn
// while that monitor shows a different workspace (or a special workspace on top).
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
  id: root

  property var cursors: ({})        // id -> {x, y, label, color, clickSeq, hidden, where}
  property int revision: 0          // bump to refresh bindings
  property bool suspended: false

  function handle(line) {
    let m;
    try { m = JSON.parse(line); } catch (e) { console.warn("bad message", line); return; }
    const c = root.cursors;
    if (m.op === "move" || m.op === "click") {
      const prev = c[m.id] || { label: m.id, color: "#d97757", clickSeq: 0, x: m.x, y: m.y };
      c[m.id] = {
        x: m.x, y: m.y,
        label: m.label ?? prev.label,
        color: m.color ?? prev.color,
        clickSeq: prev.clickSeq + (m.op === "click" ? 1 : 0),
        hidden: false,
        where: root.placeOf(m.x, m.y),
      };
    } else if (m.op === "hide") {
      if (c[m.id]) c[m.id] = Object.assign({}, c[m.id], { hidden: true });
    } else if (m.op === "remove") {
      delete c[m.id];
    } else if (m.op === "suspend") {
      root.suspended = true;
    } else if (m.op === "resume") {
      root.suspended = false;
    }
    root.cursors = c;
    root.revision++;
  }

  // ---- which workspace a cursor belongs to (host overlay only) -------------
  // monitor name -> name of the special workspace open on it ("" = none), from Hyprland events.
  property var specials: ({})
  function specialOf(mon) {
    if (!mon) return "";
    const s = root.specials[mon.name];
    if (s !== undefined) return s;
    const o = mon.lastIpcObject;   // state from before this overlay started
    return (o && o.specialWorkspace && o.specialWorkspace.name) || "";
  }
  function wsOf(mon) { return mon && mon.activeWorkspace ? mon.activeWorkspace.id : 0; }
  // The monitor + workspace now shown at a point; null when unknown (the cursor is then always drawn).
  function placeOf(x, y) {
    if (!root.isHost) return null;
    const screens = Quickshell.screens;
    for (let i = 0; i < screens.length; i++) {
      const s = screens[i];
      if (x < s.x || y < s.y || x >= s.x + s.width || y >= s.y + s.height) continue;
      const mon = Hyprland.monitorFor(s);
      return mon ? { mon: mon.name, ws: root.wsOf(mon), special: root.specialOf(mon) } : null;
    }
    return null;
  }
  Connections {
    target: root.isHost ? Hyprland : null
    function onRawEvent(event) {
      if (event.name !== "activespecial") return;   // data: "<workspace name or empty>,<monitor name>"
      const i = event.data.lastIndexOf(",");
      if (i < 0) return;
      const s = Object.assign({}, root.specials);
      s[event.data.slice(i + 1)] = event.data.slice(0, i);
      root.specials = s;
    }
  }

  // ---- "an agent needs you" banner (host overlay only) -------------------
  // Shown when an agent asked for the user and the bar can't show it: the bar
  // is hidden (Super+B) or a fullscreen window covers it. This layer is the
  // Overlay layer, which Hyprland draws above fullscreen windows.
  readonly property bool isHost: Quickshell.env("DMCP_ROLE") === "host"
  readonly property string ctl: Quickshell.env("DMCP_CTL")
  property var alert: ({ show: false, needy: [] })
  readonly property bool bannerShown: isHost && alert.show && alert.needy.length > 0

  Process {
    id: alertProc
    command: [root.ctl, "alert"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const r = JSON.parse(this.text);
          root.alert = { show: !!r.show, needy: Array.isArray(r.needy) ? r.needy.slice(0, 5) : [] };
        } catch (e) { root.alert = { show: false, needy: [] }; }
      }
    }
  }
  Process { id: actProc }
  function act(args) {
    if (actProc.running) return;
    actProc.command = [root.ctl].concat(args);
    actProc.running = true;
    alertTimer.restart();
  }
  Timer {
    id: alertTimer
    interval: 1000; repeat: true; triggeredOnStart: true
    running: root.isHost && root.ctl !== ""
    onTriggered: if (!alertProc.running) alertProc.running = true
  }
  function clip(s, n) { s = String(s || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s; }
  function safeColor(c) { return /^#[0-9a-fA-F]{6}$/.test(String(c)) ? c : "#d97757"; }

  SocketServer {
    active: true
    path: Quickshell.env("DMCP_SOCKET")
    handler: Socket {
      parser: SplitParser { onRead: (line) => root.handle(line) }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "desktop-mcp-overlay"
      readonly property var hmon: root.isHost ? Hyprland.monitorFor(modelData) : null
      // True when this monitor still shows the workspace the cursor was put on.
      function showsPlace(where) {
        if (!where || !hmon) return true;
        return where.mon === hmon.name && where.ws === root.wsOf(hmon) && where.special === root.specialOf(hmon);
      }
      // Click-through everywhere, except the banner while it is shown.
      Region { id: noInput }
      Region { id: bannerInput; item: banner }
      mask: root.bannerShown ? bannerInput : noInput

      // The banner is not hidden during agent screenshots: it is the user's, not the agent's.
      Rectangle {
        id: banner
        visible: root.bannerShown
        z: 10
        anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 18 }
        width: Math.min(760, parent.width - 40)
        height: bannerCol.implicitHeight + 24
        radius: 14
        color: "#1d1d22"
        border.color: root.alert.needy.length ? root.safeColor(root.alert.needy[0].color) : "#d97757"
        border.width: 2
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Column {
          id: bannerCol
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 18; rightMargin: 12 }
          spacing: 8

          Repeater {
            model: root.alert.needy

            Item {
              id: arow
              required property var modelData
              width: bannerCol.width
              height: Math.max(36, msgCol.implicitHeight)

              Text {
                id: bell
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                textFormat: Text.PlainText
                text: "󰂞"
                color: root.safeColor(arow.modelData.color)
                font.pixelSize: 24
              }
              Column {
                id: msgCol
                anchors { left: bell.right; leftMargin: 14; right: buttons.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 2
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.clip(arow.modelData.label, 30) + " needs you"
                  color: "white"; font.pixelSize: 15; font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.clip(arow.modelData.message, 300)
                  color: "#c8c8d0"; font.pixelSize: 13
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
              }
              Row {
                id: buttons
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                spacing: 8
                Repeater {
                  model: arow.modelData.sandbox ? [["Show", "show"], ["Done", "ack"]] : [["Done", "ack"]]
                  Rectangle {
                    required property var modelData
                    width: lbl.implicitWidth + 24; height: 30; radius: 8
                    color: ma.containsMouse ? "#3a3a44" : "#2a2a32"
                    border.color: modelData[1] === "ack" ? root.safeColor(arow.modelData.color) : "#4a4a55"
                    Text { id: lbl; anchors.centerIn: parent; textFormat: Text.PlainText; text: parent.modelData[0]; color: "white"; font.pixelSize: 13 }
                    MouseArea {
                      id: ma
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.act([parent.modelData[1], String(arow.modelData.id)])
                    }
                  }
                }
              }
            }
          }
        }
      }

      Item {
        anchors.fill: parent
        visible: !root.suspended

        Repeater {
          model: { root.revision; return Object.keys(root.cursors); }

          Item {
            id: cur
            required property string modelData
            readonly property var info: { root.revision; return root.cursors[modelData] || null; }
            readonly property bool shown: info !== null && !info.hidden && win.showsPlace(info.where)
            opacity: shown ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            x: info ? info.x - win.modelData.x : 0
            y: info ? info.y - win.modelData.y : 0
            width: 1; height: 1
            Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

            property int lastClick: 0
            readonly property int clickSeq: info ? info.clickSeq : 0
            onClickSeqChanged: if (clickSeq > lastClick) { lastClick = clickSeq; ripple.restart(); }

            // click ripple
            Rectangle {
              id: ring
              width: 36; height: 36; radius: 18
              x: -18; y: -18
              color: "transparent"
              border.color: cur.info ? cur.info.color : "white"
              border.width: 3
              opacity: 0; scale: 0.3
              SequentialAnimation {
                id: ripple
                PauseAnimation { duration: 240 }
                ParallelAnimation {
                  NumberAnimation { target: ring; property: "opacity"; from: 0.95; to: 0; duration: 450 }
                  NumberAnimation { target: ring; property: "scale"; from: 0.3; to: 1.6; duration: 450; easing.type: Easing.OutQuad }
                }
              }
            }

            // arrow pointer
            Canvas {
              id: arrow
              x: -2; y: -2
              width: 26; height: 30
              property color fill: cur.info ? cur.info.color : "#d97757"
              onFillChanged: requestPaint()
              onPaint: {
                const g = getContext("2d");
                g.reset();
                g.beginPath();
                g.moveTo(3, 2); g.lineTo(3, 24); g.lineTo(9, 18.5);
                g.lineTo(13, 27); g.lineTo(17, 25.2); g.lineTo(13, 17); g.lineTo(21, 17);
                g.closePath();
                g.lineJoin = "round";
                g.lineWidth = 2.2;
                g.strokeStyle = "white";
                g.fillStyle = fill;
                g.fill(); g.stroke();
              }
            }

            // name tag
            Rectangle {
              x: 20; y: 22
              height: 20; width: tag.implicitWidth + 14
              radius: 10
              color: cur.info ? cur.info.color : "#d97757"
              border.color: "white"; border.width: 1.5
              Text {
                id: tag
                anchors.centerIn: parent
                text: cur.info ? cur.info.label : ""
                color: "white"; font.pixelSize: 11; font.bold: true
              }
            }
          }
        }
      }
    }
  }
}
