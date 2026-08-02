# KVitals

Live CPU, RAM, GPU, temperature, fan, battery, network, and disk vitals
for the Noctalia bar, panel, and desktop. A Luau port of the KVitals
Plasma widget by yassine20011 (GPL-3.0).

## Plugin

| Field | Value |
| --- | --- |
| ID | `royalebiskut/kvitals` |
| Entries | Service: `sampler`; bar widget: `metrics`; panel: `sparkline`; desktop widget: `tile` |

## Requirements

- `cat` (coreutils) and `ip` (iproute2) on `PATH`.
- The Noctalia System Monitor service enabled for CPU, RAM, GPU, and load
  data (`[system.monitor]` in the shell config).

## Usage

1. Install the plugin from the store and enable `royalebiskut/kvitals`.
2. Add the bar widget `metrics` from the Add-widget picker.
3. Add the desktop tile `tile` from the desktop widgets editor.
4. Left-click the bar widget to open the sparkline panel.
5. Right-click the bar widget to open the settings.

Open the panel with:

```sh
noctalia msg panel-toggle royalebiskut/kvitals:sparkline
```

## Settings

Settings live under Settings -> Plugins -> KVitals.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_ms` | `int` | `1000` | Sample interval in milliseconds. |
| `temp_unit` | `select` | `c` | Celsius or Fahrenheit. |
| `net_unit` | `select` | `auto` | Unit for network rates. |
| `metric_order` | `string_list` | `cpu, ram, temp, gpu, vram, fan, battery, net, disk` | Order of the metrics in the bar, panel, and desktop tile. |
| `enabled_cpu`, `enabled_ram`, `enabled_temp`, `enabled_gpu`, `enabled_vram`, `enabled_fan`, `enabled_battery`, `enabled_net`, `enabled_disk` | `bool` | `true` | Show or hide each metric. |
| `cpu_act` / `cpu_crit`, `ram_act` / `ram_crit`, `temp_act` / `temp_crit`, `gpu_act` / `gpu_crit`, `vram_act` / `vram_crit`, `disk_act` / `disk_crit` | `int` | per metric | Activity and critical thresholds in percent. Values at the activity level tint the metric toward the accent color; critical uses the accent color fully. |
| `net_act` / `net_crit` | `double` | `1` / `50` | Network thresholds in MB/s. |
| `icon_cpu`, `icon_ram`, `icon_temp`, `icon_gpu`, `icon_vram`, `icon_fan`, `icon_net`, `icon_disk` | `select` | per metric | Icon for each metric. |
| `accent_color`, `font_color` | `color` | theme | Colors for critical values, icons, and text. |
| `show_cpu_freq`, `show_power_draw`, `show_net_ip` | `bool` | `true` / `true` / `false` | Detail toggles for CPU clock, battery power draw, and the local IP address. |

Per-instance widget settings: `display_mode` (icons, text, or both),
`font_size`, and `hide_absent`. Panel settings: `show_graphs` and
`graph_height`. Desktop tile settings: `show_glyphs` and `font_size`.

## IPC

No extra IPC events. The bar widget opens the panel on left-click and the
settings on right-click.

## Notes

- Read-only: sysfs (`/sys/class/hwmon`, `/sys/class/power_supply`, CPU
  cpufreq), `/proc/diskstats`, and the host System Monitor service.
  The plugin writes no files and makes no network calls.
- Spawns `cat` for tiny sysfs reads and `ip -j -brief addr` every
  30 seconds for the local IPv4 address (only when `show_net_ip` is
  enabled and `ip` exists).
- GPU VRAM comes from the host System Monitor (amdgpu sysfs on AMD,
  NVML on NVIDIA).
- License: GPL-3.0. Port of KVitals by yassine20011
  (https://github.com/yassine20011/kvitals).
