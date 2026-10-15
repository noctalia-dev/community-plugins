# WFMU

Browse WFMU's live streams or listen to the most recent archived
episode of every WFMU show.

## Plugin

| Field | Value |
| --- | --- |
| ID | `quaversa/wfmu` |
| Entries | Bar widget: `control`; panel: `browse` |
| Launcher Prefix | — |

## Requirements

Both tools must be available on `PATH`:

- `mpv` plays the streams. The plugin starts it with `--no-video` and an IPC
  socket in the plugin data directory.
- `python3` runs the bundled stream-list fetcher at `scripts/wfmu_archives.py`.

The fetcher makes network requests to `wfmu.org`, `mp3archives.wfmu.org`, and
`podcast.wfmu.org`. No account or API key is needed.

## Usage

Add the **WFMU** bar widget (`control`) from Settings, then click it to open the panel. 
The panel can also be toggled directly:

```sh
noctalia msg panel-toggle quaversa/wfmu:browse
```

The panel has three groups: **Live** (the WFMU live streams), **Favourites**,
and **Archives** (each show's most recent episode). Click a stream or archive to play it in
mpv, and favorite a stream to pin it. 

You will need to click "refresh" once from the panel header or the
widget's right-click action to build the stream list.

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
- **Live stream URLs** are built into the fetcher and may need updating if WFMU
  changes them.
