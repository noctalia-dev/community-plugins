# Ping Monitor

Ping devices on your network and see at a glance which ones are reachable. Each device has its own poll interval and sound. When a device comes back online you get a notification and, optionally, a sound.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nofiltera1/ping-monitor` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

## Requirements

`ping` (iputils or equivalent) on `PATH`.

## Usage

Add the widget to a bar section as `nofiltera1/ping-monitor:bar` (for example `[widget.ping]` with `type = "nofiltera1/ping-monitor:bar"`).

- The bar icon is the primary color when every device is online, the error color when any device is offline, and neutral while checking. Hovering shows every device and its status.
- Left click opens the panel. Each device has its own card: status, last successful ping, a per-device interval (5 s to 5 min), a bell button to mute that device, a remove button, and an activity graph of the last days.
- The panel has a global Sound toggle, and an "Add device" form at the bottom (optional name and an IP or hostname).
- Right click on the bar icon mutes or unmutes sound for all devices.

```sh
noctalia msg panel-toggle nofiltera1/ping-monitor:panel
```

The device list starts empty; add devices from the panel.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `sound_enabled` | `bool` | `true` | Master switch for the "online" sound. |
| `sound_file` | `file` | `/usr/share/sounds/Oxygen-Sys-App-Positive.ogg` | Sound played when a device comes online. Falls back to a log message if the file cannot be decoded. |
| `history_days` | `int` | `14` | Number of days shown in each device's activity graph. |

## Notes

- Runs `ping -c 1 -W 2 <host>` for every device at its own interval. No other network access.
- Stores the device list and mute state (`config.json`) and a per-device history of days with at least one successful ping (`history.json`) in the plugin data directory.
- A notification (and sound, unless muted) is shown only when a device changes from offline to online after its first check.
