# Changelog

## 1.1.0 — 2026-11-10

### Fixes
- **RFCOMM reliability:** the link is now aborted on send/read failure (socket closed, pending requests failed, one-time disconnect notification), the daemon marks `connected: false` with the real error, and reconnects honestly instead of looping on a dead socket (`Errno 107`).
- **Daemon/engine deadlock prevention:** lock ordering is enforced (engine → daemon). `save()` snapshots local engine state before taking the daemon lock, and local event handling never enters the engine while holding the daemon lock.
- **Shortcut engine:** gestures resolve with the modifiers held at gesture start, restore uses the gesture's `previous_volume`, and rule loading/updates validate structure. The volume watcher ignores events when the sink cannot be identified, and the modifier tracker retries instead of dying when `/dev/input` is unavailable.
- **Daemon/service behavior:** the service sends `configure` (poll interval, MAC, name) on every cycle and the daemon applies/logs it, so user settings take effect even if the daemon started with defaults. Expected RPC errors are reported as single-line `UserError` entries (no tracebacks).
- **UI:** updated color roles to `surface_container`/`outline_variant`, removed undefined widget variables, corrected English/Spanish translation strings, and removed the tab-switch transition (instant tab changes).
- **Shortcut toggles:** `snapshot()` now returns a fresh shortcut-engine snapshot instead of the copy cached in `self.state`, which only refreshed on the monitor tick. The panel polls `status` twice a second and re-seeded its rule list from that stale copy, so every toggle flipped back about half a second after the click.
- **`wheel_adjust`:** the setting now gates the mouse wheel on the bar widget, which is what the README always described. The panel sliders are native controls that always take the wheel, so the unsupported `wheelAdjustEnabled` property (ignored by the UI tree reconciler, and a warning in the log on every render) was removed.

### Performance
- **The panel reads `state.json` instead of asking the daemon twice a second.** Every request is a `python3 budsctl.py rpc` process (~100 ms of interpreter start-up), so the open panel kept an interpreter busy about a quarter of the time. The daemon already publishes the same state in `state.json` (including the shortcut snapshot and the volume, which the monitor now writes whenever it changes), so the ticks read that file and a real round trip is kept every 5 s as a safety net (it forces the volume read and it is the only way to receive an error the file cannot carry). An unchanged state does not redraw the panel.
- **The bar widget only redraws when the published state changed** (it was rebuilding its node tree once a second for the same values).
- **The service only sends `configure` when it is needed:** the round compares the payload and the `daemon_pid` the daemon reports, instead of spawning a process every 20 s to send values it already had.
- **The RPC client does not import the daemon-only modules:** `local_actions`, `subprocess` and `traceback` are imported on first use, which takes about 50 ms out of every call.

### Compatibility
- Bumped `plugin_api` to `43` and plugin `version` to `1.1.0`.
- **The daemon runs on Python 3.8 or newer.** The RPC server was built with `socketserver.ThreadingUnixStreamServer`, a class that only exists from Python 3.12: on Debian 12 (3.11) or Ubuntu 22.04 (3.10) the daemon died at start-up with an `AttributeError` and the plugin appeared to do nothing. The same class is now assembled from `ThreadingMixIn` and `UnixStreamServer` when the interpreter does not have it, and the syntax of both Python files is checked against 3.8 in the test suite.
- Declared every external command the plugin runs: `python3`, `bluetoothctl`, `pactl`, `hyprctl`, `notify-send` and `dbus-monitor` (the last three are optional and degrade gracefully).

### Verification
- Python suites pass: `bin/test_local_actions.py` (161 checks), `bin/test_connect.py` (5 checks), `bin/test_snapshot.py` (5 checks, covers the stale `local_actions` regression), `bin/test_panel_fixes.py` (18 tests) and `bin/test_luau_fixes.py` (25 tests, including the panel/widget/service round trips and the lazy imports of the CLI).
- Measured on the real plugin: with the panel open, the daemon requests dropped from ~2 per second to 1 every 5 s; with the panel closed, idle traffic is the service ping every 20 s.
- Official plugin validator passes for the isolated `cmf-buds` plugin.
- `luac5.4 -p` and `py_compile` pass for plugin sources.
