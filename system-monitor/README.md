# System Monitor

System Monitor combines seven host metrics into one compact Noctalia bar capsule: CPU usage, CPU temperature, RAM, swap, disk usage, download rate, and upload rate. Subtle dividers separate processor, memory, storage, and network groups.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tmelik/system-monitor` |
| Entries | Bar widget: `summary` |
| License | GPL-3.0-only |

## Requirements

- No external programs or libraries.
- Noctalia v5 with plugin API 16 or newer.
- The Noctalia system monitor service must be enabled.

## Usage

1. Open Noctalia Settings.
2. Go to **Bar**, add a plugin widget, and select **System Monitor**.
3. Place the widget in the desired section of the bar.

Left-click the capsule to open the **System** tab in Control Center. Hover it to see the full metric names and values.

Middle-click the capsule to open its settings. Each metric can be shown or hidden independently. You can also toggle category separators and the detailed tooltip, choose compact or explicit network units, and change the monitored disk path. The default path is the root filesystem (`/`).

Unavailable sensors are displayed as an em dash instead of a misleading zero. Network rates are totals across active non-loopback interfaces. RAM uses a distinct server-module glyph so it is easy to tell apart from CPU at a glance.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_cpu_usage` | `bool` | `true` | Show aggregate CPU usage. |
| `show_cpu_temperature` | `bool` | `true` | Show CPU temperature when a sensor is available. |
| `show_ram` | `bool` | `true` | Show RAM utilization. |
| `show_swap` | `bool` | `true` | Show swap utilization. |
| `show_disk` | `bool` | `true` | Show utilization for `disk_path`. |
| `show_download` | `bool` | `true` | Show aggregate receive rate. |
| `show_upload` | `bool` | `true` | Show aggregate transmit rate. |
| `show_separators` | `bool` | `true` | Separate non-empty processor, memory, storage, and network groups. |
| `show_tooltip` | `bool` | `true` | Show expanded metric names and values on hover. |
| `compact_network` | `bool` | `true` | Use `M/s`-style labels; disable for `MB/s`-style labels. |
| `disk_path` | `string` | `/` | Select the filesystem whose utilization is displayed. |

## Notes

- The plugin only reads snapshots exposed by Noctalia through `systemStats()` and `diskStats()`.
- It does not access the network, execute processes, read arbitrary files, or write data.
- Values refresh according to Noctalia's system-monitor sampling intervals; the widget redraws once per second.
- If every metric is disabled, the capsule remains accessible and prompts the user to enable a metric.
