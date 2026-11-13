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

### Compatibility
- Bumped `plugin_api` to `43` and plugin `version` to `1.1.0`.
- Declared every external command the plugin runs: `python3`, `bluetoothctl`, `pactl`, `hyprctl` and `notify-send` (the last two are optional and degrade gracefully).

### Verification
- Python suites pass: `bin/test_local_actions.py` (161 checks), `bin/test_connect.py` (5 checks) and the new `bin/test_snapshot.py` (5 checks, covers the stale `local_actions` regression).
- Official plugin validator passes for the isolated `cmf-buds` plugin.
- `luac5.4 -p` and `py_compile` pass for plugin sources.
