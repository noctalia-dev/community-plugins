# Lyrics

Lyrics adds a synchronized status-bar lyric display with album artwork, karaoke
highlighting, animated line changes, and configurable online or local sources.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h465855hgg/lyrics` |
| Entries | Bar widget: `lyrics`; service: `service` |

## Requirements

Install `playerctl`, `python3`, and `cp` on `PATH`. The active media
player must expose MPRIS metadata for automatic track and playback detection.

Noctalia installs the plugin files; it does not install system packages for you.
To check or install the runtime packages automatically, run:

```sh
sh scripts/setup-deps.sh --check
sh scripts/setup-deps.sh
```

Use `--yes` for unattended installs. The script supports `apt`, `dnf`,
`pacman`, `zypper`, `apk`, and `xbps-install`.

## Usage

Enable `h465855hgg/lyrics`, then add the `lyrics` bar widget in Noctalia's bar
settings. The background `service` detects the active MPRIS player, resolves
lyrics, downloads or caches album artwork, and publishes playback state to the
widget.

Left-click the widget to switch between lyrics and track information. Right-click
to pause or resume the active player. Paused content is dimmed and all lyric,
transition, and marquee animation stops until playback resumes.

When synchronized lyrics are unavailable, the widget displays
`track title + artist`. Long lines pause at each end while scrolling. Intro and
instrumental gaps can show a configurable cue such as `•••••`.

## Screenshots

Status-bar widget:

![Lyrics bar widget](screenshots/widget.webp)

Plugin settings:

![Lyrics settings](screenshots/settings.webp)

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `lyrics_source` | `select` | `auto` | Selects automatic fallback, LRCLIB, public NetEase, MPRIS text, custom HTTP, or external IPC. |
| `custom_url` | `string` | empty | HTTP URL template with `{title}`, `{artist}`, `{album}`, and `{duration}` placeholders. |
| `custom_json_field` | `string` | `syncedLyrics` | Dotted field path containing an LRC string or timed-lines array in a JSON response. |
| `cue_text` | `string` | `•••••` | Characters highlighted through long intro or instrumental gaps. |
| `scroll_mode` | `select` | `auto` | Enables automatic marquee, forced marquee, or static truncation. |
| `marquee_speed` | `int` | `30` | Approximate long-line scroll speed in logical pixels per second. |
| `max_lines` | `int` | `1` | Number of lines shown on a vertical bar, from 1 to 3. |
| `gradient` | `bool` | `true` | Enables progressive per-character highlighting. |
| `animation` | `select` | `karaoke` | Chooses karaoke, cascade, wave, fade-only, or no line transition. |
| `max_chars` | `int` | `24` | Number of visible Unicode characters before marquee scrolling starts. |
| `char_width` | `int` | `9` | Estimated logical-pixel character width used for scroll timing and minimum layout width. |
| `glyph` | `glyph` | `music` | Fallback icon shown when album artwork is unavailable. |
| `show_artist` | `bool` | `true` | Includes the artist in track-information mode. |
| `hide_when_paused` | `bool` | `false` | Hides the widget instead of dimming it while paused. |
| `show_cover` | `bool` | `true` | Shows circular album artwork beside the lyrics. |
| `active_color` | `color` | `primary` | Colors the current and already-sung lyric characters. |
| `inactive_color` | `color` | `on_surface_variant` | Colors upcoming lyrics, paused playback, and secondary lines. |

## IPC

External players can set `lyrics_source` to `external` and address the singleton
service with:

```sh
noctalia msg plugin h465855hgg/lyrics:service all <event> '<payload>'
```

Supported events:

- `push-lrc`: accepts synchronized or plain LRC text.
- `push-json`: accepts JSON with a `lines` timed array or a `lyrics` LRC string.
- `push-state`: also accepts `track`, `position`, `playing`, and `cover` fields.
- `clear`: clears the currently published lyrics.

Line timestamps and character timestamps are milliseconds. MPRIS track duration
and playback position are microseconds:

```json
{"lines":[{"time":1200,"duration":1800,"text":"Hello","chars":[1200,1500,1800,2100,2400]}]}
```

## Notes

Automatic mode requests LRCLIB first, then the public NetEase Music API. Custom
HTTP mode contacts only the configured endpoint. The plugin never reads browser
cookies or player credentials.

The service runs `playerctl` to read and control MPRIS playback, `python3` for the
LRCLIB helper and dynamic-lyric parser, and `cp` to preserve temporary local cover
files. Public NetEase requests use Noctalia's HTTP API. Query scratch files and
downloaded cover images are written inside the plugin runtime directory. Remote
code is never downloaded or executed.
