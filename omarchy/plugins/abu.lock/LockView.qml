import QtQuick
import Quickshell
import Quickshell.Io
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  // false on secondary screens: name + password box hidden there, but the
  // field still takes keystrokes (shared with the primary screen's box).
  property bool showInput: true
  // Lock style (dotfiles): big red clock with red stars under it, no box.
  // Set to false for the boxed password field.
  readonly property bool clockStyle: true
  property string clockText: Qt.formatTime(new Date(), "HH:mm")
  property bool loadBackground: true
  // dotfiles: no wallpaper on the lock screen, just black behind the clock.
  readonly property bool showWallpaper: false
  property string passwordText: ""
  property bool syncingPasswordText: false

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.6)  // space between stars
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Commons.Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Commons.Color.lock.borderActive, root.outlineThickness, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "\u2731".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground && root.showWallpaper ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && root.showWallpaper && wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    // Name above the password field, in the Omarchy logo's block-letter style
    // (added in ~/dotfiles). Regenerate the art with:
    //   ~/dotfiles/bin/block-text YOUR NAME > ~/dotfiles/omarchy/plugins/abu.lock/name-art.txt
    FileView {
      id: nameArtFile
      path: Qt.resolvedUrl("name-art.txt")
      watchChanges: true
      onFileChanged: reload()
    }

    readonly property string nameArt: nameArtFile.loaded ? nameArtFile.text().replace(/\n+$/, "") : ""
    readonly property int nameArtColumns: {
      var lines = nameArt.split("\n"), n = 1
      for (var i = 0; i < lines.length; i++) n = Math.max(n, lines[i].length)
      return n
    }

    FontMetrics {
      id: nameArtMetrics
      font.family: Style.font.family
      font.pixelSize: 100
    }

    Text {
      id: lockName
      visible: root.showInput && text.length > 0
      textFormat: Text.PlainText
      text: parent.nameArt
      horizontalAlignment: Text.AlignHCenter
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: inputField.top
      anchors.bottomMargin: Math.round(root.fieldHeight * 0.9)
      color: Commons.Color.accent
      font.family: Style.font.family
      // Fit the art to ~60% of the screen width.
      font.pixelSize: Math.max(4, Math.floor(root.width * 0.6 / (parent.nameArtColumns * nameArtMetrics.averageCharacterWidth / 100)))
      lineHeightMode: Text.FixedHeight
      lineHeight: Math.ceil(font.pixelSize * nameArtMetrics.height / 100)
      wrapMode: Text.NoWrap
    }

    // Big thin red clock (clock style), centred above the stars.
    Timer {
      interval: 1000
      running: root.clockStyle && root.showInput
      repeat: true
      triggeredOnStart: true
      onTriggered: root.clockText = Qt.formatTime(new Date(), "HH:mm")
    }

    Text {
      id: lockClock
      visible: root.clockStyle && root.showInput
      textFormat: Text.PlainText
      text: root.clockText
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: inputField.top
      anchors.bottomMargin: Math.round(root.fieldHeight * 0.35)
      color: Commons.Color.accent
      font.family: "JetBrains Mono"   // ttf-jetbrains-mono: has the thin weights
      font.pixelSize: Math.round(root.width * 0.12)
      font.weight: Font.ExtraLight
      font.letterSpacing: -Math.round(root.width * 0.002)
    }

    BorderSurface {
      id: inputField
      opacity: root.showInput ? 1 : 0
      width: root.fieldWidth
      height: root.fieldHeight
      // Centre the name + password box as one group on screen.
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: (lockName.visible ? Math.round((lockName.height + lockName.anchors.bottomMargin) / 2) : 0)
        + (lockClock.visible ? Math.round((lockClock.height + lockClock.anchors.bottomMargin) / 2) : 0)
      color: root.clockStyle ? "transparent" : Commons.Color.lock.background
      borderSpec: root.clockStyle ? ({ color: "transparent", widths: root.inputBorderSpec.widths, gradient: null }) : root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "\u2731"  // ✱ heavy asterisk
        passwordMaskDelay: 0
        color: root.clockStyle ? Commons.Color.accent : Commons.Color.lock.text
        selectionColor: Commons.Color.lock.selection
        selectedTextColor: Commons.Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Commons.Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…" : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0 && (!root.clockStyle || root.authenticatingPassword || root.failureMessage.length > 0)
        color: root.authenticatingPassword ? Commons.Color.lock.text : (root.failureMessage.length > 0 ? Commons.Color.lock.textError : Commons.Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Commons.Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
