import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Panel: Big 3 + today's tasks in five views (To-Do, Progress, Stand By,
// Done, Notes), a Later list, day progress, and a 14-day strip. Every
// mutation is delegated to the Rust backend, which returns the new state.
Item {
  id: root

  property var anchorItem: null
  property var host: null
  property var bar: null
  property var settings: null
  property string binPath: ""
  property bool opened: false

  property string activeTab: "todo"
  property var allTasks: []
  property var allNotes: []
  property var laterList: []
  property var dayStats: ({})
  property var historyList: []
  property var monthCells: []
  property int streakDays: 0
  property string todayKey: ""
  property int dataVersion: 0
  property double nowMs: Date.now()
  property string editingId: ""
  property bool big3Mode: false
  property bool laterOpen: false
  property var pendingArgs: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color bg: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool isLightMode: (bg.r * 0.299 + bg.g * 0.587 + bg.b * 0.114) > 0.5
  readonly property color cardBackground: isLightMode ? "#FFFFFF" : Util.alpha(foreground, 0.05)
  readonly property bool hasRunningTask: {
    var _ = dataVersion
    for (var i = 0; i < allTasks.length; i++) if (allTasks[i].timer && allTasks[i].timer.isRunning) return true
    return false
  }

  function open() {
    opened = true
    nowMs = Date.now()
    editingId = ""
    run(["state"])
    Qt.callLater(function() { if (itemInput) itemInput.forceActiveFocus() })
  }
  function openForCapture() { open() }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function applyState(state) {
    if (!state || typeof state !== "object") return
    // Mantém a barra (e a animação do Pip) em dia sem esperar o próximo poll.
    if (host && host.backendState !== undefined) host.backendState = state
    allTasks = state.tasks || []
    allNotes = state.notes || []
    laterList = state.later || []
    dayStats = state.stats || ({})
    historyList = state.history || []
    monthCells = state.month || []
    streakDays = state.streak || 0
    todayKey = state.todayKey || ""
    dataVersion++
    nowMs = Date.now()
  }

  function run(args) {
    if (!binPath) return
    if (backendProc.running) { pendingArgs = args; return }
    backendProc.command = [binPath].concat(args)
    backendProc.running = true
  }

  // -- task helpers ---------------------------------------------------------
  function liveSeconds(t) {
    if (!t) return 0
    var total = t.timeSpentSeconds || 0
    if (t.timer && t.timer.isRunning && t.timer.lastStartedAt)
      total += Math.max(0, Math.floor(nowMs / 1000) - t.timer.lastStartedAt)
    return total
  }
  function fmtClock(sec) {
    var s = Math.max(0, Math.floor(sec)), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
    var pad = function(n) { return (n < 10 ? "0" : "") + n }
    return h > 0 ? pad(h) + ":" + pad(m) + ":" + pad(r) : pad(m) + ":" + pad(r)
  }
  function fmtHuman(sec) {
    var s = Math.max(0, Math.floor(sec || 0))
    if (s <= 0) return "0s"
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
    if (h > 0) return h + "h" + (m > 0 ? " " + m + "m" : "")
    if (m > 0) return m + "m" + (r > 0 ? " " + r + "s" : "")
    return r + "s"
  }
  // Cor do quadradinho do mês: mais tarefas concluídas, mais escuro.
  function monthCellColor(cell) {
    if (!cell || !(cell.total > 0)) return Util.alpha(foreground, 0.08)
    if (!(cell.done > 0)) return Util.alpha(foreground, 0.14)
    var alphas = [0.30, 0.52, 0.76, 1.0]
    return Util.alpha(Color.accent, alphas[Math.max(0, Math.min(3, (cell.level || 1) - 1))])
  }

  function moveItemToTab(itemObj, isNote, targetTab) {
    if (!itemObj) return
    var id = itemObj.id
    if (isNote) {
      if (targetTab === "notes") return
      root.run(["note-to-task", id])
      if (targetTab === "in_progress") root.run(["start", id])
      else if (targetTab === "standby") root.run(["set-status", id, "standby"])
      else if (targetTab === "done") root.run(["complete", id])
      else if (targetTab === "todo") root.run(["set-status", id, "todo"])
    } else {
      if (targetTab === "notes") {
        root.run(["task-to-note", id])
      } else {
        if (targetTab === "in_progress") root.run(["start", id])
        else if (targetTab === "standby") root.run(["set-status", id, "standby"])
        else if (targetTab === "done") root.run(["complete", id])
        else if (targetTab === "todo") root.run(["set-status", id, "todo"])
      }
    }
  }
  function countFor(tab) {
    var _ = dataVersion
    if (tab === "notes") return allNotes.length
    return allTasks.filter(function(t) { return t.status === tab }).length
  }
  readonly property var currentItems: {
    var _ = dataVersion
    if (activeTab === "notes") return allNotes
    return allTasks.filter(function(t) { return t.status === activeTab })
  }
  readonly property real dayFraction: {
    var start = settings && settings.dayStart !== undefined ? Number(settings.dayStart) : 8
    var end = settings && settings.dayEnd !== undefined ? Number(settings.dayEnd) : 22
    if (end <= start) end = start + 1
    var d = new Date(nowMs)
    return Math.max(0, Math.min(1, ((d.getHours() + d.getMinutes() / 60) - start) / (end - start)))
  }

  Process {
    id: backendProc
    stdout: StdioCollector { id: backendOut }
    onExited: function(code) {
      if (code === 0) {
        try { root.applyState(JSON.parse(backendOut.text)) } catch (e) {}
      }
      if (root.pendingArgs) {
        var next = root.pendingArgs
        root.pendingArgs = null
        root.run(next)
      }
    }
  }
  Process { id: copyProc }

  Timer {
    interval: 500
    running: root.opened || root.hasRunningTask
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.run(["state"])
  }

  Component.onCompleted: run(["state"])

  KeyboardPanel {
    id: popupPanel
    anchorItem: root.anchorItem
    owner: root.host || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popupPanel.fittedContentWidth(Style.space(500))
    contentHeight: popupPanel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: column.width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar {
          policy: QQC.ScrollBar.AsNeeded
          width: Style.space(8)
        }

        Column {
          id: column
          // Calha à direita para a barra de rolagem não cobrir os ícones.
          width: panelFlick.width - Style.space(14)
          spacing: Style.space(10)

          // ---------- Hero: date, count, day progress ----------
          RowLayout {
            width: parent.width
            spacing: Style.space(10)
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)
              Text {
                text: {
                  var _ = root.dataVersion
                  var d = new Date()
                  return d.toLocaleDateString(Qt.locale("pt_BR"), "dddd, d 'de' MMMM")
                }
                color: root.foreground
                font.family: root.fontFamily
                font.bold: true
                font.pixelSize: Style.font.subtitle
              }
              Text {
                text: {
                  var _ = root.dataVersion
                  var s = root.dayStats
                  var parts = [(s.done || 0) + "/" + (s.total || 0) + " concluídas"]
                  if (s.big3Total) parts.push("Big 3: " + (s.big3Done || 0) + "/" + s.big3Total)
                  if (root.streakDays > 0) parts.push("sequência de " + root.streakDays + "d")
                  return parts.join(" · ")
                }
                color: Util.alpha(root.foreground, 0.65)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
            Text {
              visible: root.hasRunningTask
              text: "▶ rodando"
              color: Color.accent
              font.family: root.fontFamily
              font.bold: true
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Day progress: fill = done ratio, tick = where the clock is.
          Rectangle {
            width: parent.width
            height: Style.space(8)
            radius: Style.space(4)
            color: Util.alpha(root.foreground, 0.12)
            Rectangle {
              height: parent.height
              radius: parent.radius
              width: parent.width * Math.max(0, Math.min(1, (root.dayStats.ratio || 0)))
              color: Color.accent
              Behavior on width { NumberAnimation { duration: 250 } }
            }
            Rectangle {
              width: 2
              height: parent.height + 4
              y: -2
              x: parent.width * root.dayFraction - 1
              color: root.foreground
            }
          }

          // ---------- Tabs ----------
          Row {
            id: tabRow
            width: parent.width
            spacing: Style.space(4)
            readonly property var tabDefs: [
              { id: "todo", name: "A Fazer" },
              { id: "in_progress", name: "Andamento" },
              { id: "standby", name: "Em Espera" },
              { id: "done", name: "Concluídas" },
              { id: "notes", name: "Aprovação" }
            ]
            readonly property real cellWidth: (width - spacing * (tabDefs.length - 1)) / tabDefs.length
            Repeater {
              model: tabRow.tabDefs
              Button {
                required property var modelData
                width: tabRow.cellWidth
                text: modelData.name + " (" + root.countFor(modelData.id) + ")"
                selected: modelData.id === root.activeTab
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(4)
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.activeTab = modelData.id
              }
            }
          }

          // ---------- Quick add ----------
          Rectangle {
            width: parent.width
            implicitHeight: Style.space(40)
            radius: Style.cornerRadius
            color: "transparent"
            border.color: itemInput.activeFocus ? Color.accent : Util.alpha(root.foreground, 0.15)
            border.width: itemInput.activeFocus ? 1.5 : 1
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(6)
              Text {
                text: "+"
                color: itemInput.activeFocus ? Color.accent : Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily
                font.bold: true
                font.pixelSize: Style.font.subtitle
              }
              QQC.TextField {
                id: itemInput
                Layout.fillWidth: true
                placeholderText: root.activeTab === "notes" ? "Adicionar enviado para aprovação..." : (root.big3Mode ? "Adicionar tarefa do Big 3..." : "Adicionar nova tarefa...")
                placeholderTextColor: Util.alpha(root.foreground, 0.4)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                background: null
                onAccepted: {
                  var t = text
                  text = ""
                  if (!t || !t.trim()) return
                  if (root.activeTab === "notes") root.run(["add-note", t])
                  else if (root.big3Mode) root.run(["add", t, "--big3"])
                  else root.run(["add", t])
                  if (root.activeTab !== "notes" && root.activeTab !== "todo") root.activeTab = "todo"
                }
                Keys.onEscapePressed: root.close()
              }
              // Big 3 toggle for the next added task.
              Rectangle {
                visible: root.activeTab !== "notes"
                width: Style.space(28); height: Style.space(26); radius: Style.space(5)
                color: root.big3Mode ? Util.alpha(Color.accent, 0.18) : "transparent"
                border.color: root.big3Mode ? Color.accent : Util.alpha(root.foreground, 0.2)
                border.width: 1
                Text { anchors.centerIn: parent; text: "★"; color: root.big3Mode ? Color.accent : root.foreground; font.pixelSize: Style.font.bodySmall }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.big3Mode = !root.big3Mode }
              }
              // Add straight to Later.
              Rectangle {
                visible: root.activeTab !== "notes"
                width: Style.space(28); height: Style.space(26); radius: Style.space(5)
                color: "transparent"
                border.color: Util.alpha(root.foreground, 0.2); border.width: 1
                Text { anchors.centerIn: parent; text: "🕐"; font.pixelSize: Style.font.bodySmall }
                MouseArea {
                  anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var t = itemInput.text
                    if (t && t.trim()) { itemInput.text = ""; root.run(["add-later", t]); root.laterOpen = true }
                  }
                }
              }
            }
          }

          // Clear done (only on Done tab)
          Text {
            visible: root.activeTab === "done" && root.currentItems.length > 0
            text: "limpar todas as concluídas"
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.run(["clear-done"]) }
          }

          // ---------- Empty state ----------
          Text {
            visible: root.currentItems.length === 0
            width: parent.width
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
            text: root.activeTab === "notes" ? "Nenhum item enviado para aprovação ainda.\nDigite acima para adicionar um."
              : root.activeTab === "standby" ? "Nada em espera.\nPause uma tarefa em andamento e ela vem para cá."
              : "Nenhuma tarefa aqui.\nDigite acima para adicionar uma."
            color: Util.alpha(root.foreground, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Cards ----------
          Repeater {
            model: root.currentItems
            Rectangle {
              id: card
              required property var modelData
              required property int index
              width: column.width
              implicitHeight: Math.max(Style.space(42), cardRow.implicitHeight + Style.space(12))
              height: implicitHeight
              radius: Style.cornerRadius
              property var itemObj: modelData
              property bool isNote: root.activeTab === "notes"
              property bool isRunning: !isNote && itemObj.timer && itemObj.timer.isRunning === true
              property bool isEditing: root.editingId === (itemObj ? itemObj.id : "")
              property bool hovered: cardHover.hovered

              function commitEdit() {
                var t = editField.text, id = itemObj.id, note = card.isNote
                root.editingId = ""
                if (t && t.trim()) root.run([note ? "note-edit" : "rename", id, t])
              }
              color: isRunning ? Util.alpha(Color.accent, 0.08) : root.cardBackground
              border.color: isRunning ? Color.accent : (hovered ? Util.alpha(root.foreground, 0.25) : Util.alpha(root.foreground, 0.12))
              border.width: 1
              HoverHandler { id: cardHover }

              RowLayout {
                id: cardRow
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.topMargin: Style.space(6)
                anchors.bottomMargin: Style.space(6)
                spacing: Style.space(6)

                // Play / pause / reopen
                Rectangle {
                  visible: !card.isNote
                  width: Style.space(26); height: Style.space(26); radius: Style.space(6)
                  Layout.alignment: Qt.AlignVCenter
                  color: playMouse.containsMouse ? Util.alpha(Color.accent, 0.15) : "transparent"
                  border.color: card.isRunning ? Color.accent : Util.alpha(root.foreground, 0.2)
                  border.width: 1
                  Text {
                    anchors.centerIn: parent
                    text: itemObj.status === "done" ? "↺" : (card.isRunning ? "⏸" : "▶")
                    color: card.isRunning ? Color.accent : root.foreground
                    font.family: root.fontFamily; font.bold: true; font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: playMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (itemObj.status === "done") root.run(["set-status", itemObj.id, "todo"])
                      else if (card.isRunning) root.run(["pause", itemObj.id])
                      else root.run(["start", itemObj.id])
                    }
                  }
                }

                // Big 3 star
                Text {
                  visible: !card.isNote && itemObj.big3
                  text: "★"; color: Color.accent; font.pixelSize: Style.font.bodySmall
                  Layout.alignment: Qt.AlignVCenter
                }

                Text {
                  visible: !card.isEditing
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  wrapMode: Text.Wrap
                  text: card.isNote ? (itemObj.text || "") : (itemObj.text || itemObj.title || "")
                  textFormat: card.isNote ? Text.MarkdownText : Text.PlainText
                  color: itemObj.status === "done" ? Util.alpha(root.foreground, 0.55) : root.foreground
                  font.family: root.fontFamily; font.bold: !card.isNote; font.pixelSize: Style.font.body
                }
                QQC.TextField {
                  id: editField
                  visible: card.isEditing
                  Layout.fillWidth: true
                  text: card.isNote ? (itemObj.text || "") : (itemObj.text || "")
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                  background: Rectangle { color: "transparent"; radius: 4; border.color: Color.accent; border.width: 1.5 }
                  onVisibleChanged: if (visible) { forceActiveFocus(); selectAll() }
                  onAccepted: card.commitEdit()
                  Keys.onEscapePressed: root.editingId = ""
                }

                // Confirmar edição (mesmo caminho do Enter)
                Rectangle {
                  visible: card.isEditing
                  width: Style.space(28); height: Style.space(26); radius: Style.space(5)
                  Layout.alignment: Qt.AlignVCenter
                  color: confirmMouse.containsMouse ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.accent, 0.12)
                  border.color: Color.accent; border.width: 1.5
                  Text {
                    anchors.centerIn: parent; text: "✓"
                    color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
                  }
                  MouseArea {
                    id: confirmMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: card.commitEdit()
                  }
                  PanelToolTip {
                    visible: confirmMouse.containsMouse
                    text: "Confirmar edição"
                    fontFamily: root.fontFamily
                  }
                }

                // Cancelar edição
                Rectangle {
                  visible: card.isEditing
                  width: Style.space(28); height: Style.space(26); radius: Style.space(5)
                  Layout.alignment: Qt.AlignVCenter
                  color: cancelMouse.containsMouse ? Util.alpha(Color.urgent, 0.18) : "transparent"
                  border.color: cancelMouse.containsMouse ? Color.urgent : Util.alpha(root.foreground, 0.25); border.width: 1
                  Text {
                    anchors.centerIn: parent; text: "✕"
                    color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
                  }
                  MouseArea {
                    id: cancelMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: root.editingId = ""
                  }
                  PanelToolTip {
                    visible: cancelMouse.containsMouse
                    text: "Cancelar edição"
                    fontFamily: root.fontFamily
                  }
                }

                // Time / status badge
                Rectangle {
                  visible: !card.isNote && !card.isEditing
                  height: Style.space(20); radius: Style.space(4)
                  Layout.preferredWidth: badgeText.implicitWidth + Style.space(10)
                  Layout.alignment: Qt.AlignVCenter
                  color: card.isRunning ? Util.alpha(Color.accent, 0.1) : "transparent"
                  border.color: card.isRunning ? Util.alpha(Color.accent, 0.45) : Util.alpha(root.foreground, 0.15)
                  border.width: 1
                  Text {
                    id: badgeText; anchors.centerIn: parent
                    text: {
                      var _ = root.nowMs
                      if (itemObj.status === "in_progress") return (card.isRunning ? "▶ " : "⏸ ") + root.fmtClock(root.liveSeconds(itemObj))
                      if (itemObj.status === "standby") return "⏸ " + root.fmtHuman(root.liveSeconds(itemObj))
                      if (itemObj.status === "done") return "✓ " + root.fmtHuman(itemObj.timeSpentSeconds || 0)
                      if (itemObj.carries > 0) return "↻" + itemObj.carries
                      return ""
                    }
                    visible: text !== ""
                    color: card.isRunning ? Color.accent : Util.alpha(root.foreground, 0.7)
                    font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: card.isRunning
                  }
                }

                // Hover actions: complete, stand-by, star, defer, edit/copy, delete
                Row {
                  visible: card.hovered && !card.isEditing
                  spacing: Style.space(2)
                  Layout.alignment: Qt.AlignVCenter
                  Repeater {
                    model: {
                      var acts = []
                      if (card.isNote) {
                        // Está em Aprovação -> pode mover para A Fazer, Andamento, Em Espera, Concluídas
                        acts.push({ a: "mov-todo", t: "📋", tip: "Mover para A Fazer" })
                        acts.push({ a: "mov-in_progress", t: "▶", tip: "Iniciar (Andamento)" })
                        acts.push({ a: "mov-standby", t: "⏸", tip: "Mover para Em Espera" })
                        acts.push({ a: "mov-done", t: "✓", tip: "Mover para Concluídas" })
                        acts.push({ a: "sep" })
                        acts.push({ a: "copy", t: "⧉", tip: "Copiar texto" })
                        acts.push({ a: "toggle", t: itemObj.done ? "↺" : "✔", tip: itemObj.done ? "Reabrir item" : "Marcar resolvido" })
                        acts.push({ a: "edit", t: "✎", tip: "Editar" })
                        acts.push({ a: "delete", t: "✕", tip: "Apagar" })
                        return acts
                      }

                      // Está em Tarefas (A Fazer / Andamento / Em Espera / Concluídas)
                      // Destinos disponíveis exceto o estado atual:
                      if (itemObj.status !== "todo") acts.push({ a: "mov-todo", t: "📋", tip: "Mover para A Fazer" })
                      if (itemObj.status !== "in_progress") acts.push({ a: "mov-in_progress", t: "▶", tip: "Mover para Andamento (iniciar timer)" })
                      if (itemObj.status !== "standby") acts.push({ a: "mov-standby", t: "⏸", tip: "Mover para Em Espera" })
                      if (itemObj.status !== "done") acts.push({ a: "mov-done", t: "✓", tip: "Concluir tarefa" })
                      acts.push({ a: "mov-approval", t: "⏳", tip: "Mover para Aprovação" })

                      acts.push({ a: "sep" })

                      // Big 3 e Para Depois
                      if (itemObj.status !== "done") acts.push({ a: "star", t: itemObj.big3 ? "★" : "☆", tip: itemObj.big3 ? "Remover do Big 3" : "Tornar Big 3" })
                      if (itemObj.status !== "done") acts.push({ a: "defer", t: "↓", tip: "Mover Para Depois" })
                      acts.push({ a: "edit", t: "✎", tip: "Editar texto" })
                      acts.push({ a: "delete", t: "✕", tip: "Apagar tarefa" })
                      return acts
                    }
                    Rectangle {
                      required property var modelData
                      visible: modelData.a !== "sep"
                      width: Style.space(22); height: Style.space(22); radius: Style.space(4)
                      color: actMouse.containsMouse ? Util.alpha(root.foreground, 0.14) : "transparent"
                      Text {
                        anchors.centerIn: parent; text: modelData.t || ""
                        color: modelData.a === "delete" ? Color.urgent : (modelData.a && modelData.a.indexOf("mov-") === 0 ? Color.accent : root.foreground)
                        font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
                      }
                      MouseArea {
                        id: actMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          var id = itemObj.id, a = modelData.a
                          if (a === "mov-todo") root.moveItemToTab(itemObj, card.isNote, "todo")
                          else if (a === "mov-in_progress") root.moveItemToTab(itemObj, card.isNote, "in_progress")
                          else if (a === "mov-standby") root.moveItemToTab(itemObj, card.isNote, "standby")
                          else if (a === "mov-done") root.moveItemToTab(itemObj, card.isNote, "done")
                          else if (a === "mov-approval") root.moveItemToTab(itemObj, false, "notes")
                          else if (a === "star") root.run(["toggle-big3", id])
                          else if (a === "defer") root.run(["defer", id])
                          else if (a === "edit") root.editingId = id
                          else if (a === "delete") root.run([card.isNote ? "note-delete" : "delete", id])
                          else if (a === "toggle") root.run(["note-toggle", id])
                          else if (a === "copy") { copyProc.command = [root.binPath, "copy", itemObj.text || ""]; copyProc.running = true }
                        }
                      }
                      PanelToolTip {
                        visible: actMouse.containsMouse && modelData.tip !== undefined
                        text: modelData.tip || ""
                        fontFamily: root.fontFamily
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------- Later ----------
          Rectangle {
            width: parent.width
            height: Style.space(30)
            radius: Style.cornerRadius
            color: Util.alpha(root.foreground, 0.04)
            border.color: Util.alpha(root.foreground, 0.1); border.width: 1
            Text {
              anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
              text: (root.laterOpen ? "▾ " : "▸ ") + "PARA DEPOIS · " + root.laterList.length
              color: Util.alpha(root.foreground, 0.75); font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.laterOpen = !root.laterOpen }
          }
          Repeater {
            model: root.laterOpen ? root.laterList : []
            Rectangle {
              required property var modelData
              width: column.width; height: Style.space(36); radius: Style.cornerRadius
              color: root.cardBackground; border.color: Util.alpha(root.foreground, 0.1); border.width: 1
              RowLayout {
                anchors.fill: parent; anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(6); spacing: Style.space(6)
                Text {
                  Layout.fillWidth: true; text: modelData.text; color: root.foreground
                  font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight
                }
                Text {
                  text: "📋 hoje"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.run(["pull-later", modelData.id]) }
                }
                Text {
                  text: "⏳"; color: Util.alpha(root.foreground, 0.75); font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                  MouseArea {
                    id: laterApproveMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.run(["pull-later", modelData.id])
                      root.run(["task-to-note", modelData.id])
                      root.activeTab = "notes"
                    }
                  }
                  PanelToolTip {
                    visible: laterApproveMouse.containsMouse
                    text: "Mover direto para Aprovação"
                    fontFamily: root.fontFamily
                  }
                }
                Text {
                  text: "✕"; color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.run(["delete", modelData.id]) }
                }
              }
            }
          }

          // ---------- Mês: um quadradinho por dia, escurece ao concluir ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: {
                  var d = new Date()
                  var m = d.toLocaleDateString(Qt.locale("pt_BR"), "MMMM yyyy")
                  return m.charAt(0).toUpperCase() + m.slice(1)
                }
                color: Util.alpha(root.foreground, 0.75)
                font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
              }
              Item { Layout.fillWidth: true }
              Text {
                text: "menos"
                color: Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
              }
              Row {
                spacing: Style.space(2)
                Repeater {
                  model: [0.14, 0.30, 0.52, 0.76, 1.0]
                  Rectangle {
                    required property var modelData
                    width: Style.space(10); height: Style.space(10); radius: 2
                    color: Util.alpha(Color.accent, modelData)
                  }
                }
              }
              Text {
                text: "mais"
                color: Util.alpha(root.foreground, 0.5)
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
              }
            }
            Grid {
              width: parent.width
              spacing: Style.space(3)
              columns: Math.ceil(root.monthCells.length / 2)
              Repeater {
                model: root.monthCells
                Rectangle {
                  required property var modelData
                  width: Math.max(Style.space(10), (column.width - Style.space(3) * (parent.columns - 1)) / Math.max(1, parent.columns))
                  height: Style.space(26)
                  radius: Style.space(3)
                  color: root.monthCellColor(modelData)
                  border.width: modelData.today ? 1.5 : 0
                  border.color: root.foreground
                  Text {
                    anchors.centerIn: parent
                    text: String(modelData.day)
                    color: (modelData.level || 0) >= 3 ? Color.popups.background : Util.alpha(root.foreground, modelData.today ? 1 : 0.65)
                    font.family: root.fontFamily; font.pixelSize: 8; font.bold: modelData.today
                  }
                  MouseArea {
                    id: cellHover
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                  }
                  PanelToolTip {
                    visible: cellHover.containsMouse
                    text: modelData.total > 0
                      ? modelData.day + " · " + modelData.done + "/" + modelData.total + " concluídas"
                      : modelData.day + " · sem tarefas"
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
