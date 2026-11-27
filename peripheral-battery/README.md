# Peripheral Battery

Noctalia bar widget and panel that monitors battery levels of wireless peripherals reported by UPower (mice, keyboards, headsets, gamepads/controllers, and other supported devices).

Inspired by [Wireless-Device-Battery-Monitor (BatteryHub)](https://github.com/krisgfx9/Wireless-Device-Battery-Monitor), implemented for Linux/Noctalia using system battery providers (UPower) instead of Windows HID drivers.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nemanja/peripheral-battery` |
| Entries | Bar widget: `bar`, Panel: `panel`, Service: `service` |

## Usage

1. Open Noctalia Settings.
2. Go to **Bar**, add a widget, and select **Peripheral Battery** (`nemanja/peripheral-battery:bar`).
3. Click the bar widget to open the panel, or toggle it via IPC:
   ```sh
   noctalia msg panel-toggle nemanja/peripheral-battery:panel
   ```

The bar widget shows a compact summary (device count and/or lowest/exact level) with per-device tooltip details. The panel lists detected peripherals with name, kind, battery state/level, and a progress indicator, and includes refresh and settings actions.

Open plugin settings from the panel (gear button) or via:

```sh
noctalia msg settings-open-plugin nemanja/peripheral-battery
```

## What it does

- Discovers peripheral battery devices reported by **UPower** by polling `upower -d`.
- Shows **exact battery percentage** when the device reports one, plus state (discharging/charging/fully charged), and coarse battery/warning level details when available.
- Filters out internal system/line-power batteries and focuses on peripheral devices (e.g. wireless mice, keyboards, headsets/earbuds, controllers) that UPower exposes.
- Publishes a snapshot for the bar widget and panel; updates on a configurable interval and supports manual refresh.

Reported accuracy and device coverage depend on what the device/driver exposes through UPower. Some devices provide an exact percentage; others provide only a coarse level.

## Requirements

- [Noctalia Shell](https://noctalia.dev/) with plugin support.
- `upower` installed and `upowerd` running (the plugin checks for the `upower` command and reads `upower -d`). On NixOS this is commonly enabled on desktop systems.

## External commands and behavior

Declared dependencies in `plugin.toml`: `upower`.

- **Spawned processes:** the service runs `upower -d` periodically (and on refresh/config changes) via `noctalia.runAsync` to read device battery information.
- **Network calls:** none.
- **Filesystem writes:** none by the plugin code (Noctalia state is used for snapshots/settings as provided by the plugin API).

## Settings

| Setting | Type | Default | Notes |
| --- | --- | --- | --- |
| `refresh_seconds` | int | `60` | Poll interval in seconds (min 10, max 3600). |

## Files

- `plugin.toml` — manifest, settings, and entry points
- `service.luau` — polls UPower, parses peripheral devices, publishes snapshot state
- `widget.luau` — bar widget summary, tooltip, opens panel on click
- `panel.luau` — peripheral battery list, refresh, and settings access
- `translations/en.json` — settings label/description strings

## License

MIT
