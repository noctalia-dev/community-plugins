# Upbeat

Upbeat adds a bar widget that displays Swatch Internet Time, a timezone-neutral
decimal time system measured in beats and centibeats.

## Plugin

| Field | Value |
| --- | --- |
| ID | `neuro/upbeat` |
| Entry | Bar widget: `upbeat` |

## Usage

Add the `upbeat` widget from Noctalia's widget picker. The widget displays the
current Internet Time at UTC+1; hover it to see conventional local time in the
configured 12- or 24-hour format.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_centibeats` | `bool` | `true` | Shows two centibeat digits after the decimal point. |
| `beat_display` | `bool` | `false` | Appends the `.beats` label to the value. |
| `time_format_toggle` | `bool` | `false` | Uses 24-hour time instead of 12-hour time in the tooltip. |

## Notes

Internet Time is computed locally and does not contact a network service. The
widget updates more frequently when centibeats are displayed.
