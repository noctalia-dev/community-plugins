# Keychron Battery

Shows the battery level of Keychron mice in the bar and sends a notification
when it runs low. The entry uses the bar's own colors and turns red at the
notification threshold.

## Plugin

| Field | Value |
| --- | --- |
| ID | `dmopp/keychron-battery` |
| Entries | Bar widget: `keychron-battery`; panel: `panel`; service: `service` |

## Requirements

- `upower` on `PATH`. The plugin reads all battery data from `upower --dump`.
- For a mouse on a Keychron receiver or USB cable: the
  [keychron-battery-dkms](https://github.com/csutcliff/keychron-battery-dkms)
  kernel module. Keychron mice do not report their battery over standard HID;
  the module queries it and exposes it as `/sys/class/power_supply/keychron_mouse`,
  which UPower picks up. Check it with
  `cat /sys/class/power_supply/keychron_mouse/capacity`.
- Keychron mice over Bluetooth work without the module (standard BLE battery
  service).

## Usage

Add the bar widget `dmopp/keychron-battery:keychron-battery` to a bar in
Settings. It shows a mouse icon and the battery percentage. When no battery
level comes in, it stays in the bar with a crossed-out mouse, `--` and the error
color, and the tooltip says what is missing; meanwhile the service reads UPower
every 30 seconds so the level is back soon. Hover it for name and connection;
left-click opens the panel with a battery bar per mouse and a refresh button.

```sh
noctalia msg panel-toggle dmopp/keychron-battery:panel
```

When the level drops to the notification threshold, the service sends one
notification, and an urgent one at the critical threshold. Both re-arm after the
mouse charges or climbs back 5% above the threshold.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `low_threshold` | `int` | `20` | Percent at which a notification is sent and the bar entry turns red (5–50). |
| `critical_threshold` | `int` | `10` | Percent for a second, urgent notification (1–30). |
| `notify` | `bool` | `true` | Send the low and critical notifications. |
| `poll_interval` | `int` | `60` | Seconds between UPower reads (10–900); at most 30 while no battery level comes in. The kernel module itself refreshes every 5 minutes. |
| `mouse_name` | `string` | empty | Name shown in tooltip, panel and notifications. Empty uses the UPower model name. |

## IPC

Re-read UPower immediately:

```sh
noctalia msg plugin dmopp/keychron-battery:service all refresh
```

## Notes

- The plugin only spawns `upower --dump`. It makes no network calls and writes
  no files.
- Supported over receiver or cable: whatever the kernel module binds to,
  currently the Ultra-Link 8K receiver (`3434:d028`) and the wired M5
  (`3434:d048`). The model name comes from the module and can be generic
  (for example "Keychron Ultra-Link 8K"), so set `mouse_name` for a nicer one.
- With keychron-battery-dkms 0.1.3, the receiver stops reporting the battery
  after the mouse was on the cable, until the receiver is replugged
  ([keychron-battery-dkms#5](https://github.com/csutcliff/keychron-battery-dkms/issues/5)).
  The bar entry then shows the error state instead of disappearing.
- Keychron keyboards are not shown: over the Keychron Link 2.4G receiver their
  firmware does not report a battery level at all.
