# LOQ RGB

Control the RGB lighting of Lenovo LOQ keyboards and other keyboards that expose the standard
**HID LampArray** interface (the Windows "Dynamic Lighting" standard; tested on a LOQ 17IRX10 with the
ITE 8258 controller). A drop-down panel offers a palette mode that follows your Noctalia theme, two- and
three-point gradients, per-zone colors and a solid color, with a live preview and smooth fades on the
keyboard. The number of zones is detected automatically.

## Plugin

| Entry | Entry id | Full id | What it is |
| --- | --- | --- | --- |
| Plugin | | `arthur/loq-rgb` | Keyboard lighting control |
| Bar widget | `rgb` | `arthur/loq-rgb:rgb` | Status icon in the bar; opens the panel |
| Panel | `panel` | `arthur/loq-rgb:panel` | Modes, live preview of every zone, color editor, brightness |
| Service | `service` | `arthur/loq-rgb:service` | Keeps your profile and drives the keyboard (no UI) |

## Usage

Add the widget to a bar (use the widget picker in the settings, or edit the configuration):

```toml
[widget.loq_rgb]
type = "arthur/loq-rgb:rgb"

[bar.default]
end = ["...your widgets...", "loq_rgb"]
```

- **Left click** the widget to open the panel, **right click** to switch the lighting on or off,
  **scroll** to change the brightness.
- Open the panel from anywhere with:

```sh
noctalia msg panel-toggle arthur/loq-rgb:panel
```

Modes:

- **Palette**: colors follow your wallpaper. Choose which theme roles are used, as blocks or a smooth blend.
- **Gradient**: start color, end color and an optional middle point on any zone (three-point gradient).
- **Zones**: one color per zone; click a zone in the preview, then choose its color.
- **Solid**: one color for the whole keyboard.
- **Auto**: the keyboard's own firmware effects (they cannot be dimmed from the system).

## Requirements

- `python3` (standard library only). The plugin ships one small, readable script,
  `helper/lamparray.py`, because sending a HID feature report needs an `ioctl`, which Luau cannot do.
  Everything else is Luau.
- **Keyboard access.** Your user needs permission to talk to the keyboard's lighting interface. The plugin
  checks this by itself: when access is missing, the panel shows a banner and opens a terminal that runs
  `scripts/setup-access.sh`. The script shows the udev rule it will install, asks for confirmation, then
  uses `sudo` (or `pkexec`). This is a one-time step and relies on systemd-logind (`uaccess`).
- A keyboard exposing the HID LampArray interface. If none is found, the panel says so and can copy a short
  diagnostic (the list of HID devices) to the clipboard for a bug report.

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
- The helper reads `/sys/class/hidraw/*` to find the keyboard and talks to `/dev/hidraw*` through `ioctl`.
  It uses no CPU while idle (it waits on a file notification), sends only the lamps whose color changed, and
  hands the keyboard back to its firmware effects when the plugin stops.
- The only file written outside the plugin's data directory is the udev rule
  `/etc/udev/rules.d/70-noctalia-loq-rgb-<vid>-<pid>.rules`, and only through the setup script, after
  your confirmation. Delete it to undo.
- Keyboards with more than 32 lamps (for example per-key RGB) are grouped left to right into 32 zones.
- If the helper is killed with `SIGKILL` it cannot hand the keyboard back; restart the plugin or choose
  **Auto** to restore the firmware effects.
