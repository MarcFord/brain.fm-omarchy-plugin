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
  // `bfm status --watch --json` has two blind spots, both verified against
  // bfmd v0.1.0 on this machine rather than assumed:
  //
  //   1. A watcher that starts while no daemon is reachable prints one
  //      "unavailable" line and then stays silent forever, even once a daemon
  //      appears. It does not exit, so nothing would otherwise retry it.
  //   2. A watcher whose daemon dies mid-stream prints nothing at all and
  //      keeps running, leaving the last state on screen indefinitely. A bar
  //      built on the stream alone shows "playing" for a dead daemon.
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
    // The daemon went away and the stream will not say so (blind spot 2).
    // Report it immediately, then restart so the next line comes in-band.
    _setUnavailable("Brain.fm — daemon stopped")
    _restartWatcher(true)
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
    running: root.sessionState === "unavailable" && watcher.running
    onTriggered: root._restartWatcher(true)
  }

  Component.onCompleted: watcher.running = true

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
