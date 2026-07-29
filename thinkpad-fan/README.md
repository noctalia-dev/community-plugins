# ThinkPad Fan & Thermal Control

A fan monitor and manual speed control for **Noctalia v5**, for ThinkPads using
the `thinkpad_acpi` kernel module. The bar widget shows the current fan RPM and
turns a warning color when the fans are forced off or set to a manual level.
Clicking it opens a panel to pick a fan level — no root needed at runtime.

> Ported from the Noctalia v4 (Quickshell/QML) plugin of the same name to the v5
> Luau plugin runtime.

## Plugin

Manifest id `piero-93/thinkpad-fan`. Three entries share one state snapshot (no
Lua memory is shared between them):

- `service` — headless: polls `/proc/acpi/ibm/fan` and the thermal zone, and
  performs the fan-level writes.
- `widget` — the bar widget: fan glyph + `NNNN RPM`, tinted by status. Click it
  to open the panel.
- `panel` — the control surface: a grid of fan levels (Auto, Full, 0–7). Toggle
  it from a keybind with:

  ```sh
  noctalia msg panel-toggle piero-93/thinkpad-fan:panel
  ```

## Features

- **Live RPM** in the bar, with a tooltip showing speed, level, and temperature.
- **Status coloring** — the widget turns red when the fans are forced off
  (level 0) and uses the accent color for any manual override.
- **Manual level control** — Auto, Full (disengaged), or fixed levels 0–7.
- **Temperature readout** from a configurable thermal zone.

## Setup (required)

Manual fan control needs two things, handled once by the included script:

1. the `thinkpad_acpi` module loaded with `fan_control=1`, and
2. write access to `/proc/acpi/ibm/fan`.

```sh
cd ~/Documents/Projects/community-plugins/thinkpad-fan/scripts
sudo ./setup-fan-permissions.sh
```

If the script had to enable `fan_control=1`, reboot (or reload the module) once.
Without this, the RPM/temperature readout still works, but changing the level
will fail (the panel shows a notification).

> ⚠️ Forcing the fans off (level 0) or to a fixed low level can let the machine
> overheat. Use manual levels with care; **Auto** returns control to firmware.

## Usage

Install this checkout as a development source and enable the plugin:

```sh
noctalia msg plugins source add dev path ~/Documents/Projects/community-plugins
noctalia msg plugins enable piero-93/thinkpad-fan
```

Then add the **ThinkPad Fan & Thermal Control** widget from the bar's Add-widget
picker. `.luau` edits hot-reload; `plugin.toml` changes apply on the next config
reload.

## Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| Colorize by status | bool | `true` | Tint the widget when forced off / manual |
| Left-click opens the control panel | bool | `true` | Open the panel on left-click |
| Thermal zone | string | `thermal_zone0` | sysfs thermal zone for the temperature |

## What it does to your system

For review transparency (this plugin is trusted, unsandboxed Luau):

- **Reads** `/proc/acpi/ibm/fan` and `/sys/class/thermal/<zone>/temp` (poll ~2.5 s).
- **Writes** `level <value>` to `/proc/acpi/ibm/fan` only when you pick a level in
  the panel.
- **No external commands, no network access.**

## License

GPL-3.0
