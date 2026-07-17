# Cloudflare WARP

Plugin to check and toggle Cloudflare WARP connection and Client from a bar widget or the control center, so is not needed to keep the official and heavy warp-taskbar running all the time just for visual feedback.

## Plugin

| Field | Value |
| --- | --- |
| ID | `aurora-kid/cloudflare-warp` |
| Entries | Bar widget: `warp_widget`; service: `warp_service` | shortcut: `warp_shortcut` |

## Requirements

- [WARP Setup](https://developers.cloudflare.com/warp-client/get-started/linux/)
- Install `cloudflare-warp` package (`cloudflare-warp-bin` in some distros).
- Ensure `warp-svc` service is enabled and `warp-cli` is available on `PATH`.
- `warp-taskbar` is optional

## Usage

The `warp_service` runs upon plugin activation, checking every `update_interval` seconds for connection state through `warp-cli status` command. If `notify_state` is enabled a notification will be sent on every connection change detected. `warp_widget` can be added to bars, and its `glyph` icon changed. Simpler `warp_shortcut` can be set to the control center panel. Left click on any of both, widget or shortcut, toggles the connection, right click on widget toggles the Client UI (launch or terminate `warp-taskbar`) if available.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `update_interval` | `int` | `5` | Update interval, in seconds, between connection status checks. |
| `notify_state` | `bool` | `false` | Send a notification on every connection change detected. |
| `glyph` | `glyph` | `brand-cloudflare` | Glyph shown by bar widget instance. |

## Notes

- The Client toggle is really basic and executes `pkill -15 warp-taskbar` if is already running (no matter the window state, hidden to it's tray or not) and `warp-taskbar --show` if noctalia doesn't find a running process match.
- This plugin does not perform further checks on the connection, just if connected, disconnected, connecting or error. By the moment the connection mode or if the `warp-svc` does have proper setup is not handled.
