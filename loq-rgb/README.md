# LOQ RGB

Control the RGB lighting of keyboards that expose the standard **HID LampArray** interface
(Lenovo LOQ and Legion models with the ITE 8258 controller, and other keyboards following the
Windows "Dynamic Lighting" standard). A drop-down panel offers a palette mode that follows your
Noctalia theme, two- and three-point gradients, per-zone colors and a solid color, with a live
preview and smooth fades on the keyboard.

## Plugin

| Entry | Type | Id |
| --- | --- | --- |
| LOQ RGB | plugin | `arthur/loq-rgb` |
| service | service | `arthur/loq-rgb:service` |
| rgb | bar widget | `arthur/loq-rgb:rgb` |
| panel | panel | `arthur/loq-rgb:panel` |

## Usage

Add the widget to a bar:

```toml
[widget.loq_rgb]
type = "arthur/loq-rgb:rgb"

[bar.default]
end = ["...your widgets...", "loq_rgb"]
```

- **Left click** the widget to open the panel, **right click** to switch the lighting on or off,
  **scroll** to change the brightness.
- The panel can also be opened with:

```sh
noctalia msg panel-toggle arthur/loq-rgb:panel
```

Modes: **Palette** (colors follow your wallpaper; choose which theme roles are used, blocks or smooth
blend), **Gradient** (start, end and an optional middle point on any zone), **Zones** (one color per
zone, click a zone in the preview), **Solid**, and **Auto** (the keyboard's own firmware effects).
The number of zones is detected automatically, so the editor adapts to your keyboard.

## Requirements

- `python3` (standard library only). The plugin ships one small, readable script,
  `helper/lamparray.py`: sending HID feature reports needs an `ioctl`, which Luau cannot do.
  Everything else is Luau.
- **Keyboard access.** Your user needs permission to talk to the keyboard's lighting interface. The
  plugin checks this itself: when access is missing, the panel shows a banner and opens a terminal that
  runs `scripts/setup-access.sh`, which shows you the udev rule it will install, asks for confirmation,
  and uses `sudo` (or `pkexec`). It is a one-time step. The rule relies on systemd-logind (`uaccess`).
- A keyboard exposing the HID LampArray interface. If none is found, the panel says so and can copy a
  short diagnostic (the list of HID devices) to the clipboard for a bug report.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Transition time (ms) | `350` | Duration of color fades on the keyboard. `0` turns fading off. |
| Show brightness next to the icon (widget) | off | Shows the brightness percentage in the bar. |

The panel opens near the widget that toggled it by default; change this under **Settings -> Plugins**.

## Notes

- No network access. Nothing leaves your machine.
- Files written in the plugin's data directory: `profile.json` (your settings), `command.txt` and
  `command.tmp` (commands to the helper), `helper.pid`.
- The helper reads `/sys/class/hidraw/*` to find the keyboard and talks to `/dev/hidraw*` through
  `ioctl`. It uses no CPU while idle (it waits on a file notification), sends only the lamps whose color
  changed, and hands the keyboard back to its firmware effects when the plugin stops.
- Very large keyboards (more than 32 lamps, for example per-key RGB) are grouped left to right into
  32 zones.
- On exit through `SIGKILL` the helper cannot hand the keyboard back; restart the plugin or use
  **Auto** mode to restore the firmware effects.
