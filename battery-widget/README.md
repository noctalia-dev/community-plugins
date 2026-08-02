# Battery Widget

Desktop/lockscreen widget that displays the current battery level and charging status.

## Plugin

| Field | Value |
| --- | --- |
| ID | `yocraft/battery-widget` |
| Entries | Desktop widget: `widget` |

## Usage

Add it to your desktop/lockscreen widgets using the widget editor. You can configure it in the widget settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `layout` | `select` | `horizontal` | Layout of the widget. |
| `show_glyph` | `bool` | `true` | Show the battery icon. |
| `show_label` | `bool` | `true` | Show text next to the icon. |
| `hide_plugged` | `bool` | `false` | Hide the battery widget when connected to AC power. |
| `hide_full` | `bool` | `false` | Hide the battery widget when fully charged. |
| `color` | `color` | `on_surface` | Color role for this widget's icon and label; fixed hex colors are also supported. |
| `warning_color` | `color` | `error` | Color applied when charge is at or below warning threshold. |
| `charging_color` | `color` | `on_surface` | Color applied when connected to AC power. |
| `battery` | `select` | `auto` | Detect the battery automatically or set a custom name. |
| `battery_name` | `string` | `BAT0` | Set a custom name for the battery. |
| `refresh_interval` | `int` | `60` | Controls how frequently the widget updates its content. (in seconds) |

## Notes

`hide_full` and `hide_plugged` do not hide the background due to plugin limitations.
The warning threshold is pulled from noctalia's settings.
