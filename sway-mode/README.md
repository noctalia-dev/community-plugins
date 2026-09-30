# Sway Mode

Displays the current Sway mode in the Noctalia bar and keeps it updated as the mode changes.
It can show a glyph of your choice or hide it, hide the default mode, or rename the default mode.

## Plugin

| Field   | Value                                       |
| ---     | ---                                         |
| ID      | `ismay/sway-mode`                           |
| Entries | Bar widget: `sway-mode`; service: `service` |

## Usage

Add the Sway Mode widget to your Noctalia bar.
Once added, the widget displays the current Sway mode and automatically updates whenever the mode changes.
By default, the widget is hidden while Sway is in its `default` mode. You can change this behavior in the settings.

## Requirements

Requires a running `sway` session.
The `swaymsg` command, which is included with Sway, must be available on `PATH`.
The plugin uses `swaymsg` to retrieve the current mode and subscribe to mode changes.

## Settings

| Setting          | Type     | Default                | Description                                                                               |
| ---              | ---      | ---                    | ---                                                                                       |
| `glyph`          | `glyph`  | `"square-letter-m"`    | Glyph displayed next to the current Sway mode. Leave empty to hide the glyph.             |
| `hide_default`   | `bool`   | `true`                 | Hides the widget while Sway is in its `default` mode.                                     |
| `rename_default` | `string` | `""`                   | Replaces the displayed name of the `default` mode. Leave empty to keep the original name. |

## Notes

- The widget is hidden when the service encounters an error or when no Sway mode could be retrieved. Errors will be logged to the noctalia log.
- This widget does not render pango markup, as pango markup does not map directly to the styling available in the Noctalia bar. So any pango markup will be rendered verbatim.
