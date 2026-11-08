import QtQuick
import qs.Commons
import qs.Ui

// The contents of the bar popup: what is playing, transport for it, and a
// picker for starting something new.
//
// Lives in its own file only to keep Widget.qml readable -- it is an ordinary
// local component, not a plugin entry point, so the bar still sees a single
// widget and `owner` stays the widget root.
//
// Every list here is filled from the daemon (`bfm list ...`). Nothing about the
// Brain.fm catalogue is hardcoded, so this cannot drift from what the service
// actually offers or from the other front-ends.
Item {
  id: root

  property var service: null
  property var bar: null

  signal closeRequested

  readonly property color fg: bar ? bar.foreground : Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string sessionState: service ? service.sessionState : "starting"
  readonly property bool reachable: service ? service.reachable : false
  readonly property bool hasSession: sessionState === "playing"
    || sessionState === "paused" || sessionState === "buffering"

  implicitHeight: column.implicitHeight

  // ---- Selection, local to the panel until Start is pressed.
  property string selState: ""
  property string selActivity: ""
  property var selGenres: []
  property string selEffort: "high"
  property string selLength: ""

  // Session length. BrainFM1 exposes ListSessionLengths but the CLI has no
  // `bfm list session-lengths`, so these are the three shapes SetTimer accepts
  // rather than a fetched catalogue -- the one list here that is not read from
  // the daemon, and labelled as a choice of shape rather than of preset.
  readonly property var lengths: [
    { value: "", label: "Open-ended" },
    { value: "25m", label: "25m" },
    { value: "50m", label: "50m" },
    { value: "90m", label: "90m" },
    { value: "25m/5m x4", label: "25/5 ×4" }
  ]

  readonly property var efforts: [
    { value: "low", label: "Low" },
    { value: "medium", label: "Medium" },
    { value: "high", label: "High" }
  ]

  function syncDefaults() {
    if (!service) return
    if (selState === "") {
      const states = service.mentalStates || []
      if (states.length > 0) chooseState(String(states[0]))
    }
  }

  function chooseState(next) {
    if (next === selState) return
    selState = next
    // The activity and genre lists are per-state, so a carried-over choice
    // would be silently invalid.
    selActivity = ""
    selGenres = []
    if (service) service.loadCatalog(next)
  }

  function toggleGenre(name) {
    const out = []
    let found = false
    for (let i = 0; i < selGenres.length; i++) {
      if (selGenres[i] === name) { found = true; continue }
      out.push(selGenres[i])
    }
    if (!found) out.push(name)
    // Replaced wholesale: QML does not notice a `var` array mutated in place.
    selGenres = out
  }

  function hasGenre(name) {
    for (let i = 0; i < selGenres.length; i++) if (selGenres[i] === name) return true
    return false
  }

  readonly property bool canStart: selState !== "" && service !== null
    && !service.busy && reachable

  // The panel's primary action, shared by the Start button and by Enter.
  // Omarchy's panels are expected to be keyboard-drivable -- that is what
  // KeyboardPanel and PanelKeyCatcher exist for -- and routing both through
  // one function keeps the two from drifting apart.
  function startSelected() {
    if (!canStart) return
    service.startSession(selState, selActivity, selGenres, selEffort, selLength)
    closeRequested()
  }

  function titleCase(s) {
    const t = String(s || "")
    return t.length === 0 ? t : t.charAt(0).toUpperCase() + t.slice(1)
  }

  onServiceChanged: syncDefaults()
  Component.onCompleted: syncDefaults()

  Connections {
    target: root.service
    function onMentalStatesChanged() { root.syncDefaults() }
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      width: flick.width
      spacing: Style.space(14)

      // ---- What is happening now.
      Column {
        width: parent.width
        spacing: Style.spacing.labelGap

        Text {
          width: parent.width
          text: root.service
            ? (root.service.trackTitle !== "" ? root.service.trackTitle : root.titleCase(root.sessionState))
            : "Connecting"
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        // The daemon formats this, including the timer phase and time left
        // ("playing - work 49:56 left"), so the plugin does not reimplement
        // that formatting and cannot disagree with the other front-ends.
        Text {
          width: parent.width
          text: root.service ? root.service.tooltipText : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- Transport. Only shown when there is something to control.
      Row {
        width: parent.width
        spacing: Style.space(6)
        visible: root.hasSession

        Button {
          text: root.sessionState === "paused" ? "Resume" : "Pause"
          iconText: root.sessionState === "paused" ? "󰐊" : "󰏤"
          bordered: true
          focusable: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: {
            if (!root.service) return
            if (root.sessionState === "paused") root.service.resume()
            else root.service.pause()
          }
        }

        // No previous-track button: Brain.fm sessions only move forward and
        // bfmd reports CanGoPrevious false. Same for seeking.
        Button {
          text: "Skip"
          iconText: "󰒭"
          bordered: true
          focusable: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.skip()
        }

        Button {
          text: "Stop"
          iconText: "󰓛"
          bordered: true
          focusable: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: if (root.service) root.service.stop()
        }
      }

      // ---- The daemon is not there. Say what to do about it rather than
      //      showing a picker that cannot work.
      Text {
        width: parent.width
        visible: !root.reachable
        text: "The Brain.fm daemon is not running.\nRun `bfm status` in a terminal to see why."
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(root.fg, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        foreground: root.fg
        visible: root.reachable
      }

      // ---- Start something new.
      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.reachable

        PanelSectionHeader {
          text: "NEW SESSION"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        // Mental states, split evenly across the popup the way the power
        // panel lays out its profiles.
        Row {
          id: stateRow
          width: parent.width
          spacing: Style.space(6)

          readonly property var items: root.service ? (root.service.mentalStates || []) : []
          readonly property real cellWidth: items.length > 0
            ? (width - spacing * (items.length - 1)) / items.length
            : 0

          Repeater {
            model: stateRow.items
            Button {
              required property var modelData
              width: stateRow.cellWidth
              text: root.titleCase(String(modelData))
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: root.selState === String(modelData)
              onClicked: root.chooseState(String(modelData))
            }
          }
        }

        // Activities wrap: the daemon returns five for focus and two for
        // meditate, so a fixed row would either clip or waste space.
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          visible: activityFlow.children.length > 0

          PanelSectionHeader {
            text: "ACTIVITY"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Flow {
            id: activityFlow
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.service ? (root.service.activities || []) : []
              Button {
                required property var modelData
                text: String(modelData.name)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.selActivity === String(modelData.name)
                // Tapping the chosen activity again clears it, which is how
                // you get back to "no activity" without restarting the panel.
                onClicked: root.selActivity =
                  (root.selActivity === String(modelData.name) ? "" : String(modelData.name))
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap
          visible: genreFlow.children.length > 0

          PanelSectionHeader {
            text: "GENRE — OPTIONAL, PICK ANY"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Flow {
            id: genreFlow
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.service ? (root.service.genres || []) : []
              Button {
                required property var modelData
                text: String(modelData)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.hasGenre(String(modelData))
                onClicked: root.toggleGenre(String(modelData))
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: "NEURAL EFFECT"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Row {
            id: effortRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth:
              (width - spacing * (root.efforts.length - 1)) / root.efforts.length

            Repeater {
              model: root.efforts
              Button {
                required property var modelData
                width: effortRow.cellWidth
                text: String(modelData.label)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.selEffort === String(modelData.value)
                onClicked: root.selEffort = String(modelData.value)
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: "LENGTH"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.lengths
              Button {
                required property var modelData
                text: String(modelData.label)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.selLength === String(modelData.value)
                onClicked: root.selLength = String(modelData.value)
              }
            }
          }
        }

        Button {
          width: parent.width
          text: root.hasSession ? "Replace session" : "Start session"
          iconText: "󰐊"
          bordered: true
          focusable: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          // Button does not dim itself when disabled, so say so explicitly.
          enabled: root.canStart
          opacity: enabled ? 1.0 : 0.45
          onClicked: root.startSelected()
        }

        Text {
          width: parent.width
          visible: root.service && root.service.lastError !== ""
          text: root.service ? root.service.lastError : ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- Hand off to the desktop app, when one is installed.
      //
      // This is the one place the existing GTK front-end is reused, and it is
      // reused by launching it rather than importing it: its UI cannot be
      // loaded into the shell process.
      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.service && root.service.hasFullApp

        PanelSeparator { foreground: root.fg }

        Button {
          width: parent.width
          text: "Open full app"
          iconText: "󰏋"
          bordered: true
          focusable: true
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: {
            if (root.service) root.service.openFullApp()
            root.closeRequested()
          }
        }
      }
    }
  }
}
