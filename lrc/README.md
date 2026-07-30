# LRC

![thumbnail](thumbnail.webp)

Displays current song lyrics on the bar widget via `lrc_tty`. Works with MPD and Spotify.

## Plugin

| Field | Value |
| --- | --- |
| ID | `shin/lrc` |
| Entries | Bar widget: `lrc` |

## Requirements

- `lrc_tty` — fetches and outputs synchronized lyrics.
- `playerctl` — reads MPRIS player status and metadata.

## Usage

Enable `shin/lrc` in Settings → Plugins, then add the **LRC** bar widget. It displays the current lyric line when a track is playing.

The widget checks MPD first, then falls back to Spotify.

## Notes

Spawns `playerctl` to query playback status and `lrc_tty` to fetch and synchronize lyrics.
