# undershell

Controls [undershell](https://github.com/EternalSelf-2328/undershell)'s desktop
widgets (audio visualizers, clocks, a now-playing card that can pass behind the
wallpaper's subject) from the bar. You can toggle the editor, set depth planes and
tilt, and save or load layouts per wallpaper and per monitor.

## Plugin

| Field | Value |
| --- | --- |
| ID | `eternalself-2328/undershell` |
| Entries | Bar widget: `bar`; panel: `panel` |

## Requirements

- `undershell`, the desktop widgets daemon, from
  <https://github.com/EternalSelf-2328/undershell>. The plugin looks for it at
  `~/.local/bin/undershell` first, then on `PATH`.
- `systemctl` (systemd), with undershell's **user service** `undershell.service`
  installed. undershell's install puts the unit in place; enable it with
  `systemctl --user enable --now undershell`. The panel's **Start undershell**
  button runs `systemctl --user start undershell.service`.

You need a Wayland compositor with `wlr-layer-shell`. Depth (widgets passing behind
the wallpaper's subject) comes from Noctalia's official `wallpaper_depth`
plugin.

## Usage

Add the **undershell** widget to a bar in Settings → Bar.

- **Left click** opens the panel.
- **Right click** turns undershell's on-screen editor on or off: drag, resize,
  rotate and style the widgets on the desktop.

The panel shows whether undershell is running (with a button to start it) and
the layout of the current wallpaper. For each widget it lists:

- **behind the scenery** on or off;
- the **depth plane** and the **tilt**, each applied when you release its slider;
- a pencil that opens the editor on that widget.

The **Saved profiles** section stores named copies of the layout, and can load,
overwrite or delete them. With several monitors, **Load on** chooses the monitor
a profile goes to, or **All**. Each copy is fitted to that screen's size, and the
other monitors keep their widgets.

```sh
noctalia msg panel-toggle eternalself-2328/undershell:panel
```

## Notes

- Processes the plugin spawns: `undershell msg …` (`json` and `saves` to read
  the state; `edit`, `set`, `save`, `save-load` and the like to act), and
  `systemctl --user start undershell.service` when you press **Start
  undershell** while the daemon is not running. The plugin writes no files
  itself; undershell keeps its configuration in `~/.config/undershell/`.
- No network access. undershell itself fetches synced lyrics from LRCLIB for
  the now-playing card.
