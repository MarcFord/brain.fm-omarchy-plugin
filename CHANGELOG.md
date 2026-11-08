# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- Mental states, activities and genres are read from the daemon rather than
  hardcoded, so the plugin cannot drift from the catalogue the other
  front-ends show. Activities and genres reload when the mental state changes.
- An "Open full app" button that launches `bfm-gtk`, falling back to
  `bfm-kde`, and is hidden when neither is installed. This is the only place
  the existing desktop front-end is reused, and it is reused by launching it:
  its QML is compiled into that binary and cannot be imported.
- Middle-clicking the bar item toggles pause without opening the panel.
- Settings `showTrackTitle` and `maxTitleWidth` on the bar entry.

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
- `dist/check-plugin.sh`, run in CI, covering manifest schema, entry points,
  symlinks, QML syntax, and that every external command the plugin runs is
  documented in the README.

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
