# Wi-Fi Hotspot

Start and stop a NetworkManager Wi-Fi hotspot from the bar, inspect connected
devices in a panel, and control the service over IPC.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cleboost/hotspot` |
| Entries | Bar widget: `toggle`; panel: `panel`; service: `hotspot` |

## Requirements

Install `nmcli` from NetworkManager, plus `iw` and `ip` from iproute2, on
`PATH`. The active user must be allowed to manage NetworkManager connections
(the default on most desktop setups).

## Usage

1. Open the plugin settings and set the hotspot name and password.
2. Add the `toggle` widget to a bar.
3. Left-click the widget to open the panel with the connected device list.
4. Right-click the widget to start or stop the hotspot.

```sh
noctalia msg panel-toggle cleboost/hotspot:panel
```

Starting a hotspot may disconnect the Wi-Fi adapter from its current network
while the access point is active.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `ssid` | `string` | `Noctalia Hotspot` | Network name broadcast to clients. |
| `password` | `string` | *(empty)* | WPA password. Must be at least 8 characters before starting. |
| `interface` | `string` | *(empty)* | Optional Wi-Fi interface such as `wlan0`. Auto-detected when empty. |
| `refresh_interval` | `int` | `5` | Seconds between status and client-list refreshes. |

## IPC

```sh
noctalia msg plugin cleboost/hotspot:hotspot all enable
noctalia msg plugin cleboost/hotspot:hotspot all disable
noctalia msg plugin cleboost/hotspot:hotspot all toggle
noctalia msg plugin cleboost/hotspot:hotspot all refresh
```

The `enable`, `disable`, and `toggle` events change the hotspot state.
`refresh` and `status` re-read NetworkManager without changing it. IPC events
take no payload.

## Notes

- The plugin uses `nmcli device wifi hotspot` to create the access point and
  `nmcli connection down` to stop the active AP profile.
- Connected devices are discovered with `iw station dump` and `ip neigh`.
- The plugin makes no network requests and writes no user content to disk.
- Notifications use the host `notification-show` IPC with Wi-Fi glyphs (`wifi`,
  `wifi-off`, `alert-circle`) because `noctalia.notify()` does not accept a
  custom icon yet.
- Hotspots started outside Noctalia are detected when NetworkManager reports an
  active `802-11-wireless` connection in `ap` mode.
