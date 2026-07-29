# RSS/Atom Notifier

Monitor RSS/Atom feeds and get notifications for new items.

## Plugin

**Id:** `nilsonlinux/rss-notifier`

**Entries:**
- **Service:** `fetcher` - Background service that fetches and parses feeds
- **Widget:** `badge` - Shows unread count on the bar
- **Panel:** `list` - Displays feed items in a list

**IPC Command:**

## Usage

1. Add feed URLs in the plugin settings
2. The widget will show a badge with unread count
3. Click the widget to open the panel
4. Click items to mark them as read

## Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `feed_urls` | string_list | `[]` | List of RSS/Atom feed URLs to monitor |
| `refresh_minutes` | int | `30` | How often to check for new items |
| `notify_new` | bool | `true` | Display notifications when new items arrive |
| `max_notifications_per_cycle` | int | `5` | Maximum notifications shown per check |

