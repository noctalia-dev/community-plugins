# iio-lock

iio-lock provides orientation controls for 2-in-1 devices, allowing automatic
screen rotation to be locked and manual output transforms to be selected.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nikolaj-zwergius/iio_lock` |
| Entries | Bar widgets: `iio-lock`, `lock-panel`; panel: `panel`; shortcut: `toggle`; service: `iio-service` |

## Requirements

The plugin supports Hyprland with `iio-hyprland` and `hyprctl`. Sway support
uses `iio-sway` and `swaymsg` and is currently experimental. The helper
commands `pgrep` and `pkill` must also be available on `PATH`.

## Usage

Add the `iio-lock` widget to toggle the orientation lock with a left click and
open the transform panel with a right click. The `lock-panel` widget opens the
transform panel with a left click. You can also add the `toggle` shortcut under
Settings → Control Center shortcuts.

Open the transform panel directly with:

```sh
noctalia msg panel-toggle nikolaj-zwergius/iio_lock:panel
```

Locking stops the configured IIO rotation helper; unlocking starts it again.
The panel applies the selected transform to the chosen output.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `iio` | `select` | `iio-hyprland` | Automatic rotation helper to start and stop. |
| `transform-order` | `string` | `0,1,2,3` | Transform values shown by the panel, in order. |
| `vm` | `select` | `hyprland` | Selects the Hyprland or Sway command backend. |
| `locked` | `glyph` | `lock` | Glyph used while orientation is locked. |
| `unlocked` | `glyph` | `lock-open-2` | Glyph used while orientation is unlocked. |

## Notes

Hyprland is the tested backend. Verify the configured rotation helper works on
its own before using the plugin, especially on Sway and similar compositors.
