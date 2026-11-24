import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Agents working through desktop-mcp (~/dotfiles/desktop-mcp).
// Each agent's MCP server writes $XDG_RUNTIME_DIR/desktop-mcp/agents/<id>.json;
// `desktop-mcp-ctl list` reads them (pruning dead ones) every second.
// The icon shows while any agent is running and turns urgent + pulses when one
// asks for you (request_user_input, or a blocked password prompt).
// Agent labels and messages are untrusted, so every text here is plain text.
// Hard stop: the stop button on a row kills that agent's MCP server and all it
// started; "Stop all" (also SUPER+CTRL+ESCAPE) kills every agent and refuses
// desktop control until you press Resume.
Panel {
  id: root
  moduleName: "abu.agent-desk"
  ipcTarget: "abu.agent-desk"

  readonly property string ctl: Quickshell.env("HOME") + "/dotfiles/desktop-mcp/bin/desktop-mcp-ctl"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var agents: []
  property real now: Date.now()
  property string errorText: ""
  property bool halted: false

  readonly property var needy: agents.filter(a => a.attention)
  readonly property bool needsYou: needy.length > 0

  visible: agents.length > 0 || halted || opened
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  function refresh() { if (!readProc.running) readProc.running = true }
  function act(args) {
    // Panic has its own process so a busy action can never swallow it.
    if (args[0] === "panic") { if (!panicProc.running) panicProc.running = true; return }
    if (actProc.running) return
    actProc.command = [root.ctl].concat(args)
    actProc.running = true
  }
  function clip(s, n) { s = String(s || ""); return s.length > n ? s.slice(0, n - 1) + "…" : s }
  function ago(ms) {
    const sec = Math.max(0, Math.floor((now - ms) / 1000))
    if (sec < 5) return "now"
    if (sec < 60) return sec + " s ago"
    if (sec < 3600) return Math.floor(sec / 60) + " min ago"
    return Math.floor(sec / 3600) + " h ago"
  }
  function caption(a) {
    if (a.attention) return "Needs you · " + ago(a.attention.since)
    const where = a.sandbox ? "own desktop" : "your desktop"
    if (a.lastAction && now - a.lastAction.at < 60000) return "Working in " + where + " · " + clip(a.lastAction.name, 24).replace(/_/g, " ") + " " + ago(a.lastAction.at)
    return "Idle · " + where
  }
  function safeColor(c) { return /^#[0-9a-fA-F]{6}$/.test(String(c)) ? c : root.foreground }

  Process {
    id: readProc
    command: [root.ctl, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.now = Date.now()
        try {
          const r = JSON.parse(this.text)
          root.agents = Array.isArray(r.agents) ? r.agents.slice(0, 20) : []
          root.halted = r.halted === true
        } catch (e) { root.agents = []; root.halted = false }
      }
    }
  }
  Process {
    id: actProc
    stdout: StdioCollector {
      onStreamFinished: {
        try { const r = JSON.parse(this.text); root.errorText = r.ok ? "" : clip(r.error, 160) }
        catch (e) { root.errorText = "Couldn't reach desktop-mcp-ctl" }
      }
    }
    onExited: root.refresh()
  }
  Process {
    id: panicProc
    command: [root.ctl, "panic"]
    onExited: root.refresh()
  }
  Timer {
    interval: 1000; running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Beside the clock: a quiet "󰍹 N" while agents work, and an urgent pulsing
  // "󰂞 <agent> needs you" pill when one asks for you.
  WidgetButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: root.halted && root.agents.length === 0 ? "󰓛 stopped"
          : root.needsYou
          ? "󰂞  " + (root.needy.length === 1 ? root.clip(root.needy[0].label, 20) + " needs you" : root.needy.length + " agents need you")
          : "󰍹 " + root.agents.length
    labelVisible: true
    active: root.needsYou || root.halted
    dimmed: !root.needsYou && !root.halted
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.opened ? "" : root.halted ? "Agent desktop control is stopped"
                 : root.needsYou ? root.clip(root.needy[0].attention.message, 120)
                 : (root.agents.length === 1 ? "1 agent working in its own desktop" : root.agents.length + " agents working")
    onPressed: function(b) { root.toggle() }

    SequentialAnimation on opacity {
      running: root.needsYou && !root.opened && Style.duration(1000) > 0
      loops: Animation.Infinite
      onRunningChanged: if (!running) barButton.opacity = 1
      NumberAnimation { from: 1; to: 0.45; duration: 800; easing.type: Easing.OutCubic }
      NumberAnimation { from: 0.45; to: 1; duration: 800; easing.type: Easing.OutCubic }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(440))
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
            title: root.needsYou ? (root.needy.length === 1 ? "An agent needs you" : root.needy.length + " agents need you") : "Agent desktops"
            meta: root.halted ? "Stopped · agents are refused"
                  : root.agents.length === 0 ? "No agents running"
                  : root.agents.length === 1 ? "1 agent" : root.agents.length + " agents"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.needsYou ? "󰂞" : "󰍹"
                color: root.needsYou ? root.urgent : root.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.agents.length > 0 || root.halted

            Button {
              visible: root.agents.length > 0 || !root.halted
              text: "󰓛  Stop all agents"
              tooltipText: "Hard stop: kill every agent's desktop control now (SUPER+CTRL+ESCAPE)"
              foreground: root.urgent
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act(["panic"])
            }
            Button {
              visible: root.halted
              enabled: !actProc.running
              text: "󰐊  Resume"
              tooltipText: "Allow agents to control the desktop again (reconnect their MCP server, e.g. /mcp in Claude Code)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.act(["resume"])
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

          PanelSeparator { width: parent.width; foreground: root.foreground; visible: root.agents.length > 0 }

          Repeater {
            model: root.agents

            CursorSurface {
              id: row
              required property var modelData
              width: content.width
              implicitHeight: rowLayout.implicitHeight + Style.space(14)
              current: !!modelData.attention
              foreground: root.foreground

              RowLayout {
                id: rowLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(10)

                Rectangle {
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.space(4)
                  width: Style.space(10); height: width; radius: width / 2
                  color: root.safeColor(row.modelData.color)
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(2)
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.clip(row.modelData.label, 40)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    visible: !!row.modelData.attention
                    textFormat: Text.PlainText
                    text: row.modelData.attention ? root.clip(row.modelData.attention.message, 300) : ""
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.caption(row.modelData)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelActionButton {
                  visible: !!row.modelData.sandbox
                  enabled: !actProc.running
                  iconText: "󰍹"
                  tooltipText: "Show its desktop"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: { root.act(["show", String(row.modelData.id)]); root.close() }
                }
                PanelActionButton {
                  visible: !!row.modelData.attention
                  enabled: !actProc.running
                  iconText: "󰄬"
                  tooltipText: "Done: let the agent continue"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act(["ack", String(row.modelData.id)])
                }
                PanelActionButton {
                  enabled: !actProc.running
                  iconText: "󰓛"
                  tooltipText: "Hard stop: kill this agent's desktop control"
                  foreground: root.urgent
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act(["kill", String(row.modelData.id)])
                }
                PanelActionButton {
                  visible: !!row.modelData.sandbox
                  enabled: !actProc.running
                  iconText: "󰅖"
                  tooltipText: "Close its desktop"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  Layout.alignment: Qt.AlignVCenter
                  onClicked: root.act(["stop", String(row.modelData.id)])
                }
              }
            }
          }
        }
      }
    }
  }
}
