# Custom Shortcut

Add a custom centrol center tile. Choose the label, icon and command launched when clicked.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yocraft/custom-shortcut` |
| Entries | Shortcut: `shortcut` |

## Usage

Add the shortcut to your control center and configure it in the plugin settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `label` | `string` | `Custom` | Text of the control center shortcut. |
| `icon` | `glyph` | `question-mark` | Icon of the control center shortcut. |
| `onclick_cmd` | `string` | `notify-send "Custom Shortcut"` | Command executed when the shortcut is clicked. |

## Notes

The shortcut need a noctalia restart to appear.
