# Habits

A minimalist habit tracker widget and panel for Noctalia. Track daily routines with a progressive circular completion ring on the bar and manage habits in a clean, distraction-free panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mumenosman/habits` |
| Entries | Bar widget: `habits`; panel: `panel` |

## Usage

Add the `habits` widget to your bar from Noctalia Settings or your bar configuration. Click the bar widget to toggle the habit tracker panel. You can also open the panel directly or bind it in your compositor:

```sh
noctalia msg panel-toggle mumenosman/habits:panel
```

### Habits Tab
- View your daily completion percentage and ratio (e.g. `1/2`).
- Click any habit row to toggle its completion for today. Completed tasks display their icon highlighted in the primary theme color.
- Drag and drop habits via the grip handle to reorder them in the list.

### Add Tab
- Type a habit name in the input field.
- Optionally select an icon from the icon grid (or keep the default circle).
- Click **+** or press Enter to add the habit.
- Reorder existing habits using the up and down arrow buttons.
- Manage existing habits with delete buttons and confirmation.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_count` | `bool` | `true` | Show completed count ratio (e.g. `2/3`) next to the progressive ring icon on the bar. |

## Notes

- Habit completions automatically reset each calendar day at midnight based on local system date (`YYYY-MM-DD`).
- All habit data and completion history are stored locally in `habits.json` inside Noctalia's plugin data directory.
- No network requests are made; all operations are local and self-contained.
