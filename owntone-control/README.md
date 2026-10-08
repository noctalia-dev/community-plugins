# OwnTone Control

Play/pause, volume, now-playing, and multi-room audio outputs for
[OwnTone](https://owntone.github.io/owntone-server/) (forked-daapd) — a full
control panel right in the bar, no browser tab needed.

## Plugin

| Field | Value |
| --- | --- |
| ID | `danielel/owntone-control` |
| Entries | Data service: `poller`; bar widget: `owntone`; panel: `panel` |

## Requirements

No external dependencies — the plugin only needs network access to your
OwnTone server's HTTP API (default port `3689`).

## Usage

Enable the plugin, then add the `owntone` widget from Noctalia's bar widget
picker. Set your server's `host:port` in the plugin settings (and username /
password if your server requires HTTP authentication).

- **Left click**: opens the panel — now playing, playback controls, master
  volume, and multi-room audio outputs. A Library tab lets you browse
  artists, albums, genres, playlists, and internet radio stations, plus a
  search box for finding an artist or album by name.
- **Right click**: toggles play/pause directly from the bar, without opening
  the panel.
- **Scroll**: adjusts volume, 5% per step.

Open or close the panel without a bar widget:

```sh
noctalia msg panel-toggle danielel/owntone-control:panel
```

For compositor keybinds, the bar widget also accepts IPC events:

```sh
noctalia msg plugin danielel/owntone-control:owntone focused toggle
noctalia msg plugin danielel/owntone-control:owntone focused next
noctalia msg plugin danielel/owntone-control:owntone focused previous
noctalia msg plugin danielel/owntone-control:owntone focused volume_up
noctalia msg plugin danielel/owntone-control:owntone focused volume_down
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `host` | `string` | `127.0.0.1:3689` | `host:port` of your OwnTone server. |
| `poll_seconds` | `int` | `3` | How often the background service refreshes now-playing/volume state. |
| `username` | `string` | (empty) | OwnTone HTTP username; leave empty if your server has no authentication. |
| `password` | `string` | (empty) | OwnTone HTTP password. |
| `glyph` (widget setting) | `glyph` | `music` | Bar widget icon. |

## IPC

`danielel/owntone-control:owntone` accepts `toggle`, `next`, `previous`,
`volume_up`, and `volume_down` events, so these can be bound to compositor
keys without touching the mouse.

## Notes

- The `poller` service is the only entry that talks to OwnTone for reading
  state: it polls the JSON API every `poll_seconds` and publishes a
  normalized status via `noctalia.state`. The widget and panel only read that
  shared state; the panel additionally sends its own HTTP requests for
  playback actions (play/pause/seek/queue) and library browsing/search.
- Now-playing artwork is downloaded to the plugin's data directory and
  reused until the artwork URL changes.
- `password` is stored and shown in plain text in Noctalia's settings —
  there is no secret-storage API exposed to plugins, and OwnTone itself only
  accepts HTTP Basic authentication.
- Playlists that are really a single internet-radio stream wrapped in a
  one-track m3u (`item_count` 1, `stream_count` 1) are hidden from the
  Playlists screen; they show up correctly under the dedicated Radio screen
  instead, using the same `data_kind is url` search OwnTone's own web client
  uses for its Radio tab.
