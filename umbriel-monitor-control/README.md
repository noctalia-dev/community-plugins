# Umbriel Monitor Control

Place and tune your monitors from the Noctalia bar: move a display left,
right, above or below the others, and change its resolution and refresh rate.
Every change is written into the Umbriel config file (validated before it
lands, restored if invalid) and reloaded live, so settings persist across
reboots.

**Umbriel only.** This plugin drives the Umbriel compositor through its CLI and
its config file; it does nothing under niri, Hyprland, Sway or any other
compositor, and hides its widget outside an Umbriel session.

## Plugin

| Field | Value |
| --- | --- |
| ID | `muhammadessam/umbriel-monitor-control` |
| Entries | Bar widget: `monitor`; panel: `panel`; service: `service` |

## Requirements

- An **Umbriel** session (the `umbriel` CLI and its IPC socket must be present;
  the plugin hides its widget outside Umbriel).
- `[output.*]` sections are managed in the file at the `config_path` setting
  (default `~/.config/umbriel/config.toml`).

## Usage

Add the `monitor` widget to the bar: it shows the focused output's current
mode; click opens the panel. Or open the panel directly:

```sh
noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel
```

The panel opens with an **arrangement map**: every enabled output drawn as a
rectangle where the compositor actually has it, scaled to keep its real
proportions, with a legend row per monitor (name, mode, `x, y` in logical
pixels). An output placed above another draws above it, side-by-side displays
draw in one row. The focused output's rectangle carries the thicker border.

In the panel, each monitor card has a resolution dropdown, a refresh-rate
dropdown and an Apply button, plus four placement buttons (left / right / up /
down) that dock the monitor against the outer edge of the arrangement.

Below them, a **Position** row takes the two coordinates by hand — logical
pixels, `x` then `y`, as the legend and the map show them (`mode size / scale`;
negative `y` is above the origin). Enter in either box or the crosshair button
applies them. The placement buttons stay the coarse move: press one and the
fields update to whatever it landed on.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `config_path` | `string` | `~/.config/umbriel/config.toml` | Umbriel config file the plugin patches. |
| `auto_reload` | `bool` | `true` | Reload the compositor after writing; off = persist-only. |
| `show_text` | `bool` | `true` | Bar widget shows resolution + Hz next to the glyph. |
| `glyph` | `glyph` | `device-desktop` | Bar widget icon. |

## IPC

```sh
noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel
```

## Notes

- **Files written**: the configured Umbriel config (patched `[output.*]`
  sections only; comments and other keys are preserved) and a rolling backup
  `config.toml.bak` in the plugin's data dir, used to restore if a patched file
  fails `umbriel validate` or for the revert request.
- **Commands spawned**: `umbriel outputs --json` (inventory),
  `umbriel validate -c <file>` (pre-reload gate), `umbriel msg config-reload`
  (live apply). No network access.
- Resolution/refresh options come from the modes the display advertises, so
  the dropdowns only ever offer something the monitor can do. Umbriel falls
  back to the preferred mode if a saved mode cannot be applied later.
- Placement uses logical layout coordinates (mode size divided by scale),
  matching Umbriel's own `position` semantics.
- Known limitation: `[output.*]` headers with the quoted monitor-name form are
  matched case-insensitively like Umbriel, but the plugin writes sections keyed
  by connector name (the `umbriel outputs` `name` field).
