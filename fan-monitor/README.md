# Fan Speed Monitor

A lightweight, reliable hardware fan monitor widget for Noctalia Shell. It dynamically detects laptop fan sensors across Linux hwmon drivers (including Dell, Lenovo ThinkPad, ASUS, HP, and generic motherboard sensors).

## Plugin

| Field | Value |
| --- | --- |
| ID | `muhamm-ad-ahmad/fan-monitor` |
| Entries | Bar widget: `fan_speed`; service: `service` |

## Usage

Add the fan monitor widget to your bar:

1. Open Noctalia settings (`noctalia msg settings-open`).
2. Navigate to **Bar** settings.
3. Click **Add Widget** and choose **Fan Speed Monitor**.
4. Place the widget in your bar or within a capsule group.

Alternatively, configure the widget directly in `~/.config/noctalia/config.toml`:

```toml
[widget.fan_speed]
type = "muhamm-ad-ahmad/fan-monitor:fan_speed"
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_interval_ms` | `int` | `2000` | Sensor polling interval in milliseconds. |
| `show_label` | `bool` | `true` | Show fan RPM text next to the fan icon. |
| `show_unit` | `bool` | `true` | Append RPM unit to the display text. |
| `colorize_by_speed` | `bool` | `true` | Tint icon based on fan speed load. |
| `high_rpm_threshold` | `int` | `4000` | RPM threshold for alert/warning color. |

## IPC

To trigger an immediate fan sensor refresh from a script or keybind:

```sh
noctalia msg plugin muhamm-ad-ahmad/fan-monitor:service all refresh
```

## Notes

- Uses non-blocking asynchronous reads of `/sys/class/hwmon` and `/proc/acpi/ibm/fan`.
- Works on any Linux machine where the kernel exposes fan inputs (`fan*_input`).
- Created by Antigravity AI.
