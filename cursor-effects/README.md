# Cursor Effects

Switch Umbriel cursor themes, cursor size, and cursor shader effects from a Noctalia
panel, without editing `~/.config/umbriel/config.toml` by hand.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h465855hgg/cursor-effects` |
| Entries | Bar widget: `cursor-effects`; panel: `panel` |

## Requirements

- `umbriel` 0.1.0 or newer on `PATH` — the panel validates the config with
  `umbriel config validate` and sends IPC messages to the running compositor.
- `python3` 3.11 or newer — the panel runs `bin/cursor_effects.py` to edit the config
  file and the selected effect manifest.

The plugin only makes sense on Umbriel.

## Usage

Add the **Cursor Effects** bar widget, or open the panel directly:

```sh
noctalia msg panel-toggle h465855hgg/cursor-effects:panel
```

The panel shows:

- **Size** — cursor size from 16 to 72 px
- **Effect radius** — radius from 32 to 256 for the selected effect
- **Theme** — every Xcursor theme found in `~/.local/share/icons`,
  `~/.icons` and `/usr/share/icons`
- **Cursor effect** — every cursor shader preset found in
  `~/.config/umbriel/shaders/community/cursor/*/effect.toml`, plus `Off`

Picking a row or releasing a slider applies the change immediately.

## Notes

Files written:

- `~/.config/umbriel/config.toml` — `[input.cursor] theme`/`size` and
  `[effects] cursor`; the chosen effect's `effect.toml` is appended to
  `[include] files` when missing.
- `~/.config/umbriel/shaders/community/cursor/<name>/effect.toml` — the `radius` of
  the selected preset. Reinstalling a community effect resets its radius.

Commands spawned:

- `umbriel config validate -c <config>`
- `umbriel msg config-reload`
- `umbriel msg effect-cursor-set <name>`

No network access.

![Panel](screenshots/panel.png)
