import QtQuick
import qs.Commons
import qs.Ui

// Brain.fm bar item: current session state, and a popup to control it.
//
// The file is Widget.qml rather than BarWidget.qml on purpose: a file named
// BarWidget.qml whose root type is also BarWidget resolves only because
// qs.Ui wins over same-directory type resolution, and fails confusingly if
// that import ever stops resolving.
BarWidget {
  id: root

  moduleName: "marcford.brainfm"

  // The host injects `bar`, `moduleName` and `settings` into a bar widget and
  // nothing else -- no `shell`, no `service`. A third-party widget reaches its
  // own service through the capability-scoped bar facade, which only ever
  // returns a service belonging to the asking plugin.
  //
  // Null until the service component finishes loading, so every read below is
  // guarded.
  readonly property var service: bar && bar.shell
    && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null

  readonly property string sessionState: service ? service.sessionState : "starting"
  readonly property string trackTitle: service ? service.trackTitle : ""
  readonly property bool reachable: service ? service.reachable : false

  // Manifest `defaults` are not delivered to QML -- enabling a widget writes a
  // bare {id} entry and `settings` stays empty until a user changes something.
  // Every fallback here therefore has to repeat the manifest's defaultValue.
  readonly property bool showTrackTitle: root.setting("showTrackTitle", true) === true
  readonly property int maxTitleWidth: {
    const raw = Math.floor(Number(root.setting("maxTitleWidth", 180)))
    if (!isFinite(raw) || raw <= 0) return 0
    return Math.max(0, Math.min(560, raw))
  }

  // ---- Popup lifecycle.
  //
  // open(), close() and opened are not just for the mouse: Bar.findPanelWidget
  // skips any bar widget that does not expose all three, and that is what
  // routes `omarchy-shell shell summon marcford.brainfm` -- and so a keybinding
  // -- to this widget. The popup state lives here rather than in SessionPanel
  // because the bar identifies a popup by the item mounted in its slot.
  property bool opened: false
  // Read back off the owner by KeyboardPanel to suppress the fade when one bar
  // popup replaces another.
  property bool popoutSwitchClosing: false

  function open() {
    opened = true
    // Re-read the running timer on every open, so the panel shows what is
    // actually set rather than what was last picked in it.
    sessionPanel.reload()
  }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function () { root.popoutSwitchClosing = false })
  }

  // Nerd Font glyphs. Each codepoint below was rendered in the font that
  // `monospace` resolves to here and identified by eye -- the nf-md names are
  // not a reliable guide to which codepoint draws what, and three of the five
  // first chosen here turned out to draw something else entirely.
  //
  // The brain holds the idle state so the widget still reads as Brain.fm at
  // rest; the others describe what is happening instead.
  readonly property string stateGlyph: {
    switch (sessionState) {
    case "playing":   return "󰎇"  // U+F0387 music note
    case "paused":    return "󰏤"  // U+F03E4 pause
    case "buffering": return "󰇘"  // U+F01D8 dots-horizontal
    case "idle":      return "󰧑"  // U+F09D1 brain
    case "unavailable":
    case "starting":  return "󰅤"  // U+F0164 cloud-off
    default:          return "󰧑"  // U+F09D1 brain
    }
  }

  readonly property string tooltipText: service
    ? service.tooltipText : "Brain.fm — connecting"

  // A title is only worth bar space while there is actually a session; a
  // vertical bar has no room for one at all.
  readonly property bool titleVisible: showTrackTitle
    && !vertical
    && trackTitle !== ""

  // The bar reads implicitWidth on a horizontal bar and forces width to
  // barSize on a vertical one, so only the horizontal case is computed here.
  implicitWidth: vertical ? barSize : contentRow.implicitWidth + Style.space(12)
  implicitHeight: barSize

  // WidgetButton rather than a bare Row plus a MouseArea. It registers itself
  // as one of the bar's click targets, which is what makes a click work both
  // normally and while a popup overlay covers the screen, and it is the only
  // thing that satisfies the `tooltipHovered` contract `bar.showTooltip`
  // requires -- a hand-rolled MouseArea calling showTooltip is dropped on the
  // floor silently, with no error and no tooltip.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    // Defaults to `text !== ""`, and this button draws its own children rather
    // than a label, so without this the whole widget is invisible.
    hasVisualContent: true
    tooltipText: root.tooltipText
    active: root.opened

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        // The one thing worth doing without opening anything.
        if (!root.service) return
        if (root.sessionState === "playing") root.service.pause()
        else if (root.sessionState === "paused") root.service.resume()
        return
      }
      root.toggle()
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: root.titleVisible ? Style.space(6) : 0

      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        text: root.stateGlyph
        textFormat: Text.PlainText
        // The bar's own foreground, not Color.foreground: it is contrast
        // corrected when bar transparency is on.
        color: root.bar ? root.bar.barForeground : Color.foreground
        // Dimmed whenever the daemon is not reachable, so an outage reads as an
        // outage without needing the tooltip.
        opacity: root.reachable ? 1.0 : 0.5
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering

        Behavior on opacity {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          NumberAnimation { duration: 160 }
        }
      }

      Item {
        id: titleClip
        visible: root.titleVisible
        anchors.verticalCenter: parent.verticalCenter
        height: glyph.height
        clip: true
        width: !root.titleVisible
          ? 0
          : (root.maxTitleWidth > 0
            ? Math.min(root.maxTitleWidth, titleText.implicitWidth)
            : titleText.implicitWidth)

        Text {
          id: titleText
          text: root.trackTitle
          textFormat: Text.PlainText
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          renderType: Text.NativeRendering
        }
      }
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    // The popout identity has to be the widget in the bar slot, not the panel:
    // the bar compares against slot.activeItem to decide which popup is open
    // and which one to close when another opens.
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(sessionPanel.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      // Enter starts the selected session. KeyboardPanel exists so a panel can
      // be driven from the keyboard, and the primary action is the one thing
      // that has to be reachable that way.
      onReturnRequested: sessionPanel.startSelected()

      SessionPanel {
        id: sessionPanel
        anchors.fill: parent
        service: root.service
        bar: root.bar
        onCloseRequested: root.close()
      }
    }
  }
}
