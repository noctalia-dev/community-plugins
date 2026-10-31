# modernclock

A sleek, modern desktop clock widget for Noctalia compositors.

Inspired by KDE Modern Clock, featuring the rainwater theme “Mond”. Features the iconic geometric futuristic day title in **FN Octahedron** font, alongside clean date and time formatted in **Poppins**.

## Plugin

| Field | Value |
|---|---|
| id | `styrish/modernclock` |
| author | Styrish007 |
| license | GPL-3.0 |
| desktop_widget | `clock` |

## Usage

Add the `clock` desktop widget to your layout via the Noctalia desktop configuration or settings UI.

### Adding to Desktop

1. Open Noctalia Desktop Widget Editor:
   ```bash
   noctalia msg desktop-widgets-toggle-edit
   ```
2. Click **Add Widget** and select **Modern Clock**.
3. Position and resize the widget as desired.
4. Exit the editor (`noctalia msg desktop-widgets-exit`).

## Settings

Settings can be configured through the Noctalia Settings UI under **Plugins → Modern Clock**.

| Key | Type | Description |
|---|---|---|
| `show_day` | bool | Toggle day display |
| `day_font_size` | int | Font size for day label |
| `day_font_color` | color | Hex color for day text |
| `day_letter_spacing` | int | Letter spacing for day text |
| `show_date` | bool | Toggle date display |
| `date_font_size` | int | Font size for date label |
| `date_font_color` | color | Hex color for date text |
| `date_letter_spacing` | int | Letter spacing for date text |
| `date_format` | string | Strftime date format string |
| `show_time` | bool | Toggle time display |
| `time_font_size` | int | Font size for time label |
| `time_font_color` | color | Hex color for time text |
| `time_letter_spacing` | int | Letter spacing for time text |
| `use_24_hour_format` | bool | Use 24-hour time instead of 12-hour |
| `time_character` | string | Delimiter character between time components |

## Notes

- Plugin code is licensed under GPL-3.0 (see [LICENSE](LICENSE)).
- Bundled third-party fonts are licensed separately under the SIL Open Font License (OFL-1.1):
  - **Poppins** (`fonts/Poppins.ttf`): Copyright 2014-2019 Indian Type Foundry (see [fonts/OFL-Poppins.txt](fonts/OFL-Poppins.txt)).
  - **FN Octahedron** (`fonts/fn-octahedron-v11.otf`): Copyright 2024-2025 Fox Nóvak (see [fonts/OFL-Octahedron.txt](fonts/OFL-Octahedron.txt)).
