# Hyprland Submap

Add simple bar widget to show Hyprland's current submap.

## Plugin


| Field | Value |
| --- | --- |
| ID | `k4n4t4/hypr-submap` |
| Entries | Bar widget: `hypr-submap` |

## Requirements

The following utilities must be installed and available on `PATH`:
- `socat`
- `stdbuf`
- `hyprctl`
Execution within a Hyprland environment is required.

## Usage

Add the widget to the bar via the Noctalia Settings.
Clicking the widget executes `hyprctl dispatch 'hl.dsp.submap("reset")'`.

## Settings


| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `hide_when_default` | `bool` | `false` | Hides the bar widget when the current submap is default. |
| `prefix` | `string` | `""` | Add the prefix text to the submap name displayed on the widget. |
| `glyph` | `glyph` | `"keyboard"` | Specifies the glyph displayed on the widget. |


## Notes

This plugin continuously runs a background subprocess using `socat` and `stdbuf` to monitor Hyprland's IPC socket for submap changes.
