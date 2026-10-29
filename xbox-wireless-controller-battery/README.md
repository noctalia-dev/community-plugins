# Xbox Wireless Controller Battery

Shows the battery level of every connected Xbox controller in the bar and
sends a notification before a controller runs out. It reads the kernel's
power-supply entries, so it needs no UPower and no helper process.

## Plugin

| Field | Value |
| --- | --- |
| ID | `blanchedeadwood/xbox-wireless-controller-battery` |
| Entries | Bar widget: `battery` |

## Requirements

An Xbox controller whose driver reports its battery under
`/sys/class/power_supply`. This covers:

- [xpadneo](https://github.com/atar-axis/xpadneo) over Bluetooth (`xpadneo_battery_*`),
- [xone](https://github.com/dlundqvist/xone) with the Xbox Wireless Adapter (`gip*`),
- the kernel's own Bluetooth HID battery (`hid-<mac>-battery`, model name
  "Xbox Wireless Controller").

Wired controllers on the stock `xpad` driver do not report a battery.

## Usage

Add the **Xbox Wireless Controller Battery** widget
(`blanchedeadwood/xbox-wireless-controller-battery:battery`) to a bar. It appears within
two seconds of a controller connecting and hides when none is left. Hover it
for each controller's name, level and charging state. Left click re-reads the
batteries immediately.

- With several controllers the bar shows `1:80% 2:45%`, or only the emptiest
  one with `show_lowest_only`.
- Controllers that report only a coarse level (no percentage) show it as
  "Full", "High", "Normal", "Low" or "Critical".
- The entry turns red when a controller is at or below the low threshold, and
  a notification is sent once per controller. It is re-armed only after that
  controller has been charged or reconnected.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_interval` | `int` | `30` | Seconds (5–600) between battery readings. Connecting or disconnecting a controller is noticed within two seconds regardless. |
| `low_threshold` | `int` | `20` | Percentage (5–50) at or below which the entry turns red and the low notification fires. |
| `show_lowest_only` | `bool` | `false` | With several controllers, show only the emptiest one in the bar; the tooltip still lists all. |
| `match` | `string` | `xpadneo,gip,xbox` | Comma-separated, case-insensitive parts of a power-supply name or model name that mark a controller. |
| `notify_low` | `bool` | `true` | Send a notification once when a controller reaches the low threshold. |
| `notify_full` | `bool` | `false` | Send a notification once when a controller is fully charged. |
| `battery_glyph` | `bool` | `false` | Show a battery glyph with the fill level instead of the gamepad glyph. |
| `icon_only` | `bool` | `false` | Show only the battery glyph, without the percentage. The tooltip keeps the details. |

## IPC

Re-read the batteries right away:

```sh
noctalia msg plugin blanchedeadwood/xbox-wireless-controller-battery:battery all refresh
```

## Notes

- **Files read:** `/sys/class/power_supply/*/{scope,model_name}` every two
  seconds, plus `capacity`, `capacity_level` and `status` of matching entries
  on each reading. Entries with scope `System` (laptop batteries, UPS) are
  never counted.
- **Files written, processes, network:** none.
