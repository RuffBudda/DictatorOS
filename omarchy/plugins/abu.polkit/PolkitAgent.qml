import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel

Item {
  id: root

  property string fontFamily: Style.font.menuFamily
  // Bound to the central [polkit] section in shell.toml via Commons.Color.qml.
  property color accent: Commons.Color.polkit.accent
  property color background: Commons.Color.polkit.background
  property color foreground: Commons.Color.polkit.text
  property color border: Commons.Color.polkit.border
  property color borderError: Commons.Color.polkit.borderError
  property var borderSpec: Border.surfaceSpec("polkit", errorFlash ? "border-error" : "border", errorFlash ? borderError : border, Math.max(1, Style.space(2)), "border-alpha")
  property color scrim: Commons.Color.polkit.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int fieldHeight: Math.max(Style.space(42), Style.spacing.controlHeight)

  property bool closing: false
  property bool submitted: false
  property string currentMessage: ""
  property string currentPrompt: ""
  property string currentSupplementary: ""
  property bool responseRequired: false
  property bool responseVisible: false
  property bool failed: false
  property bool errorFlash: false
  // pam_fprintd appears in the polkit PAM stack (a sensor is enrolled).
  property bool fingerprintConfigured: false
  // Lid shut right now — the reader is physically unreachable, so we fall back
  // to the password even when a sensor is enrolled. Refreshed per request.
  property bool laptopClosed: false
  property int shakeOffset: 0

  readonly property bool dialogVisible: polkitAgent.isActive || closing
  // We show one method at a time. Fingerprint owns the dialog while PAM is
  // waiting on the reader (lid open, sensor enrolled); the moment PAM asks for
  // a password — including immediately when the lid is shut and the clamshell
  // gate skips pam_fprintd — we switch to the password field instead.
  readonly property bool fingerprintMode: fingerprintConfigured && !laptopClosed && dialogVisible && !responseRequired && !submitted && !errorFlash
  readonly property int cardHeight: panel.height > 0 ? Math.min(fieldHeight + contentMargin * 2, panel.height - Style.gapsOut * 2) : fieldHeight + contentMargin * 2
  // Password mode is a wide field; fingerprint mode collapses to a square that
  // just frames the centered sensor icon.
  readonly property int cardWidth: fingerprintMode ? cardHeight : Math.min(Style.space(312), Math.max(Style.space(260), panel.width - Style.gapsOut * 2))

  function authorizationLabel(message) {
    return message ? PolkitModel.authorizationLabel(message, I18n.t) : I18n.t("polkit.authenticationNeeded")
  }

  function loadPamConfig(raw) {
    fingerprintConfigured = PolkitModel.fingerprintConfiguredFromPamConfig(raw)
  }

  function refreshLidState() {
    if (!laptopClosedProc.running) laptopClosedProc.running = true
  }

  function resetSnapshot() {
    currentMessage = ""
    currentPrompt = ""
    currentSupplementary = ""
    responseRequired = false
    responseVisible = false
    failed = false
    errorFlash = false
    submitted = false
    passwordInput.text = ""
  }

  function syncFromFlow() {
    var flow = polkitAgent.flow
    if (!flow) return

    currentMessage = String(flow.message || "")
    currentPrompt = String(flow.inputPrompt || "")
    currentSupplementary = String(flow.supplementaryMessage || "")
    responseRequired = !!flow.isResponseRequired
    responseVisible = !!flow.responseVisible
    failed = !!flow.failed

    if (responseRequired) submitted = false
  }

  function beginFlow() {
    closeTimer.stop()
    closing = false
    submitted = false
    passwordInput.text = ""
    refreshLidState()
    syncFromFlow()
    Qt.callLater(refocus)
  }

  function refocus() {
    if (!dialogVisible) return
    // In fingerprint mode there is no field to type into — park focus on the
    // key catcher so Escape still cancels; otherwise focus the password field.
    if (fingerprintMode) keyCatcher.forceActiveFocus()
    else passwordInput.forceActiveFocus()
  }

  function submitResponse() {
    var flow = polkitAgent.flow
    if (!flow || !flow.isResponseRequired) return
    submitted = true
    errorFlash = false
    flow.submit(passwordInput.text)
    passwordInput.text = ""
    keyCatcher.forceActiveFocus()
  }

  function cancelRequest() {
    var flow = polkitAgent.flow
    passwordInput.text = ""
    submitted = false
    closing = true
    closeTimer.restart()
    if (flow) flow.cancelAuthenticationRequest()
  }

  function triggerFailureFeedback() {
    submitted = false
    errorFlash = true
    passwordInput.text = ""
    errorTimer.restart()
    shakeAnimation.restart()
    Qt.callLater(refocus)
  }

  Timer {
    id: closeTimer
    interval: 300
    repeat: false
    onTriggered: {
      closing = false
      resetSnapshot()
    }
  }

  Timer {
    id: errorTimer
    interval: 1200
    repeat: false
    onTriggered: root.errorFlash = false
  }

  SequentialAnimation {
    id: shakeAnimation
    NumberAnimation { target: root; property: "shakeOffset"; to: -8; duration: Style.duration(35); easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 8; duration: Style.duration(50); easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: Style.duration(55); easing.type: Easing.OutQuad }
  }
  FileView {
    path: "/etc/pam.d/polkit-1"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPamConfig(text())
    onLoadFailed: root.fingerprintConfigured = false
    onFileChanged: reload()
  }

  Process {
    id: laptopClosedProc
    command: ["bash", "-c", "omarchy-hw-laptop-closed && echo closed || echo open"]
    stdout: StdioCollector { id: laptopClosedOut; waitForEnd: true }
    onExited: root.laptopClosed = String(laptopClosedOut.text || "").trim() === "closed"
  }

  PolkitAgent {
    id: polkitAgent
    path: "/org/omarchy/PolkitAgent"

    onAuthenticationRequestStarted: root.beginFlow()
    onIsActiveChanged: {
      if (isActive) root.syncFromFlow()
      else if (!root.closing) root.resetSnapshot()
    }
    onIsRegisteredChanged: {
      if (isRegistered) console.log("omarchy polkit agent registered")
      else console.warn("omarchy polkit agent is not registered; another agent may be running")
    }
  }

  Connections {
    target: polkitAgent.flow

    function onIsResponseRequiredChanged() {
      root.syncFromFlow()
      if (!polkitAgent.flow || !polkitAgent.flow.isResponseRequired) passwordInput.text = ""
      Qt.callLater(root.refocus)
    }

    function onInputPromptChanged() { root.syncFromFlow() }
    function onResponseVisibleChanged() { root.syncFromFlow() }
    function onSupplementaryMessageChanged() { root.syncFromFlow() }
    function onFailedChanged() { root.syncFromFlow() }

    function onAuthenticationFailed() {
      root.syncFromFlow()
      root.triggerFailureFeedback()
    }

    function onAuthenticationSucceeded() {
      root.closing = true
      closeTimer.restart()
    }

    function onAuthenticationRequestCancelled() {
      root.closing = true
      closeTimer.restart()
    }
  }

  // ── Lock-screen look (dotfiles): full black screen, big thin red clock,
  //    red ✱ stars under it, no box. A dim line says what is asking. ──
  property string clockText: Qt.formatTime(new Date(), "HH:mm")

  Timer {
    interval: 1000
    running: root.dialogVisible
    repeat: true
    triggeredOnStart: true
    onTriggered: root.clockText = Qt.formatTime(new Date(), "HH:mm")
  }

  PanelWindow {
    id: panel
    Binding { target: panel.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
    Binding { target: panel.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

    visible: root.dialogVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "#000000"
    WlrLayershell.namespace: "omarchy-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    readonly property int fieldWidth: 381
    readonly property int fieldHeight: 67
    readonly property int starSize: Math.round(Style.font.heading * 1.33)
    readonly property int starSpacing: Math.round(Style.font.heading * 0.6)

    MouseArea {
      anchors.fill: parent
      onClicked: root.refocus()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.cancelRequest()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (root.responseRequired) root.submitResponse()
          event.accepted = true
        }
      }
    }

    Text {
      id: clock
      textFormat: Text.PlainText
      text: root.clockText
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: field.top
      anchors.bottomMargin: Math.round(panel.fieldHeight * 0.35)
      color: Commons.Color.accent
      font.family: "JetBrains Mono"
      font.pixelSize: Math.round(panel.width * 0.12)
      font.weight: Font.ExtraLight
      font.letterSpacing: -Math.round(panel.width * 0.002)
    }

    Item {
      id: field
      width: panel.fieldWidth
      height: panel.fieldHeight
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.horizontalCenterOffset: root.shakeOffset
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: Math.round((clock.height + clock.anchors.bottomMargin) / 2)

      // Fingerprint mode: just the sensor glyph where the stars would be.
      Text {
        anchors.centerIn: parent
        visible: root.fingerprintMode
        text: "󰈷"
        color: root.errorFlash ? Commons.Color.lock.textError : Commons.Color.accent
        font.family: root.fontFamily
        font.pixelSize: Math.round(panel.fieldHeight * 0.6)
      }

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        visible: !root.fingerprintMode
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        echoMode: root.responseVisible ? TextInput.Normal : TextInput.Password
        passwordCharacter: "✱"  // ✱ heavy asterisk, as on the lock screen
        passwordMaskDelay: 0
        color: Commons.Color.accent
        selectionColor: Commons.Color.lock.selection
        selectedTextColor: Commons.Color.lock.text
        font.family: Style.font.family
        font.pixelSize: panel.starSize
        font.letterSpacing: text.length > 0 ? panel.starSpacing : 0
        cursorVisible: false
        cursorDelegate: Item {}
        readOnly: root.submitted || root.errorFlash
        enabled: root.dialogVisible
        onAccepted: root.submitResponse()
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequest()
            event.accepted = true
          } else if (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U) {
            text = ""
            event.accepted = true
          }
        }
      }

      // Like the lock screen: nothing while empty, only "Checking…" / the error.
      Text {
        textFormat: Text.PlainText
        anchors.fill: parent
        visible: passwordInput.text.length === 0 && (root.submitted || root.errorFlash)
        text: root.errorFlash ? I18n.t("polkit.wrong") : I18n.t("polkit.checking")
        color: root.errorFlash ? Commons.Color.lock.textError : Commons.Color.lock.text
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 1.125)
        font.italic: root.errorFlash
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }
    }

    // What is asking for the password (kept so you never authorise blind).
    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: field.bottom
      anchors.topMargin: Math.round(panel.fieldHeight * 0.4)
      width: Math.min(implicitWidth, panel.width * 0.6)
      text: root.authorizationLabel(root.currentMessage)
      color: Commons.Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideMiddle
    }
  }
}
