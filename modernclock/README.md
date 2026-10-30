- # Modern Clock for Noctalia
+ # modernclock

- ## Plugin
+ ## Plugin

- | id | styrish/modernclock |
+ | id | `styrish/modernclock` |

- | author | Styrish007 |
+ | author | Styrish007 |
+ | desktop_widget | `clock` |

+ ## Usage
+ Add the `clock` desktop widget to your layout via the Noctalia desktop configuration or settings UI.
+ 
+ ### Adding to Desktop
+ 1. Open Noctalia Desktop Widget Editor:
+ ```bash
+ noctalia msg desktop-widgets-toggle-edit
+ ```
+ 2. Click **Add Widget** and select **Modern Clock**.
+ 3. Position and resize the widget as desired.
+ 4. Exit the editor (`noctalia msg desktop-widgets-exit`).

+ ## Settings
+ Settings are configurable through the Noctalia Settings UI under **Plugins → Modern Clock**.
+ 
+ | Key | Type | Description |
+ |---|---|---|
+ | `show_day` | bool | Toggle day display |
+ | `day_font_size` | int | Font size for day label |
+ | `day_font_color` | color | Hex color for day text |
+ | `day_letter_spacing` | int | Letter spacing for day text |
+ | `show_date` | bool | Toggle date display |
+ | `date_font_size` | int | Font size for date label |
+ | `date_font_color` | color | Hex color for date text |
+ | `date_letter_spacing` | int | Letter spacing for date text |
+ | `date_format` | string | Strftime date format string |
+ | `show_time` | bool | Toggle time display |
+ | `time_font_size` | int | Font size for time label |
+ | `time_font_color` | color | Hex color for time text |
+ | `time_letter_spacing` | int | Letter spacing for time text |
+ | `use_24_hour_format` | bool | Use 24‑hour time instead of 12‑hour |
+ | `time_character` | string | Delimiter character between time components |
