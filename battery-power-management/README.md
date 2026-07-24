# Battery & Power Management

A battery status widget and control panel for **Noctalia v5**. The bar widget
shows charge percentage, live power draw in watts, and the active power profile.
Clicking it opens a panel to switch the system power profile and set the battery
charge-stop threshold — no root needed at runtime.

> Ported from the Noctalia v4 (Quickshell/QML) plugin of the same name to the v5
> Luau plugin runtime.

## Plugin

Manifest id `piero-93/battery-power-management`. It ships three entries that
share one state snapshot (no Lua memory is shared between them):

- `service` — the headless entry: polls the battery, power profile, and charge
  threshold, and performs every system read/write.
- `widget` — the bar widget: battery glyph, `NN% ±W.W`, and an optional profile
  glyph. Click it to open the panel.
- `panel` — the control surface: power-profile switch and charge-limit slider.
  Toggle it from a keybind with:

  ```sh
  noctalia msg panel-toggle piero-93/battery-power-management:panel
  ```

## Features

- **Live bar widget** — battery glyph, `NN% ±W.W`, and an optional profile glyph
  (leaf / scale / gauge), tinted by charge and profile state.
- **Power profiles** — one-tap switch between Power-saver / Balanced / Performance
  via `powerprofilesctl`.
- **Charge threshold** — a slider to cap charging (50–100%) on hardware that
  exposes `charge_control_end_threshold` (ThinkPad, ASUS, and others).
- **Time remaining** — time-to-empty / time-to-full via `upower`.

## Requirements

| Tool | Used for | If missing |
|------|----------|------------|
| `powerprofilesctl` | read/set power profile | profile controls are hidden |
| `upower` | time-to-empty/full | time remaining is hidden (watts shown instead) |

`powerprofilesctl` ships with
[power-profiles-daemon](https://gitlab.freedesktop.org/upower/power-profiles-daemon);
`upower` is packaged as `upower` on every major distro.

The charge-threshold slider additionally needs the sysfs attribute
`charge_control_end_threshold` to be present **and writable by your user** — see
Usage.

## Usage

Install this checkout as a development source and enable the plugin:

```sh
noctalia msg plugins source add dev path ~/Documents/Projects/community-plugins
noctalia msg plugins enable piero-93/battery-power-management
```

Then add the **Battery & Power Management** widget from the bar's Add-widget
picker. `.luau` edits hot-reload; `plugin.toml` changes apply on the next config
reload.

**Charge-threshold permissions (optional).** Writing the charge limit needs
write access to a root-owned sysfs file. The included script sets that up once,
without giving the plugin root at runtime:

```sh
cd ~/Documents/Projects/community-plugins/battery-power-management/scripts
sudo ./setup-threshold-permissions.sh BAT0     # use your battery, e.g. BAT1
```

Then **log out and back in**. If you skip this, everything else still works; only
the threshold slider is affected (it shows a notification on write failure).

## Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Colorize by profile | bool | `true` | Tint the widget by active profile |
| Power-saver color | color | `secondary` | Accent for the Power-saver profile |
| Performance color | color | `error` | Accent for the Performance profile |
| Show profile icon | bool | `true` | Show the profile glyph in the widget |
| Show balanced icon | bool | `false` | Also show the glyph on Balanced |
| Battery device | string | `BAT0` | sysfs battery name (`BAT0`, `BAT1`, …) |

## What it does to your system

For review transparency (this plugin is trusted, unsandboxed Luau):

- **Reads** `/sys/class/power_supply/<device>/uevent` and
  `/sys/class/power_supply/<device>/charge_control_end_threshold` (poll ~2 s).
- **Runs** `powerprofilesctl get` / `powerprofilesctl set <profile>` and
  `upower -i /org/freedesktop/UPower/devices/battery_<device>`.
- **Writes** `<threshold> > /sys/class/power_supply/<device>/charge_control_end_threshold`
  only when you move the slider (guarded by `commandExists` and permissions).
- **No network access.**

## License

GPL-3.0
