# Sway Scratchpad

Displays the number of windows currently in the Sway scratchpad in the Noctalia bar and keeps it updated as the scratchpad changes.
It can show different glyphs and colors depending on whether the scratchpad is empty or populated, hide the count, or hide the widget when the scratchpad is empty.

## Plugin

| Field   | Value                                             |
| ---     | ---                                               |
| ID      | `ismay/sway-scratchpad`                           |
| Entries | Bar widget: `sway-scratchpad`; service: `service` |

## Usage

Add the Sway Scratchpad widget to your Noctalia bar.
Once added, the widget displays the current number of windows in the Sway scratchpad and automatically updates whenever the scratchpad changes.

## Requirements

Requires a running `sway` session.
The `swaymsg` command, which is included with Sway, must be available on `PATH`.
The plugin uses `swaymsg` to retrieve the Sway tree and subscribe to window changes.

## Settings

## Settings

| Setting            | Type     | Default            | Description                                                                          |
| ---                | ---      | ---                | ---                                                                                  |
| `hide_count`       | `bool`   | `false`            | Hides the number of windows in the scratchpad.                                       |
| `hide_empty`       | `bool`   | `false`            | Hides the widget when the scratchpad is empty.                                       |
| `empty_glyph`      | `glyph`  | `"archive"`        | Glyph displayed when the scratchpad is empty. Leave empty to hide the glyph.         |
| `empty_color`      | `color`  | `"on_surface"`     | Color used when the scratchpad is empty.                                             |
| `populated_glyph`  | `glyph`  | `"archive-filled"` | Glyph displayed when the scratchpad contains windows. Leave empty to hide the glyph. |
| `populated_color`  | `color`  | `"primary"`        | Color used when the scratchpad contains windows.                                     |

## Notes

- The widget is hidden when the service encounters an error or when no scratchpad count could be retrieved. Errors will be logged to the noctalia log.
