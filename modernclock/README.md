# Modern Clock

A sleek, configurable desktop clock widget for Noctalia compositors. It provides a highly customizable digital clock that can be placed anywhere on the desktop using the widget editor.

## Plugin

| Field | Value |
|---|---|
| **ID** | `styrish/modernclock` |
| **Entries** | Desktop widget: `clock` |
| **Launcher Prefix** | None |

## Usage

Add the `clock` desktop widget through the Noctalia Desktop Widget Editor.

## Settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `show_day` | `bool` | `true` | Show or hide the day label. |
| `day_font_size` | `int` | `72` | Font size (pt) for the day label. |
| `day_font_color` | `color` | `#FFFFFF` | Hex color of the day text. |
| `day_letter_spacing` | `int` | `2` | Letter spacing for the day label. |
| `show_date` | `bool` | `true` | Show or hide the date label. |
| `date_font_size` | `int` | `19` | Font size (pt) for the date label. |
| `date_font_color` | `color` | `#FFFFFF` | Hex color of the date text. |
| `date_letter_spacing` | `int` | `1` | Letter spacing for the date label. |
| `date_format` | `string` | `%d %b %Y` | `strftime` format string for the date. |
| `show_time` | `bool` | `true` | Show or hide the time label. |
| `time_font_size` | `int` | `19` | Font size (pt) for the time label. |
| `time_font_color` | `color` | `#FFFFFF` | Hex color of the time text. |
| `time_letter_spacing` | `int` | `1` | Letter spacing for the time label. |
| `use_24_hour_format` | `bool` | `false` | Use 24-hour (`true`) or 12-hour (`false`) time format. |
| `time_character` | `string` | `-` | Delimiter character between hour, minute, and second. |

## Notes

- No external dependencies are required.
- Runs entirely inside Noctalia's Luau VM.
- Fonts, colors, sizes, and visibility can be customized through the plugin settings UI.
