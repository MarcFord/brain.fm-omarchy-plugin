# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Recommends brain.fm-linux-client 0.1.3 or newer, which fixes a security
  issue in `bfm login --browser`. This plugin never runs that command, but it
  points you at it for signing in.

## [0.1.0] - 2026-11-08

### Added

- Brain.fm bar item for Omarchy (`marcford.brainfm`), with a `service` entry
  point owning the connection to `bfmd` and a `bar-widget` entry point
  rendering it.
- Live session state — `idle`, `buffering`, `playing`, `paused` — with the
  current track title beside the glyph, driven by `bfm status --watch --json`
  so no polling is involved.
- An explicit unreachable state. A daemon that is not running is shown as an
  outage and dimmed, never as `idle`.
- A session panel on the bar item. Transport (pause/resume, skip, stop) while
  something is playing, and a picker to start a new session: mental state,
  activity, any number of genres, neural effect and length. `Enter` starts it,
  `Esc` closes the panel, and `omarchy-shell shell summon marcford.brainfm`
  opens it so it can be bound to a key.
- Session length in the three modes the daemon supports and the web player
  offers: open-ended, a countdown, or work/break intervals with a chosen
  repeat count — including **Endless** intervals that cycle until stopped.
  While something is playing, the chosen mode can be applied to the running
  session without restarting it.
- Feature detection on the daemon's `InterfaceVersion`, read over D-Bus
  because neither `bfm --version` nor its JSON status reports it and a daemon
  built from source still calls itself 0.1.0 while serving a newer interface.
  Endless intervals need version 6 and the option is hidden below that, since
  a missing repeat count means one cycle rather than forever and there is no
  way to fake it. A version that could not be read is treated as unknown, not
  as old.
- Mental states, activities, genres and suggested session lengths are read
  from the daemon rather than hardcoded, so the plugin cannot drift from the
  catalogue the other front-ends show. All four reload when the mental state
  changes — the suggestions are genuinely per-state, 60/90/120 minutes for
  focus against 7–9 hours for sleep, so one fixed list would be wrong for most
  states and absurd for one. `bfm list session-lengths` is newer than the
  released CLI; when it is not understood the Timer mode offers plain
  durations rather than inventing suggestions the service never made.
- An "Open full app" button that launches `bfm-gtk`, falling back to
  `bfm-kde`, and is hidden when neither is installed. This is the only place
  the existing desktop front-end is reused, and it is reused by launching it:
  its QML is compiled into that binary and cannot be imported.
- Middle-clicking the bar item toggles pause without opening the panel.
- The panel scrolls from the keyboard with the arrow keys or `k`/`j`. Its
  height is set by the daemon's catalogue — twenty genres for focus — so on a
  short screen the lower controls sit below the card, and a pointer wheel
  should not be the only way to reach them.
- The panel opens showing the timer that is actually running, read from the
  daemon rather than from whatever was last picked in the panel — so it is
  right for a timer set from the CLI, from another front-end, or before the
  shell restarted. A spec the controls cannot represent is shown verbatim and
  re-applied unchanged instead of being rounded to the nearest button.
- Settings on the bar entry: `showTrackTitle`, `maxTitleWidth`, and
  `defaultMentalState` for which mental state the panel opens on — honoured
  only if the daemon actually offers it, so a stale value falls back instead
  of selecting nothing.
- The bar shows a session as starting from the moment Start is pressed.
  Fetching a session's queue takes a few seconds, during which the daemon
  honestly reports `idle`; showing that made the Start button look like it had
  not worked. The indication comes from having issued the command, and clears
  as soon as the daemon says anything else, the command fails, or the wait
  passes thirty seconds.
- `dist/check-plugin.sh`, run in CI, covering manifest schema, entry points,
  symlinks, QML syntax, and that every external command the plugin runs is
  documented in the README.

### Fixed

- The bar item is built on `WidgetButton` rather than a bare row with its own
  `MouseArea`. `bar.showTooltip()` silently drops any target that does not
  satisfy the `tooltipHovered` contract, so the hover tooltip never actually
  appeared; `WidgetButton` also registers the item as a bar click target,
  without which a click does not reach it while a popup overlay is up.
- Losing the daemon no longer restarts the status watcher. `bfm` activates the
  service over D-Bus, so restarting on the name-lost edge started a fresh
  daemon purely because the bar was watching one. Recovery now waits for the
  name to come back, which is proof a daemon is running rather than a request
  to start one.

### Changed

- The MPRIS liveness fallback is now gated on `bfm capabilities` advertising
  `watch-follows-daemon`, rather than running unconditionally. On a CLI that
  makes that promise the stream reports the daemon appearing and disappearing
  by itself and the fallback is inert; on one that does not, or one too old to
  be asked, it stays active. Gated on the feature name rather than a version,
  because the name is what is guaranteed.

### Notes on `bfm status --watch --json`

Two behaviours of the upstream watcher shaped this plugin, both observed
against `bfmd` v0.1.0 rather than assumed:

- A watcher started while no daemon is reachable prints one `unavailable` line
  and then stays silent even after a daemon appears. It does not exit, so
  nothing would otherwise retry it.
- A watcher whose daemon dies mid-stream prints nothing at all and keeps
  running, which would leave a dead daemon displayed as whatever it was last
  doing.

Neither is a problem for a one-shot CLI reader; both are for a bar that has to
stay honest. The plugin therefore treats the MPRIS name `bfmd` owns
(`org.mpris.MediaPlayer2.bfm`, held even while idle) as its liveness signal and
re-reads the stream when that name appears or vanishes, keeping the stream
itself as the source of displayed state.
