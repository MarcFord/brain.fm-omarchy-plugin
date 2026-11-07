import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Brain.fm bar item. Read-only: it shows what the daemon reports and nothing
// else. Transport controls arrive in a later milestone.
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

  // Hover tooltip via the bar facade, which owns tooltip placement. Feature
  // detected: the third-party facade is capability scoped and may not expose
  // it.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton

    onEntered: {
      if (root.bar && typeof root.bar.showTooltip === "function")
        root.bar.showTooltip(root, root.tooltipText)
    }
    onExited: {
      if (root.bar && typeof root.bar.hideTooltip === "function")
        root.bar.hideTooltip(root)
    }
  }

}
