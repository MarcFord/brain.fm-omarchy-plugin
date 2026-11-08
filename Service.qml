import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// Shared state for every Brain.fm bar surface.
//
// One instance exists per shell process: the host creates `kind: "service"`
// entry points once and hands the same object to each bar widget through
// `bar.shell.serviceFor(id)`. That matters here because this service owns a
// long-running `bfm status --watch --json` child, and instantiating it per bar
// (the alternative pattern, a local `Service {}` in the widget) would mean one
// watcher process and one daemon activation per monitor.
//
// State comes from the `bfm` CLI, which upstream documents as a thin D-Bus
// client over `dev.marcford.BrainFM1`. No Brain.fm API call is made here.
Item {
  id: root

  // Services are parented to a visual host, so they must not paint.
  visible: false
  width: 0
  height: 0

  // ---- Host injection (filled in by shell.qml only if the property exists).
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "marcford.brainfm"

  // ---- Public surface read by the bar widget.
  //
  // `sessionState`, not `state`: `Item.state` already exists in QtQuick and
  // silently means something else (a QML state name).
  //
  // Starts at "starting", never at "idle". An idle daemon and an absent one
  // look identical in a bar that defaults to idle, and the absent case is the
  // one a user needs to see.
  property string sessionState: "starting"
  property string trackTitle: ""
  property string tooltipText: "Brain.fm — connecting"

  readonly property bool reachable: sessionState !== "unavailable"
    && sessionState !== "starting"
  readonly property bool playing: sessionState === "playing"

  // ---- MPRIS, used only as a liveness signal.
  //
  // `bfm status --watch --json` has two blind spots in **v0.1.0**, the released
  // build, both verified against it here rather than assumed:
  //
  //   1. A watcher that starts while no daemon is reachable prints one
  //      "unavailable" line and then stays silent forever, even once a daemon
  //      appears. It does not exit, so nothing would otherwise retry it.
  //   2. A watcher whose daemon dies mid-stream prints nothing at all and
  //      keeps running, leaving the last state on screen indefinitely. A bar
  //      built on the stream alone shows "playing" for a dead daemon.
  //
  // Upstream has since made the stream follow the daemon in both directions,
  // which makes this redundant against a daemon that has that change.
  //
  // It is kept for CLIs that do not promise that, and is inert on ones that
  // do. `bfm capabilities` advertises `watch-follows-daemon` by name, so this
  // is now gated on evidence rather than on a version number or a line in the
  // README -- which is the only reason it is conditional at all. Being wrong
  // here means a bar that shows "playing" for a daemon that is gone: the one
  // thing this plugin exists to prevent, and the hardest for a user to
  // attribute, because a stale bar looks exactly like a working one. A CLI
  // that cannot be asked keeps the fallback.
  //
  // The cost of keeping it is near zero: no polling and no subprocess, just a
  // binding on a model the shell already maintains. The two signals cannot
  // disagree in a way that matters, because MPRIS only ever sets "unavailable"
  // or asks for a re-read, and a re-read we asked for is not reported as an
  // outage.
  //
  // bfmd owns org.mpris.MediaPlayer2.bfm for as long as it runs -- including
  // while idle, with PlaybackStatus "Stopped" -- so the name appearing or
  // vanishing is an event-driven answer to "is the daemon there", with no
  // polling. It is deliberately not what gets displayed: the stream stays the
  // source of truth for state, and MPRIS only decides when to re-read it.
  readonly property var mprisPlayer: {
    const players = Mpris.players ? Mpris.players.values : []
    for (let i = 0; i < players.length; i++) {
      if (root._isBfmPlayer(players[i])) return players[i]
    }
    return null
  }

  // Tolerates either MPRIS naming convention. Quickshell reports the full bus
  // name today; matching the suffix too means a change there degrades to
  // "liveness unknown" (stream-only behaviour) instead of "daemon always down".
  function _isBfmPlayer(player) {
    if (!player) return false
    const name = String(player.dbusName || "")
    return name === "org.mpris.MediaPlayer2.bfm"
      || name === "bfm"
      || name.indexOf("MediaPlayer2.bfm") >= 0
  }

  // True once bfmd has been seen on the bus at least once this session. Until
  // then MPRIS absence proves nothing -- it could be a daemon that never
  // registers MPRIS -- so the stream is trusted on its own.
  property bool _mprisEverSeen: false

  onMprisPlayerChanged: {
    // The CLI says its stream follows the daemon on its own, so there is
    // nothing for this to add. Gated on the guarantee by name rather than on
    // a version number, because the name is the thing that is promised.
    if (watchFollowsDaemon) return
    if (mprisPlayer) {
      _mprisEverSeen = true
      // Only "unavailable" is worth a restart. "starting" means the watcher
      // simply has not printed its first line yet -- and since bfmd is D-Bus
      // activated, that first line is itself what brings the daemon up, so
      // MPRIS appearing while we are "starting" is the normal startup order,
      // not a stuck stream. Restarting on it killed the watcher mid-handshake
      // and showed a spurious "daemon not running" flash on every login.
      if (sessionState === "unavailable") _restartWatcher(true)
      return
    }
    if (!_mprisEverSeen) return
    // The daemon went away and a v0.1.0 stream will not say so (blind spot 2).
    // Report it -- but deliberately do NOT restart the watcher here. Restarting
    // runs `bfm`, the name is D-Bus activatable, and that would start a fresh
    // daemon purely because something was watching. A bar must not resurrect
    // the service it reports on, least of all one the user just stopped.
    //
    // Recovery is driven by the opposite edge instead: when the name comes back
    // the branch above restarts the stream, and MPRIS reappearing is proof the
    // daemon is already running rather than a request to start one.
    _setUnavailable("Brain.fm — daemon stopped")
  }

  // ---- The state stream.

  // Backoff for restarts, in ms. Reset on any successful read.
  property int _backoffMs: 1000
  readonly property int _backoffCeilingMs: 30000

  function _setUnavailable(reason) {
    sessionState = "unavailable"
    trackTitle = ""
    tooltipText = reason
  }

  // Set while a restart is one we asked for, so the exit it causes is not
  // mistaken for the daemon going away. Without it, every deliberate restart
  // published a false "daemon not running" before the new stream connected.
  property bool _restartIntended: false

  // `resetBackoff` is for restarts triggered by evidence that something
  // changed (MPRIS appeared, the daemon died), where waiting out a grown
  // backoff would just delay a restart that is already known to be worthwhile.
  function _restartWatcher(resetBackoff) {
    if (resetBackoff) _backoffMs = 1000
    // Setting running = false fires onExited, which schedules the restart.
    if (watcher.running) {
      _restartIntended = true
      watcher.running = false
    } else {
      restartTimer.restart()
    }
  }

  // One JSON object per state change, newline-delimited:
  //   {"text":"Topography","alt":"playing","tooltip":"playing","class":"playing"}
  //
  // `class` is the state. With a session bus present but no daemon reachable,
  // the CLI reports class "unavailable" in-band and exits 0, which is why this
  // is the right probe for a bar; plain `bfm status` exits non-zero instead and
  // would make a dead daemon indistinguishable from a broken command.
  function _handleLine(line) {
    const text = String(line || "").replace(/\r$/, "").trim()
    if (text === "") return

    let frame
    try {
      frame = JSON.parse(text)
    } catch (e) {
      // A warning on stdout or a torn write must not kill the handler and take
      // the stream with it.
      console.warn("marcford.brainfm: unparseable status line:", text)
      return
    }
    if (!frame || typeof frame !== "object") return

    _backoffMs = 1000

    const cls = String(frame.class || frame.alt || "").trim() || "unknown"
    const label = String(frame.text || "").trim()
    const tip = String(frame.tooltip || "").trim()

    if (cls === "unavailable") {
      _setUnavailable(tip ? "Brain.fm — " + tip : "Brain.fm — daemon not running")
      return
    }

    sessionState = cls
    // `text` falls back to the state name when there is no track, so a title
    // equal to the state is not a title.
    trackTitle = (label !== "" && label !== cls) ? label : ""
    tooltipText = trackTitle !== ""
      ? trackTitle + " — " + (tip || cls)
      : "Brain.fm — " + (tip || cls)
  }

  Process {
    id: watcher

    // setpriv --pdeathsig TERM: without it this child outlives an
    // omarchy-shell crash and keeps a daemon activation alive with nothing
    // reading it.
    command: ["setpriv", "--pdeathsig", "TERM",
      "bfm", "status", "--watch", "--json"]

    // `root` is null-checked in both parsers: the shell tears a plugin down by
    // destroying the service while its child is still draining, and an
    // unguarded `root._handleLine` throws
    // "TypeError: Cannot read property '_handleLine' of null" on every reload.
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { if (root) root._handleLine(line) }
    }

    // Kept out of the journal, but surfaced in the tooltip on failure below.
    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function (line) {
        if (!root) return
        const text = String(line || "").trim()
        if (text !== "") root._lastStderr = text
      }
    }

    onExited: function (exitCode) {
      if (!root) return
      if (root._restartIntended) {
        // We stopped it on purpose. Leave the displayed state alone and
        // reconnect promptly; the next line will correct it either way.
        root._restartIntended = false
        restartTimer.interval = 250
        restartTimer.restart()
        return
      }
      // An unasked-for exit means the stream is gone, so nothing on screen is
      // current any more. Say so rather than leaving the last known state up.
      if (exitCode !== 0 && root._lastStderr !== "") {
        root._setUnavailable("Brain.fm — " + root._lastStderr)
      } else {
        root._setUnavailable("Brain.fm — daemon not running")
      }
      restartTimer.interval = root._backoffMs
      root._backoffMs = Math.min(root._backoffMs * 2, root._backoffCeilingMs)
      restartTimer.restart()
    }
  }

  property string _lastStderr: ""

  Timer {
    id: restartTimer
    interval: 1000
    repeat: false
    onTriggered: if (!watcher.running) watcher.running = true
  }

  // Backstop for blind spot 1 in the case MPRIS cannot cover: a stream stuck
  // on "unavailable" while the process is still alive, with no MPRIS name to
  // watch for. Deliberately slow -- the MPRIS path handles the realistic
  // recovery, and each probe re-activates a D-Bus activated daemon.
  Timer {
    id: staleProbeTimer
    interval: 30000
    repeat: true
    // Same gate: a stream that follows the daemon recovers on its own, so
    // polling it would only re-activate a daemon the user stopped.
    running: !root.watchFollowsDaemon
      && root.sessionState === "unavailable" && watcher.running
    onTriggered: root._restartWatcher(true)
  }

  // ---- Commands.
  //
  // Everything below shells out to `bfm`, which upstream enforces to be a thin
  // D-Bus client with no API or audio code in it. The daemon's own state stream
  // is what reports the result, so none of these parse stdout for success --
  // they only surface a failure the user would otherwise never see.

  // Last command failure, shown in the panel until the next command succeeds.
  property string lastError: ""

  readonly property bool busy: actionProc.running

  function _run(args) {
    if (actionProc.running) return false
    lastError = ""
    _actionArgs = args
    actionProc.command = ["bfm"].concat(args)
    actionProc.running = true
    return true
  }

  property var _actionArgs: []

  function pause() { _run(["pause"]) }
  function resume() { _run(["resume"]) }
  function skip() { _run(["skip"]) }
  function stop() { _run(["stop"]) }

  // `timer` takes "" (infinite), "50m" (countdown) or "25m/5m x4" (intervals).
  function setTimer(spec) {
    // `bfm timer` with no argument clears it; passing "" as an argv entry is
    // not the same thing.
    _run(String(spec || "").trim() === "" ? ["timer"] : ["timer", String(spec)])
  }

  // True between asking for a session and the daemon reporting one.
  //
  // Starting a session fetches a queue of around forty tracks, which takes a
  // few seconds, and the daemon reports plain "idle" for all of it. A bar that
  // shows idle immediately after you press Start looks like a Start button
  // that did not work -- it is what made me think my own button was broken.
  //
  // This is not a guess about what the daemon is doing: it is set only by
  // issuing the command, and cleared the moment the daemon says anything else,
  // the command fails, or the wait becomes implausible.
  property bool startPending: false

  onSessionStateChanged: {
    if (sessionState !== "idle" && sessionState !== "starting") startPending = false
  }

  Timer {
    id: startPendingTimeout
    interval: 30000
    repeat: false
    running: root.startPending
    // A session that has not begun in thirty seconds is not starting. Better
    // to fall back to the daemon's own idle than to spin forever.
    onTriggered: root.startPending = false
  }

  function startSession(state, activity, genres, effort, timer) {
    const args = ["play", String(state)]
    if (activity) args.push("--activity", String(activity))
    const list = Array.isArray(genres) ? genres : []
    for (let i = 0; i < list.length; i++) args.push("--genre", String(list[i]))
    if (effort) args.push("--effort", String(effort))
    const spec = String(timer || "").trim()
    if (spec !== "") args.push("--timer", spec)
    const issued = _run(args)
    if (issued) startPending = true
    return issued
  }

  Process {
    id: actionProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }

    onExited: function (exitCode) {
      if (!root) return
      if (Number(exitCode) === 0) {
        root.lastError = ""
        return
      }
      // The command itself failed, so nothing is starting.
      root.startPending = false
      // bfm writes a human-readable reason to stderr. Keep the first line: the
      // rest is a multi-line hint block aimed at a terminal, not a bar popup.
      const err = String(stderr.text || "").trim().split("\n")[0].trim()
      root.lastError = err !== ""
        ? err
        : "bfm " + root._actionArgs.join(" ") + " failed (" + exitCode + ")"
    }
  }

  // ---- Catalogue.
  //
  // Mental states, activities and genres all come from the daemon rather than
  // being hardcoded, so this cannot drift from what Brain.fm actually offers or
  // from the other front-ends. `bfm list` has no --json, but its output is
  // simple: one item per line, and activities are "id<TAB>name".
  //
  property var mentalStates: []
  property var activities: []
  property var genres: []
  property string catalogState: ""

  // Suggested session lengths for the current mental state, as
  // [{ value: "<n>m", label: "<daemon's own label>" }].
  //
  // These are genuinely per-state -- focus is 60/90/120 minutes while sleep is
  // 7/8/9 hours -- so one hardcoded list is wrong for most states and absurd
  // for sleep. `bfm list session-lengths` is newer than the released CLI,
  // which exits non-zero with empty stdout for a list target it does not know.
  // That is the feature detection: when it fails the panel offers only the
  // lengths that are not catalogue data (open-ended, and the interval shape),
  // rather than inventing durations the service never suggested.
  property var sessionLengths: []
  property bool sessionLengthsSupported: false

  function loadCatalog(state) {
    const next = String(state || "").trim()
    if (next === "" || next === catalogState) return
    catalogState = next
    activities = []
    genres = []
    sessionLengths = []
    activitiesProc.running = false
    activitiesProc.command = ["bfm", "list", "activities", "--state", next]
    activitiesProc.running = true
    genresProc.running = false
    genresProc.command = ["bfm", "list", "genres", "--state", next]
    genresProc.running = true
    lengthsProc.running = false
    lengthsProc.command = ["bfm", "list", "session-lengths", "--state", next]
    lengthsProc.running = true
  }

  function _lines(text) {
    const out = []
    const raw = String(text || "").split("\n")
    for (let i = 0; i < raw.length; i++) {
      const line = raw[i].replace(/\r$/, "").trim()
      if (line !== "") out.push(line)
    }
    return out
  }

  Process {
    id: statesProc
    command: ["bfm", "list", "states"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root || Number(exitCode) !== 0) return
      root.mentalStates = root._lines(stdout.text)
    }
  }

  Process {
    id: activitiesProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root || Number(exitCode) !== 0) return
      // "id<TAB>name". The CLI wants the name, not the id, so the id is kept
      // only because Favorite needs that shape later.
      const rows = root._lines(stdout.text)
      const out = []
      for (let i = 0; i < rows.length; i++) {
        const parts = rows[i].split("\t")
        if (parts.length >= 2) out.push({ id: parts[0].trim(), name: parts[1].trim() })
        else out.push({ id: "", name: parts[0].trim() })
      }
      root.activities = out
    }
  }

  Process {
    id: genresProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root || Number(exitCode) !== 0) return
      root.genres = root._lines(stdout.text)
    }
  }

  Process {
    id: lengthsProc
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root) return
      if (Number(exitCode) !== 0) {
        // An older CLI that does not know this list target. Not an error worth
        // showing: the panel simply offers fewer lengths.
        root.sessionLengthsSupported = false
        root.sessionLengths = []
        return
      }
      // "seconds<TAB>label", the same shape as activities.
      const rows = root._lines(stdout.text)
      const out = []
      for (let i = 0; i < rows.length; i++) {
        const parts = rows[i].split("\t")
        if (parts.length < 2) continue
        const seconds = Number(parts[0].trim())
        if (!isFinite(seconds) || seconds <= 0) continue
        // SetTimer's countdown form is minutes. The label stays the daemon's
        // own ("7 hours"), so the panel reads the way the apps do.
        out.push({ value: String(Math.round(seconds / 60)) + "m",
                   label: parts[1].trim() })
      }
      root.sessionLengths = out
      root.sessionLengthsSupported = out.length > 0
    }
  }

  // ---- What the installed CLI guarantees about its own behaviour.
  //
  // `bfm capabilities` advertises CLI behaviour by name. It is the answer to
  // the problem that the watch fix changed how a stream behaves rather than
  // what the D-Bus interface contains, so InterfaceVersion does not move for
  // it and a version string is only a proxy for it.
  //
  // Verified against the installed binary rather than assumed: it needs no
  // session bus, and it does not start a daemon -- checked with bfmd stopped
  // and a process count either side -- so it is safe to run at startup before
  // anything is known about the environment.
  //
  // Daemon features stay on InterfaceVersion. This probe describes the CLI,
  // and a new CLI can be talking to an old daemon.
  property var capabilities: []

  // The stream reports the daemon appearing and disappearing by itself, so
  // the MPRIS fallback below is unnecessary. False until proven otherwise,
  // which is the safe direction: an older CLI, or one that could not be run,
  // guarantees nothing and keeps the fallback.
  readonly property bool watchFollowsDaemon:
    capabilities.indexOf("watch-follows-daemon") >= 0

  Process {
    id: capabilityProbe
    command: ["bfm", "capabilities", "--json"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root) return
      if (Number(exitCode) !== 0) {
        // A CLI too old to know the subcommand. Guarantees nothing.
        root.capabilities = []
        return
      }
      try {
        const parsed = JSON.parse(String(stdout.text || ""))
        const list = parsed.features
        root.capabilities = Array.isArray(list) ? list.map(String) : []
      } catch (e) {
        root.capabilities = []
      }
    }
  }

  // ---- Interface version, for feature detection.
  //
  // Read over D-Bus because neither the CLI's `--version` nor its JSON status
  // carries it: a daemon built from main still reports "bfm 0.1.0" while
  // serving a newer interface, so the binary version says nothing about which
  // members exist.
  //
  // 0 means "not read yet", never "old". A failed read is a daemon that is not
  // answering, and treating that as version 0 is the bug upstream's own GUIs
  // shipped -- telling the user their daemon was too old when it was merely
  // absent. Controls are gated on a version actually read.
  property int interfaceVersion: 0

  // `25m/5m x*` -- intervals that keep cycling until stopped, rather than a
  // fixed number of rounds.
  readonly property bool supportsEndlessIntervals: interfaceVersion >= 6

  Process {
    id: versionProbe
    running: false
    command: ["busctl", "--user", "--json=short", "get-property",
      "dev.marcford.bfm", "/dev/marcford/bfm",
      "dev.marcford.BrainFM1", "InterfaceVersion"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root || Number(exitCode) !== 0) return
      try {
        const parsed = JSON.parse(String(stdout.text || ""))
        const n = Math.floor(Number(parsed.data))
        if (isFinite(n) && n > 0) root.interfaceVersion = n
      } catch (e) {
        // Leave it unread rather than guessing a version.
      }
    }
  }

  // Only ever asked once the stream says a daemon is answering. Reading a
  // property off an activatable name would otherwise start the daemon just to
  // ask how new it is -- the same resurrection the MPRIS path avoids.
  onReachableChanged: {
    if (reachable && interfaceVersion === 0 && !versionProbe.running)
      versionProbe.running = true
  }

  // ---- The timer that is actually set right now.
  //
  // The status stream carries a human sentence ("work 24:52 left") but not the
  // shape behind it, so this reads the Timer property directly. It is what
  // lets the panel open showing the timer that is running rather than whatever
  // was last picked in it.
  //
  // `spec` is the string as it was set. It needs a daemon that records it on
  // StartSession as well as SetTimer: for a while only the latter did, which
  // left it empty for almost every session, so the panel treats an empty spec
  // as "nothing to restore" rather than as "no timer".
  property var timerState: ({ mode: "none", spec: "", unbounded: false, cycles: 0 })

  function refreshTimer() {
    // Never while the daemon is unreachable: reading an activatable name's
    // property would start one.
    if (!reachable || timerProbe.running) return
    timerProbe.running = true
  }

  Process {
    id: timerProbe
    running: false
    command: ["busctl", "--user", "--json=short", "get-property",
      "dev.marcford.bfm", "/dev/marcford/bfm",
      "dev.marcford.BrainFM1", "Timer"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (!root || Number(exitCode) !== 0) return
      try {
        const d = JSON.parse(String(stdout.text || "")).data || {}
        const pick = function (key, fallback) {
          return d[key] && d[key].data !== undefined ? d[key].data : fallback
        }
        root.timerState = {
          mode: String(pick("mode", "none")),
          spec: String(pick("spec", "")),
          unbounded: pick("unbounded", false) === true,
          cycles: Math.floor(Number(pick("cycles", 0))) || 0
        }
      } catch (e) {
        // Leave the last known value rather than inventing "no timer".
      }
    }
  }

  // ---- The optional desktop app the panel can hand off to.
  //
  // Checked once, because installing an app while the shell runs is rare and a
  // missing button is better than a button that does nothing. bfm-gtk is
  // preferred on Omarchy -- this is Hyprland, not Plasma -- with bfm-kde as the
  // fallback when that is what is installed.
  property string fullAppCommand: ""
  readonly property bool hasFullApp: fullAppCommand !== ""

  Process {
    id: fullAppProbe
    command: ["sh", "-c",
      "command -v bfm-gtk || command -v bfm-kde || true"]
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function () {
      if (!root) return
      root.fullAppCommand = String(stdout.text || "").trim().split("\n")[0].trim()
    }
  }

  function openFullApp() {
    if (fullAppCommand === "") return
    // Detached on purpose: a desktop app must not be a child of the bar, or
    // closing the shell takes it with it.
    Quickshell.execDetached([fullAppCommand])
  }

  Component.onCompleted: {
    // Before the watcher: it needs no daemon and no bus, and what it reports
    // decides whether the MPRIS fallback does anything at all.
    capabilityProbe.running = true
    watcher.running = true
    statesProc.running = true
    fullAppProbe.running = true
  }

  // Stop the child explicitly when the shell tears this plugin down. Quickshell
  // reaps a destroyed Process's child, but doing it here means the stream stops
  // before the parsers lose their `root`, and it keeps the teardown independent
  // of that behaviour.
  Component.onDestruction: {
    restartTimer.stop()
    staleProbeTimer.stop()
    if (watcher.running) watcher.running = false
  }
}
