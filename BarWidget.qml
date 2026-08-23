import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "bottelet.focus-modes"

  // The window this widget instance is mounted in — the bar object itself is
  // shared across screens, so the per-screen identity has to come from here
  // (the panel uses it to elect exactly one engine-owner instance).
  readonly property var qsWindow: QsWindow.window

  // Mirrored off the panel so the chip can show the active mode at a glance.
  readonly property bool modeActive: panelLoader.item ? panelLoader.item.modeActive : false
  readonly property string modeIcon: panelLoader.item ? panelLoader.item.chipIcon : ""
  readonly property string chipText: panelLoader.item ? panelLoader.item.chipText : ""

  readonly property bool showLabel: setting("showLabel", true) === true || setting("showLabel", true) === "true"
  readonly property bool scrollCycles: setting("scrollCycles", false) === true || setting("scrollCycles", false) === "true"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = chip
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function openSettings() {
    if (panelLoader.item && panelLoader.item.openSettings) panelLoader.item.openSettings()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (see the weather plugin for the long-form rationale).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // The chip: outline icon when Off; icon + mode name + countdown while a
  // mode runs, tinted so "I'm in a mode" reads from across the room.
  Item {
    id: chip
    implicitWidth: chipRow.implicitWidth + Style.space(root.modeActive && root.showLabel ? 12 : 8)
    implicitHeight: Math.max(chipRow.implicitHeight + Style.space(4), Style.bar.statusSlot)

    Rectangle {
      anchors.centerIn: parent
      width: parent.implicitWidth
      height: Math.min(parent.height, chipRow.implicitHeight + Style.space(6))
      radius: Style.cornerRadius
      color: root.modeActive ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
      border.width: root.modeActive ? 1 : 0
      border.color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.55)
    }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        text: root.modeActive && root.modeIcon !== "" ? root.modeIcon : "󰈉"
        textFormat: Text.PlainText
        color: root.modeActive ? Color.accent : (chipArea.containsMouse ? (root.bar ? root.bar.foreground : Color.foreground) : Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: root.modeActive && root.showLabel && root.chipText !== ""
        text: root.chipText
        textFormat: Text.PlainText
        color: Color.accent
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: chipArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onClicked: root.togglePanel()
      onWheel: function(wheel) {
        if (!root.scrollCycles || !panelLoader.item) return
        panelLoader.item.cycleMode(wheel.angleDelta.y > 0 ? -1 : 1)
      }
    }
  }
}
