# Vidi

Latest videos from [vidi](https://github.com/Fel-2/Vidi)'s subscription feed, right in your
Noctalia bar — an unread badge plus a panel with the newest uploads, thumbnails included.

## Plugin

| Field | Value |
| --- | --- |
| ID | `fel/vidi` |
| Entries | Bar widget: `latest`; panel: `feed` |
| Launcher Prefix | none |

## Requirements

Install `vidi` (≥ 0.5.0) and `jq` on `PATH`. The widget reads vidi's feed cache
(`~/.cache/vidi/feed_cache.json`), so open the Subscriptions screen in vidi at least once
to build it. Playing a video in vidi needs the CLI deep-link added in vidi 0.5.0.
`mpv` is only required if you set Click action to `mpv`; the `browser` action uses
`xdg-open`, which ships with every desktop environment.

## Usage

Add the widget to your bar in Noctalia's bar settings (widget `fel/vidi:latest`), or:

```sh
syskit bar widget-add end fel/vidi:latest --force   # when using syskit
```

The widget shows the number of videos published since you last checked the feed. Left
click opens the panel, right click marks everything seen, middle click re-reads the feed
cache. The panel lists the newest `max_items` videos; clicking a row opens the video
(default: play it in vidi), the copy button copies its URL, and the header button opens
vidi in a terminal. Opening the panel marks the feed seen.

Toggle the panel from anywhere:

```sh
noctalia msg panel-toggle fel/vidi:feed
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `max_items` | `int` | `10` | How many videos the panel lists (3–30). |
| `include_shorts` | `bool` | `false` | Count and show YouTube shorts in the feed and unread count. |
| `show_thumbnails` | `bool` | `true` | Use thumbnails vidi has cached in `~/.cache/vidi/preview_images` when available. |
| `open_action` | `select` | `vidi` | What happens on row click: `vidi`, `mpv`, `browser`, or `copy`. |

## Notes

- The widget only **reads** vidi's cache; refreshing happens inside vidi — open its
  Subscriptions screen to pick up new uploads.
- It spawns `jq` once per feed change to compact the cache, so Noctalia never parses the
  full file in a script callback.
- The unread marker persists at `~/.local/state/noctalia/plugins/data/fel/vidi/seen.json`.
- Opening a video in vidi launches a terminal running `vidi <url>`; the mpv and browser
  actions spawn `mpv`/`xdg-open` directly.