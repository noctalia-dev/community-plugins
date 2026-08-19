# RSS/Atom Notifier

Monitor RSS/Atom feeds and get notifications for new items.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nilsonlinux/rss-notifier` |
| Entries | Bar widget: `indicator`; Panel: `Panel`|

**Entries:**
- **Service:** `fetcher` - Background service that fetches and parses feeds
- **Widget:** `badge` - Shows unread count on the bar
- **Panel:** `panel` - Displays feed items in a panel

**IPC Command:**

noctalia msg panel-toggle nilsonlinux/rss-notifier:Panel
text


## Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `feed_urls` | string_list | `[]` | List of RSS/Atom feed URLs to monitor (one per line) |
| `refresh_minutes` | int | `30` | How often to check for new items (1-1440 minutes) |
| `notify_new` | bool | `true` | Display notifications when new items arrive |
| `max_notifications_per_cycle` | int | `5` | Maximum notifications shown per check (1-50) |
| `show_feed_images` | bool | `true` | Show each item's cover image (or the site's favicon as a fallback) in the item list. |
| `glyph` (widget) | `glyph` | `rss` | Icon shown in the bar for the `status` widget. |

## Installation

Install via Noctalia Plugin Store.

## Requirements

- `xdg-open` - Required to open feed URLs in your default web browser. Usually pre-installed on most Linux distributions.

## Usage

1. Add feed URLs in the plugin settings
2. The widget will show a badge with unread count
3. Click the widget to open the panel
4. Click an item to open it in your default browser

## Dependencies

**xdg-open** 

## License

MIT
