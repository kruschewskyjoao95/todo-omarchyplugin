import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: Pip the mascot, today's done/total, and the live timer when one
// is running. All state comes from the Rust backend (bin/omarchy-daily-tasks).
BarWidget {
  id: root
  moduleName: "kruschewskyjoao95.daily-tasks"

  readonly property int dayStartHour: Math.round(Number(setting("dayStart", 8)))
  readonly property int dayEndHour: Math.round(Number(setting("dayEnd", 22)))
  readonly property bool showCount: setting("showCount", true) === true
  readonly property string binPath: Qt.resolvedUrl("bin/omarchy-daily-tasks").toString().replace("file://", "")

  property var backendState: ({})
  readonly property var stats: backendState.stats || ({ done: 0, total: 0, weightedRatio: 0, allDone: false })
  readonly property string countText: stats.total > 0 ? stats.done + "/" + stats.total : "–"
  readonly property string runningText: backendState.runningText || ""

  // Mood, mirroring Daily Todos' Model.moodFor thresholds.
  readonly property var mood: {
    var now = new Date()
    var start = dayStartHour, end = dayEndHour > dayStartHour ? dayEndHour : dayStartHour + 1
    var frac = Math.max(0, Math.min(1, ((now.getHours() + now.getMinutes() / 60) - start) / (end - start)))
    if (!stats.total) return { label: "Parado", smile: 0.2, eyes: "flat", brow: 0, sweat: 0, sparkle: 0, wavy: false, urgency: 0 }
    if (stats.allDone) return { label: "Tranquilo", smile: 1, eyes: "happy", brow: -0.2, sweat: 0, sparkle: 2, wavy: false, urgency: 0 }
    var deficit = Math.max(0, Math.min(1, frac - (stats.weightedRatio || 0)))
    if (deficit < 0.15) return { label: "De boa", smile: 0.8, eyes: "happy", brow: 0, sweat: 0, sparkle: 0, wavy: false, urgency: 0.1 }
    if (deficit < 0.35) return { label: "Focado", smile: 0.3, eyes: "open", brow: 0.2, sweat: 0, sparkle: 0, wavy: false, urgency: 0.3 }
    if (deficit < 0.6) return { label: "Preocupado", smile: -0.4, eyes: "open", brow: 0.65, sweat: 1, sparkle: 0, wavy: false, urgency: 0.62 }
    return { label: "Estressado", smile: -0.9, eyes: "wide", brow: 1, sweat: 2, sparkle: 0, wavy: true, urgency: 1 }
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function openForCapture() { if (panelLoader.item) panelLoader.item.openForCapture() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("host" in target) target.host = root
    if ("binPath" in target) target.binPath = root.binPath
  }

  function refresh() { if (!stateProc.running) stateProc.running = true }
  function applyState(text) {
    try { root.backendState = JSON.parse(text) } catch (e) {}
    if (panelLoader.item && panelLoader.item.applyState) panelLoader.item.applyState(root.backendState)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Process {
    id: stateProc
    command: [root.binPath, "state"]
    stdout: StdioCollector { id: stateOut }
    onExited: function(code) { if (code === 0) root.applyState(stateOut.text) }
  }

  Timer {
    interval: root.runningText ? 1000 : 15000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel); root.refresh() }
  }

  IpcHandler {
    target: "kruschewskyjoao95.daily-tasks"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function capture(): void { root.openForCapture() }
    function status(): string { return root.stats.done + "/" + root.stats.total + " " + root.mood.label }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: 7
    fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + Style.spaceReal(7) * 2)
    fixedHeight: root.vertical ? Math.round(content.implicitHeight + Style.spaceReal(4) * 2) : -1
    tooltipText: root.stats.total > 0
      ? root.mood.label + " · " + root.stats.done + " de " + root.stats.total + " concluídas" + (root.runningText ? " · ▶ " + root.runningText : "")
      : "Tarefas do Dia — nada planejado ainda"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.openForCapture()
      else root.togglePanel()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)

      Mascot {
        width: Math.round(Style.bar.iconCanvas * 1.2)
        height: Math.round(Style.bar.iconCanvas * 1.2)
        anchors.verticalCenter: parent.verticalCenter
        baseColor: root.bar ? root.bar.barForeground : Color.foreground
        alertColor: root.bar ? root.bar.urgent : Color.urgent
        animated: root.visible
        working: root.runningText !== ""
        urgency: root.mood.urgency
        smile: root.mood.smile
        eyes: root.mood.eyes
        brow: root.mood.brow
        sweat: root.mood.sweat
        sparkle: root.mood.sparkle
        wavy: root.mood.wavy
      }

      Text {
        visible: root.showCount && !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.runningText ? root.countText + " ▶" : root.countText
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }
  }

  Component.onCompleted: root.refresh()
}
