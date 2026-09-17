# Umbriel Displays

Set resolution, refresh rate, scale, workspace floor and arrangement for every
connected display, from the bar widget or an IPC command. Umbriel configures
outputs from its config file, so this plugin owns a file that the config
includes: a change applies live and is already persistent, with nothing to save.

## Plugin

| Field | Value |
| --- | --- |
| ID | `prponkshe/umbriel-displays` |
| Entries | Bar widget: `bar`; panels: `panel`, `arrange`, `advanced`; service: `watchdog` |

## Requirements

- [Umbriel](https://github.com/noctalia-dev/umbriel), with `umbriel` on `PATH`.
- Two minutes of setup below, done once.

## Install

**1.** Enable the plugin, from the plugin store, with:

```sh
noctalia msg plugins enable prponkshe/umbriel-displays
```

or in `~/.config/noctalia/noctalia.toml`, alongside its settings:

```toml
[plugins]
enabled = ["prponkshe/umbriel-displays"]

[plugin_settings."prponkshe/umbriel-displays"]
outputs_path = "~/.config/umbriel/outputs.toml"   # the default; change to move the file
```

**2.** Paste this into `~/.config/umbriel/config.toml`:

```toml
[include]
files = ["outputs.toml"]
```

**3.** Move any `[output.*]` sections out of `config.toml` and into
`~/.config/umbriel/outputs.toml`. One left behind overrides the include and wins
silently.

```toml
[output."Acer Technologies KA242Y P6 1605181FF3W01"]
mode = "1920x1080@143.997"
position = [1920, 0]
scale = 1.0
min_workspaces = 3

[output.eDP-1]
mode = "1920x1200@60.003"
position = [0, 0]
scale = 1.0
```

`umbriel outputs` prints the `Config name` for each display; use the connector,
`eDP-1` above, for one that reports no serial. The file is created on the first
change if you have nothing to move.

Done. The plugin owns `outputs.toml` from here, and there is no output config
left to edit by hand.

**Optional.** To open a panel from the keyboard, bind its command from Usage
below under `[keybinds]` in your Umbriel config. The plugin ships no binding of
its own and claims no chord.

## Usage

The bar widget opens the display panel on left click and the arrangement window
on right click. Both panels also answer IPC:

```sh
noctalia msg panel-toggle prponkshe/umbriel-displays:panel
noctalia msg panel-toggle prponkshe/umbriel-displays:arrange
noctalia msg panel-toggle prponkshe/umbriel-displays:advanced
```

**`panel`** lists the connected displays as tiles. Picking one shows its make and
model, its current mode, and a switch to turn it off, then the controls for that
display: minimum workspaces, resolution, refresh rate and scale. Every change is
written and applied immediately.

**`advanced`** holds the rest of what an `[output.*]` section accepts: rotation,
adaptive sync, HDR and its SDR reference white, tearing, direct scanout, the
workspace inventory and axis, and the initial scrolling column width. Escape
returns to the main panel, as it does from the arrangement.

**`arrange`** draws each enabled display to scale. Drag one onto:

- **another display** to trade their places;
- a **slot between or beside** displays to insert it there;
- the **full-width slots** above and below a row to put it on a new row;
- the **tray** at the bottom to turn it off, and drag it back out to restore it.

Displays always land edge to edge, so an arrangement cannot leave an overlap or
a gap. The canvas is a fixed frame: displays shrink to fit however many there
are, rather than the window growing.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `outputs_path` | `string` | `~/.config/umbriel/outputs.toml` | The file the plugin writes `[output.*]` sections into. It must be listed in the Umbriel config's `[include] files`. |
| `glyph` | `glyph` | `device-desktop` | Icon for the bar widget. |

## Notes

- **Files written.** Only the file named by `outputs_path`. Sections are
  rewritten in place, and keys the plugin does not manage are preserved.
- **Keyed to the display, not the port.** A section is named
  `<make> <model> <serial>`, with `Unknown` filling any field the display leaves
  blank, which is the form Umbriel matches. Settings then follow the monitor
  across ports, which is what a docking station needs: it can hand the same
  monitor a different `DP-n` on every plug. The connector is used only when a
  display reports no make, model or serial at all, or when two displays report
  the same three and would answer to one name while both are attached. A section
  found under a connector moves to the monitor name on the next write, carrying
  its settings.
- **Processes spawned.** `umbriel outputs --json` on panel open, on Refresh and
  on a hotplug event, and `umbriel validate` once per change. There is no
  polling and no network access.
- **Nothing lands unvalidated.** A change is written to a candidate file beside
  the target and handed to `umbriel validate` first; only a config the running
  compositor accepts is renamed into place. A key your Umbriel is too old for is
  named back to you and the live file is left alone, so the plugin stays usable
  on an older build than the one it was written against.
- **Never dark.** The `watchdog` service takes `onOutputsChanged`. If no
  connected display is enabled, which happens when you turn one off and then
  unplug the other, it turns the best survivor back on, preferring the internal
  panel. It also relays out the arrangement whenever a display returns, since
  the returning display would otherwise reclaim a position the others have since
  been packed into and the two would overlap. Both surfaces refuse to turn off
  the last enabled display.
- **Limitations.** No mirroring: Umbriel cannot clone an output. The arrangement
  is edge to edge only, so a deliberate pixel offset between two displays has to
  be written by hand. Positions are normalised so the top-left of the
  arrangement sits at `0, 0`; Umbriel accepts negative coordinates, but the
  origin carries no meaning, so a hand-written negative layout is rewritten to
  the equivalent one. Disabling an output is a config decision by design, since
  Umbriel rejects protocol requests that disable one.
