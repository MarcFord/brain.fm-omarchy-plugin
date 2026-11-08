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

  // ---- Session length, in the three modes the service supports and the web
  //      player offers: open-ended, a countdown, or work/break intervals.
  property string timerMode: "infinite"   // infinite | timer | intervals

  // Countdown. Brain.fm's own suggestions are per-state -- 60/90/120 minutes
  // for focus but 7/8/9 hours for sleep -- so they are read from the service
  // and never hardcoded. The generic ladder is the fallback for a daemon whose
  // CLI cannot list them, and is offered as plain durations rather than as
  // anything Brain.fm recommended.
  property string selLength: ""
  readonly property var lengthOptions: {
    const fromDaemon = service ? (service.sessionLengths || []) : []
    if (fromDaemon.length > 0) return fromDaemon
    return [
      { value: "15m", label: "15 min" },
      { value: "30m", label: "30 min" },
      { value: "45m", label: "45 min" },
      { value: "60m", label: "60 min" },
      { value: "90m", label: "90 min" },
      { value: "120m", label: "120 min" }
    ]
  }

  // Intervals. Not catalogue data -- a work/break cycle is a technique, not
  // something Brain.fm publishes per state -- so these stay local.
  property int intWork: 25
  property int intBreak: 5
  property int intRepeat: 4
  readonly property var workOptions: [15, 25, 50]
  readonly property var breakOptions: [5, 10]
  // 0 means endless -- "x*", cycling until stopped. It needs interface
  // version 6, so it is offered only when the daemon actually reports that;
  // a missing count means exactly one cycle, not "forever", and "x0" is
  // rejected, so there is no way to fake it on an older daemon.
  readonly property var repeatOptions: {
    const out = [
      { value: 2, label: "×2" },
      { value: 4, label: "×4" },
      { value: 6, label: "×6" },
      { value: 8, label: "×8" }
    ]
    if (service && service.supportsEndlessIntervals)
      out.push({ value: 0, label: "Endless" })
    return out
  }

  // The spec handed to `bfm --timer` / `bfm timer`. "" means no timer, which
  // the service takes as the argument being absent rather than empty.
  readonly property string timerSpec: {
    if (timerMode === "timer") return selLength
    if (timerMode === "intervals")
      return intWork + "m/" + intBreak + "m x" + (intRepeat === 0 ? "*" : intRepeat)
    return ""
  }

  readonly property string timerSummary: {
    if (timerMode === "timer") {
      if (selLength === "") return "no length picked"
      for (let i = 0; i < lengthOptions.length; i++)
        if (lengthOptions[i].value === selLength) return lengthOptions[i].label
      return selLength
    }
    if (timerMode === "intervals") {
      const rounds = intRepeat === 0 ? "endless" : "×" + intRepeat
      return intWork + " min work / " + intBreak + " min break, " + rounds
    }
    return "runs until you stop it"
  }

  function chooseTimerMode(mode) {
    timerMode = mode
    // A countdown with nothing picked cannot start, so default to the
    // service's first suggestion the moment the mode is chosen.
    if (mode === "timer" && selLength === "" && lengthOptions.length > 0)
      selLength = String(lengthOptions[0].value)
  }

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
    // Activities, genres and suggested lengths are all per-state, so a
    // carried-over choice would be silently invalid -- a 60-minute focus
    // length is not among sleep's 7-to-9-hour ones. The chosen *mode* is kept,
    // because wanting a countdown is not state-specific; only the length is
    // dropped, and refreshLength() picks a valid one when the new list lands.
    selActivity = ""
    selGenres = []
    selLength = ""
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
    // A countdown with no length picked would silently start open-ended.
    && !(timerMode === "timer" && selLength === "")

  // The panel's primary action, shared by the Start button and by Enter.
  // Omarchy's panels are expected to be keyboard-drivable -- that is what
  // KeyboardPanel and PanelKeyCatcher exist for -- and routing both through
  // one function keeps the two from drifting apart.
  function startSelected() {
    if (!canStart) return
    service.startSession(selState, selActivity, selGenres, selEffort, timerSpec)
    closeRequested()
  }

  // Change the timer on the session that is already playing, without
  // restarting it. This is what `bfm timer` is for, and without it the three
  // modes would only be reachable by starting a new session.
  function applyTimerToCurrent() {
    if (!service || !hasSession) return
    service.setTimer(timerSpec)
  }

  function titleCase(s) {
    const t = String(s || "")
    return t.length === 0 ? t : t.charAt(0).toUpperCase() + t.slice(1)
  }

  onServiceChanged: syncDefaults()
  Component.onCompleted: syncDefaults()

  // Keep the countdown length valid: it is cleared when the mental state
  // changes, and the replacement list only arrives once `bfm list` returns.
  function refreshLength() {
    if (timerMode !== "timer") return
    const opts = lengthOptions
    if (opts.length === 0) return
    for (let i = 0; i < opts.length; i++)
      if (String(opts[i].value) === selLength) return
    selLength = String(opts[0].value)
  }

  Connections {
    target: root.service
    function onMentalStatesChanged() { root.syncDefaults() }
    function onSessionLengthsChanged() { root.refreshLength() }
  }

  onTimerModeChanged: refreshLength()

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
            text: "LENGTH — " + root.timerSummary.toUpperCase()
            foreground: root.fg
            fontFamily: root.fontFamily
            width: parent.width
            elide: Text.ElideRight
          }

          // The three modes the service supports, named the way the web
          // player names them.
          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)

            readonly property var modes: [
              { value: "infinite", label: "Open-ended" },
              { value: "timer", label: "Timer" },
              { value: "intervals", label: "Intervals" }
            ]
            readonly property real cellWidth:
              (width - spacing * (modes.length - 1)) / modes.length

            Repeater {
              model: modeRow.modes
              Button {
                required property var modelData
                width: modeRow.cellWidth
                text: String(modelData.label)
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.timerMode === String(modelData.value)
                onClicked: root.chooseTimerMode(String(modelData.value))
              }
            }
          }

          // Countdown lengths.
          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.timerMode === "timer"

            Repeater {
              model: root.lengthOptions
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

          // Interval shape: work, break, and how many times round.
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            visible: root.timerMode === "intervals"

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Work"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: Style.space(44)
              }

              Repeater {
                model: root.workOptions
                Button {
                  required property var modelData
                  text: modelData + "m"
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  bordered: true
                  active: root.intWork === Number(modelData)
                  onClicked: root.intWork = Number(modelData)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Break"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: Style.space(44)
              }

              Repeater {
                model: root.breakOptions
                Button {
                  required property var modelData
                  text: modelData + "m"
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  bordered: true
                  active: root.intBreak === Number(modelData)
                  onClicked: root.intBreak = Number(modelData)
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Repeat"
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: Style.space(44)
              }

              Repeater {
                model: root.repeatOptions
                Button {
                  required property var modelData
                  text: String(modelData.label)
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  bordered: true
                  active: root.intRepeat === Number(modelData.value)
                  onClicked: root.intRepeat = Number(modelData.value)
                }
              }
            }
          }

          // Changing the timer on the session already playing, rather than
          // starting a new one for the sake of it.
          Button {
            width: parent.width
            visible: root.hasSession
            text: "Set this on the current session"
            iconText: "󱎫"
            bordered: true
            focusable: true
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            enabled: root.service && !root.service.busy
            opacity: enabled ? 1.0 : 0.45
            onClicked: root.applyTimerToCurrent()
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
