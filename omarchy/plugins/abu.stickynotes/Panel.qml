// Sticky notes bar button + panel. Clicking the icon opens a panel holding
// every note as a colored card you can type into; notes never go on the desktop.
// Middle click: open with a new note. Shortcut: SUPER+M opens/closes.
// IPC: omarchy-shell stickynotes toggle | open | all | add
//
// Each bar (one per monitor) has its own copy of this widget. They share
// notes through ~/.local/share/abu-stickynotes/notes.json and reload when
// another copy writes it.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import qs.Commons as Commons

BarWidget {
  id: root
  moduleName: "abu.stickynotes"

  property bool popupOpen: false
  property bool showAll: false          // "View all" expanded panel
  readonly property int compactLimit: 6
  readonly property int boardCols: showAll ? 6 : 4
  readonly property var board: computeBoard(store.rev, boardCols, showAll)

  // Bento packing: place each note (in order) at the first free spot that
  // fits its span. Returns a cell rect per note (null = not shown) + row count.
  function computeBoard(_rev, cols, all) {
    var occ = [], rects = [], rows = 0
    function free(r, c, w, h) {
      for (var y = r; y < r + h; y++)
        for (var x = c; x < c + w; x++) if (occ[y] && occ[y][x]) return false
      return true
    }
    for (var i = 0; i < notesModel.count; i++) {
      if (!all && i >= compactLimit) { rects.push(null); continue }
      var sp = store.spanOf(store.sizeAt(i)), w = Math.min(sp[0], cols), h = sp[1], done = false
      for (var r = 0; !done; r++) {
        for (var c = 0; c <= cols - w; c++) {
          if (!free(r, c, w, h)) continue
          for (var y = r; y < r + h; y++) { occ[y] = occ[y] || []; for (var x = c; x < c + w; x++) occ[y][x] = true }
          rects.push({ c: c, r: r, w: w, h: h })
          rows = Math.max(rows, r + h)
          done = true
          break
        }
      }
    }
    return { rects: rects, rows: rows }
  }
  onPopupOpenChanged: if (!popupOpen) showAll = false
  readonly property var svc: store
  readonly property int count: notesModel.count

  // Panel colors follow the theme (red/black).
  readonly property color fg: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color subtle: Qt.rgba(fg.r, fg.g, fg.b, 0.55)
  readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color raised: Qt.rgba(fg.r, fg.g, fg.b, 0.05)
  readonly property string uiFont: Style.font.family
  readonly property string noteFont: "sans-serif"

  function close() { popupOpen = false }
  function open() { popupOpen = true }
  function onFocusedScreen() {
    var w = root.QsWindow.window
    var m = Hyprland.focusedMonitor
    return !!(w && w.screen && m && w.screen.name === m.name)
  }
  // The copy of this widget on the focused monitor (falls back to this one).
  function focusedPeer() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].onFocusedScreen && items[i].onFocusedScreen()) return items[i]
    return root
  }
  function stamp(ms) {
    if (!ms) return ""
    var d = new Date(ms), now = new Date()
    if (d.toDateString() === now.toDateString()) return Qt.formatTime(d, "HH:mm")
    var y = new Date(now); y.setDate(now.getDate() - 1)
    if (d.toDateString() === y.toDateString()) return "Yesterday"
    return Qt.formatDate(d, d.getFullYear() === now.getFullYear() ? "d MMM" : "d MMM yyyy")
  }

  // Only one copy's handler is active; it forwards to the focused monitor's copy.
  IpcHandler {
    target: "stickynotes"
    function toggle(): void { var p = root.focusedPeer(); p.popupOpen = !p.popupOpen }
    function open(): void { root.focusedPeer().open() }
    function all(): void { var p = root.focusedPeer(); p.open(); p.showAll = true }
    function add(): void { var p = root.focusedPeer(); p.svc.addNote(); p.open() }
  }

  ListModel { id: notesModel }

  // ── Notes store ────────────────────────────────────────────────────
  QtObject {
    id: store

    // The common sticky-note colors (Post-it / Windows Sticky Notes).
    readonly property var palette: [
      { key: "yellow",   name: "Yellow",   color: "#fff176" },
      { key: "pink",     name: "Pink",     color: "#ffa6c9" },
      { key: "blue",     name: "Blue",     color: "#a5d8ff" },
      { key: "green",    name: "Green",    color: "#b9f2a8" },
      { key: "orange",   name: "Orange",   color: "#ffc285" },
      { key: "purple",   name: "Purple",   color: "#d8bfff" },
      { key: "gray",     name: "Gray",     color: "#e4e4e4" },
      { key: "charcoal", name: "Charcoal", color: "#3b3b3b" }
    ]
    readonly property var notes: notesModel
    readonly property string dataDir: Quickshell.env("HOME") + "/.local/share/abu-stickynotes"
    property bool loaded: false
    property string lastAddedId: ""
    property string lastColor: "yellow"
    property string lastWritten: ""
    property int rev: 0          // bumps on every change; drives the bento layout

    readonly property string paper: "#fff176"   // every note is classic yellow
    readonly property var sizeCycle: ["s", "w", "t", "l"]   // small, wide, tall, large
    function spanOf(sz) { return sz === "l" ? [2, 2] : sz === "w" ? [2, 1] : sz === "t" ? [1, 2] : [1, 1] }
    // A note's size: the one picked with the resize button, else from its text.
    function sizeAt(i) {
      var n = notesModel.get(i)
      if (n.size) return n.size
      var t = n.text || "", lines = t.split("\n").length
      if (t.length > 140 || lines >= 9) return "l"
      if (lines >= 5) return "t"
      if (t.length > 70) return "w"
      return "s"
    }
    function cycleSize(id) {
      var i = indexOf(id)
      if (i < 0) return
      var cur = sizeCycle.indexOf(sizeAt(i))
      notesModel.setProperty(i, "size", sizeCycle[(cur + 1) % sizeCycle.length])
      rev++
      save()
    }

    function colorFor(key) {
      for (var i = 0; i < palette.length; i++) if (palette[i].key === key) return palette[i].color
      return palette[0].color
    }
    function isDark(key) { return key === "charcoal" }
    function indexOf(id) {
      for (var i = 0; i < notesModel.count; i++) if (notesModel.get(i).noteId === id) return i
      return -1
    }
    function addNote(colorKey) {   // newest first
      var id = String(Date.now()) + Math.floor(Math.random() * 1000)
      lastAddedId = id   // set first: the new card checks it as it is created, then takes the cursor
      notesModel.insert(pinnedCount(), { noteId: id, colorKey: "yellow", text: "", updated: Date.now(), pinned: false, size: "l" })   // new notes start large
      rev++
      save()
      return id
    }
    function pinnedCount() {
      var n = 0
      for (var i = 0; i < notesModel.count; i++) if (notesModel.get(i).pinned) n++
      return n
    }
    // Pinned notes sit at the top; unpinning drops a note just below them.
    function togglePin(id) {
      var i = indexOf(id)
      if (i < 0) return
      var pin = !notesModel.get(i).pinned
      notesModel.setProperty(i, "pinned", pin)
      notesModel.move(i, pin ? 0 : pinnedCount(), 1)
      rev++
      save()
    }
    function deleteNote(id) {
      var i = indexOf(id)
      if (i < 0) return
      notesModel.remove(i)
      rev++
      save()
    }
    function update(id, props) {
      var i = indexOf(id)
      if (i < 0) return
      for (var k in props) notesModel.setProperty(i, k, props[k])
      notesModel.setProperty(i, "updated", Date.now())
      rev++
      saveTimer.restart()
    }
    function serialize() {
      var list = []
      for (var i = 0; i < notesModel.count; i++) {
        var n = notesModel.get(i)
        list.push({ id: n.noteId, color: n.colorKey, text: n.text, updated: n.updated, pinned: n.pinned, size: n.size })
      }
      return JSON.stringify({ version: 2, lastColor: lastColor, notes: list }, null, 2) + "\n"
    }
    function save() {
      saveTimer.stop()
      if (!loaded) return
      lastWritten = serialize()
      dataFile.setText(lastWritten)
    }
    function load(raw) {
      if (raw === lastWritten) { loaded = true; return }   // our own write coming back
      lastWritten = raw
      notesModel.clear()
      try {
        var data = JSON.parse(raw)
        if (data.lastColor) lastColor = String(data.lastColor)
        var list = data.notes || []
        for (var i = 0; i < list.length; i++)
          notesModel.append({
            noteId: String(list[i].id), colorKey: String(list[i].color || "yellow"),
            text: String(list[i].text || ""), updated: Number(list[i].updated) || 0,
            pinned: list[i].pinned === true,
            size: ["s", "w", "t", "l"].indexOf(list[i].size) >= 0 ? list[i].size : ""
          })
      } catch (e) {
        console.warn("abu.stickynotes: could not read notes.json: " + e)
      }
      loaded = true
      rev++
    }
  }

  Timer { id: saveTimer; interval: 400; onTriggered: store.save() }
  Component.onDestruction: if (saveTimer.running) store.save()

  Process {
    running: true
    command: ["mkdir", "-p", store.dataDir]
    onExited: dataFile.reload()
  }

  FileView {
    id: dataFile
    path: store.dataDir + "/notes.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: if (!saveTimer.running) store.load(text())
    onLoadFailed: store.loaded = true
  }

  // ── Bar button ─────────────────────────────────────────────────────
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""   // nf-fa-sticky_note
    active: root.popupOpen
    tooltipText: root.count === 0 ? "Sticky notes (Super+M)"
      : root.count + (root.count === 1 ? " sticky note" : " sticky notes") + " (Super+M)"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) { store.addNote(); root.open() }
      else root.popupOpen = !root.popupOpen
    }
  }

  // ── Panel ──────────────────────────────────────────────────────────
  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.popupOpen
    contentWidth: panel.fittedContentWidth(root.showAll ? Style.space(980) : Style.space(640))
    contentHeight: panel.fittedContentHeight(
      header.height + notesArea.height + footer.height + layout.spacing * 2)

    Column {
      id: layout
      width: parent.width
      spacing: Style.space(14)

      // Panel keys (work wherever the focus is inside the panel)
      Shortcut {
        sequence: "Ctrl+N"
        context: Qt.WindowShortcut
        enabled: root.popupOpen
        onActivated: { store.addNote(); flick.contentY = 0 }
      }
      Shortcut {
        sequence: "Escape"
        context: Qt.WindowShortcut
        enabled: root.popupOpen
        onActivated: root.close()
      }

      // Title row
      Item {
        id: header
        width: parent.width
        height: Style.space(26)

        Row {
          anchors { left: parent.left; verticalCenter: parent.verticalCenter }
          spacing: Style.space(10)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: ""
            color: root.accent
            font.family: root.uiFont
            font.pixelSize: Style.space(17)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Sticky notes"
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.space(15)
            font.weight: Font.DemiBold
          }
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.count > 0
            height: Style.space(18)
            width: Math.max(height, countText.implicitWidth + Style.space(12))
            radius: height / 2
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
            Text {
              id: countText
              anchors.centerIn: parent
              text: root.count
              color: root.accent
              font.family: root.uiFont
              font.pixelSize: Style.space(11)
              font.weight: Font.DemiBold
            }
          }
        }

        Rectangle {
          id: newBtn
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          height: Style.space(28)
          width: height
          radius: Style.space(7)
          color: newMouse.containsMouse ? Qt.lighter(root.accent, 1.15) : root.accent
          Text {
            anchors.centerIn: parent
            text: "+"
            color: "#ffffff"
            font.family: root.noteFont
            font.pixelSize: Style.space(20)
            font.weight: Font.Bold
          }
          MouseArea {
            id: newMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { store.addNote(); flick.contentY = 0 }
          }
        }

        Rectangle {
          id: viewAll
          anchors { right: newBtn.left; rightMargin: Style.space(8); verticalCenter: parent.verticalCenter }
          visible: root.count > root.compactLimit || root.showAll
          height: Style.space(26)
          width: viewAllText.implicitWidth + Style.space(20)
          radius: Style.space(6)
          color: viewAllMouse.containsMouse ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) : root.raised
          border.width: 1
          border.color: viewAllMouse.containsMouse ? root.accent : root.hairline
          Text {
            id: viewAllText
            anchors.centerIn: parent
            text: root.showAll ? "Show less" : "View all (" + root.count + ")"
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.space(12)
          }
          MouseArea {
            id: viewAllMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.showAll = !root.showAll; flick.contentY = 0 }
          }
        }
      }


      // Notes grid (scrolls after three rows)
      Item {
        id: notesArea
        width: parent.width
        // Grows with the board, then scrolls.
        height: root.count === 0 ? Style.space(150)
          : root.showAll ? Math.min(grid.implicitHeight, Style.space(780))
          : Math.min(grid.implicitHeight, Style.space(600))

        Column {
          visible: root.count === 0
          anchors.centerIn: parent
          spacing: Style.space(8)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ""
            color: root.hairline
            font.family: root.uiFont
            font.pixelSize: Style.space(40)
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "No notes yet"
            color: root.fg
            font.family: root.uiFont
            font.pixelSize: Style.space(13)
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Click + to start one"
            color: root.subtle
            font.family: root.uiFont
            font.pixelSize: Style.space(11)
          }
        }

        Flickable {
          id: flick
          anchors.fill: parent
          visible: root.count > 0
          contentWidth: width
          contentHeight: grid.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Item {
            id: grid
            width: flick.width
            readonly property real gap: Style.space(12)
            readonly property real cell: (width - gap * (root.boardCols - 1)) / root.boardCols
            readonly property real rowH: Math.round(cell * 0.82)
            implicitHeight: root.board.rows > 0 ? root.board.rows * rowH + (root.board.rows - 1) * gap : 0
            height: implicitHeight

            Repeater {
              model: notesModel
              delegate: NoteCard {
                readonly property var rect: root.board.rects[index] || null
                visible: rect !== null
                x: rect ? rect.c * (grid.cell + grid.gap) : 0
                y: rect ? rect.r * (grid.rowH + grid.gap) : 0
                width: rect ? rect.w * grid.cell + (rect.w - 1) * grid.gap : 0
                height: rect ? rect.h * grid.rowH + (rect.h - 1) * grid.gap : 0
              }
            }
          }
        }
      }

      // Footer hint
      Text {
        id: footer
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: (!root.showAll && root.count > root.compactLimit
                ? (root.count - root.compactLimit) + " more in View all  ·  " : "")
              + "Ctrl+N new note  ·  Pinned notes stay on top  ·  Esc to close  ·  Super+M"
        color: root.subtle
        opacity: 0.8
        font.family: root.uiFont
        font.pixelSize: Style.space(10)
      }
    }
  }

  // ── One note card ──────────────────────────────────────────────────
  component NoteCard: Item {
    id: card
    required property int index
    required property string noteId
    required property string colorKey
    required property string text
    required property real updated
    required property bool pinned

    property bool confirmDelete: false
    readonly property bool dark: false
    readonly property color ink: dark ? "#f2f2f2" : "#262626"
    readonly property color inkSoft: Qt.rgba(ink.r, ink.g, ink.b, 0.5)
    readonly property color paper: store.paper
    property bool settled: false
    Behavior on x { enabled: card.settled; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on y { enabled: card.settled; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on width { enabled: card.settled; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    Behavior on height { enabled: card.settled; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    readonly property bool hot: cardHover.hovered || body.activeFocus
    readonly property int fold: Style.space(18)

    HoverHandler { id: cardHover }

    Component.onCompleted: {
      body.text = card.text
      Qt.callLater(function() { card.settled = true })
      if (store.lastAddedId === noteId) {
        store.lastAddedId = ""
        Qt.callLater(function() { body.forceActiveFocus() })
      }
    }

    // soft drop shadow
    Rectangle {
      anchors.fill: paperRect
      anchors.topMargin: Style.space(3)
      anchors.leftMargin: Style.space(1)
      anchors.rightMargin: -Style.space(1)
      anchors.bottomMargin: -Style.space(4)
      radius: paperRect.radius
      color: "#000000"
      opacity: body.activeFocus ? 0.6 : card.hot ? 0.45 : 0.3
    }

    // the paper, with its bottom-right corner folded over
    Canvas {
      id: paperRect
      anchors.fill: parent
      property real radius: Style.space(8)
      property color fill: card.paper
      onFillChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var c = getContext("2d"), w = width, h = height, r = radius, f = card.fold
        c.reset()
        c.beginPath()
        c.moveTo(r, 0); c.lineTo(w - r, 0); c.arcTo(w, 0, w, r, r)
        c.lineTo(w, h - f); c.lineTo(w - f, h)
        c.lineTo(r, h); c.arcTo(0, h, 0, h - r, r)
        c.lineTo(0, r); c.arcTo(0, 0, r, 0, r)
        c.closePath()
        c.fillStyle = fill
        c.fill()
        // the fold
        c.beginPath()
        c.moveTo(w, h - f); c.lineTo(w - f, h - f); c.lineTo(w - f, h); c.closePath()
        var k = card.dark ? 1.45 : 0.84
        c.fillStyle = Qt.rgba(Math.min(1, fill.r * k), Math.min(1, fill.g * k), Math.min(1, fill.b * k), 1)
        c.fill()
      }
    }

    // Top controls (show on hover / focus)
    Row {
      id: tools
      anchors { top: parent.top; right: parent.right; topMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(2)
      opacity: card.hot || card.confirmDelete ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }

      CardButton {
        glyph: ""   // pin
        ink: card.ink
        active: card.pinned
        onClicked: store.togglePin(card.noteId)
      }
      CardButton {
        glyph: "\uf065"   // resize: small → wide → tall → large
        ink: card.ink
        onClicked: store.cycleSize(card.noteId)
      }
      CardButton {
        glyph: "\uf1f8"   // trash; turns red, click again to delete
        ink: card.confirmDelete ? "#e53935" : card.ink
        onClicked: {
          if (card.confirmDelete || body.text.trim() === "") store.deleteNote(card.noteId)
          else { card.confirmDelete = true; confirmTimer.restart() }
        }
      }
    }
    Timer { id: confirmTimer; interval: 3000; onTriggered: card.confirmDelete = false }


    // Text
    Flickable {
      id: bodyFlick
      anchors {
        top: parent.top; left: parent.left; right: parent.right; bottom: when.top
        topMargin: Style.space(34); leftMargin: Style.space(14); rightMargin: Style.space(14); bottomMargin: Style.space(4)
      }
      contentWidth: width
      contentHeight: body.contentHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      function ensureVisible(r) {
        if (contentY >= r.y) contentY = r.y
        else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
      }

      TextEdit {
        id: body
        width: bodyFlick.width
        height: Math.max(bodyFlick.height, contentHeight)
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.PlainText
        selectByMouse: true
        color: card.ink
        selectionColor: card.dark ? "#777777" : Qt.darker(card.paper, 1.3)
        selectedTextColor: card.ink
        font.family: root.noteFont
        font.pixelSize: Style.space(14)
        onTextChanged: if (text !== card.text) store.update(card.noteId, { text: text })
        onCursorRectangleChanged: bodyFlick.ensureVisible(cursorRectangle)
        Keys.onEscapePressed: root.close()

        Text {
          visible: body.text === "" && !body.activeFocus
          text: "Write something…"
          color: card.inkSoft
          font: body.font
        }
      }
    }

    // Pinned marker (always visible)
    Text {
      visible: card.pinned
      anchors { left: parent.left; top: parent.top; leftMargin: Style.space(12); topMargin: Style.space(9) }
      text: ""
      color: card.ink
      rotation: -30
      font.family: root.uiFont
      font.pixelSize: Style.space(13)
    }

    // Edited time
    Text {
      id: when
      anchors { left: parent.left; bottom: parent.bottom; leftMargin: Style.space(14); bottomMargin: Style.space(9) }
      text: root.stamp(card.updated)
      color: card.inkSoft
      font.family: root.noteFont
      font.pixelSize: Style.space(10)
    }
  }

  component CardButton: Rectangle {
    id: btn
    property string glyph: ""
    property color ink: "#262626"
    property bool danger: false
    property bool active: false
    signal clicked()
    readonly property bool wide: glyph.length > 1
    height: Style.space(24)
    width: wide ? lbl.implicitWidth + Style.space(14) : height
    radius: Style.space(6)
    color: danger ? "#d32f2f"
         : (hover.containsMouse || active) ? Qt.rgba(ink.r, ink.g, ink.b, 0.14) : "transparent"
    Text {
      id: lbl
      anchors.centerIn: parent
      text: btn.glyph
      color: btn.ink
      font.family: btn.wide ? root.noteFont : root.uiFont
      font.pixelSize: btn.wide ? Style.space(11) : Style.space(13)
      font.weight: btn.wide ? Font.DemiBold : Font.Normal
    }
    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: btn.clicked()
    }
  }
}
