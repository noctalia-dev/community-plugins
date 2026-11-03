# WFMU

Play WFMU's live streams or browse the most recent archived
episode of each WFMU show.

## Plugin

| Field | Value |
| --- | --- |
| ID | `quaversa/wfmu` |
| Entries | Bar widget: `control`; panel: `browse`; service: `fetcher` |

## Requirements

Both tools must be available on `PATH`:

- `mpv` plays the streams. The plugin starts it with `--no-video` and an IPC
  socket in the plugin data directory.
- `python3` runs the bundled stream-list fetcher at `scripts/wfmu_archives.py`.
- `xdg-open` opens `https://wfmu.org/` when clicking the panel logo.

The fetcher makes network requests to `wfmu.org`, `mp3archives.wfmu.org`, and
`podcast.wfmu.org`. No account or API key is needed.

## Usage

Add the **WFMU** bar widget (`control`) from Settings.

The panel can also be toggled directly:

```sh
noctalia msg panel-toggle quaversa/wfmu:browse
```

The panel has three sections: **Live** (the WFMU live streams), **Favorites**,
and **Archives** (each show's most recent episode). Click a stream or archive to play it in
mpv, and favorite a playing archived show from the panel header to pin it.

The stream list is downloaded the first time the plugin is enabled.
The background `fetcher` service downloads
it and refreshes it when it goes stale, and the panel header refresh
button (or the `refresh` IPC action) forces a download at any time.

Widget actions:

- Left click opens the browse panel.
- Right click plays the first live stream, or stops playback if something is
  already playing.
- Middle click plays a random stream from the current list.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_cmd` | `string` | empty | Command run to rebuild the stream list. Leave empty to use the bundled fetcher. |
| `tsv_path` | `string` | empty | Tab-separated stream list the plugin reads. Leave empty to keep it in the plugin's own data directory. |

The default stream list lives at `latest-archives.tsv` inside the plugin data
directory and is written by `scripts/wfmu_archives.py`.

## IPC

The `control` widget entry accepts these events:

```sh
noctalia msg plugin quaversa/wfmu:control all refresh
noctalia msg plugin quaversa/wfmu:control all stop
noctalia msg plugin quaversa/wfmu:control all random
noctalia msg plugin quaversa/wfmu:control all play URL
```

`play` accepts an optional URL argument; without one it replays the last stream.

## Notes

- **Refresh:** the headless `fetcher` service rebuilds the list when it is
  missing or older than six hours, and on demand. The widget and panel read the
  list from the plugin data directory, so a fresh install is populated without
  any manual step.
- **Network:** `scripts/wfmu_archives.py` fetches the WFMU show index, one RSS
  archive feed per show, and each show's latest episode link, then writes the
  stream list. Fetched pages are cached for one hour in
  `$XDG_CACHE_HOME/noctalia-wfmu` (or `~/.cache/noctalia-wfmu`). Pass `--no-cache`
  or `--cache-ttl 0` to disable it.
- **Processes:** playback spawns `mpv`; the widget and panel talk to it over a
  Unix socket with short-lived `python3` helpers. The fetcher spawns nothing.
- **Files written:** the stream list, `mpv.pid`, `mpv.sock`, `mpv-title.txt`,
  and `favorites.json` all live in the plugin data directory. Override the
  stream list with the `tsv_path` setting.
