# Noctalia Lyrics 1.4.1

Synchronized lyrics for the Noctalia bar, with multiple MPRIS players,
translation and romanization layers, configurable sources, karaoke highlighting,
album artwork, and layout controls.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h465855hgg/lyrics` |
| Entries | Bar widget: `lyrics`; service: `service` |

## Requirements

Install these commands on `PATH`:

- `playerctl`: read and control MPRIS players.
- `python3`: run the unified lyric-source adapter and dynamic lyric parser.
- `cp`: preserve local MPRIS artwork in the plugin cache.
- `chmod`: secures the temporary request directory before credentials are
  written.

## Usage

Enable `h465855hgg/lyrics`, start its `service` entry, and add the `lyrics` bar
widget. Left-click switches between lyrics and track information when
`display_mode` is `toggle`; right-click pauses or resumes the selected player.

## Screenshots

Double-line widget with translated or romanized lyrics:

![Lyrics 1.4 widget](<screenshots/widget - 1.4.0.png>)

Plugin-wide settings:

![Lyrics 1.4 settings](<screenshots/settings - 1.4.0.png>)

Per-widget bar settings:

![Lyrics 1.4 bar widget settings](<screenshots/bar widget settings - 1.4.0.png>)

## Local development

Add the parent directory of this checkout as a local Noctalia source:

```sh
noctalia msg plugins source add lyrics-dev path /path/to/plugin-parent
noctalia msg plugins enable h465855hgg/lyrics
noctalia msg config-reload
```

Run validation after every change:

```sh
python3 .github/workflows/validate-plugins.py
noctalia plugins lint lyrics
sh lyrics/scripts/setup-deps.sh --check
cd lyrics
python3 -m py_compile lyric_sources.py krc_decode.py lrclib_lyric.py
python3 -m unittest test_lyric_sources.py
```

## Lyrics model

Every source is normalized to lines with independent original, translation,
romanization, and character-timing fields:

```json
{
  "time": 1200,
  "duration": 1800,
  "text": "Original lyric",
  "translation": "Translated lyric",
  "romanization": "romanized lyric",
  "chars": [1200, 1500, 1800]
}
```

## Sources

`auto` tries the IDs listed in `lyrics_sources` from top to bottom. Supported
IDs are:

- `lrclib`: public LRCLIB search.
- `netease`: public NetEase search, synchronized lyrics, translations, and
  romanization when returned.
- `splayer`: SPlayer's complete current lyric data, including line and word
  timing, translations, romanization, background lines, and duet markers.
  SPlayer must be running; the default API URL is `http://127.0.0.1:25884`.
  Changing this URL sends current track metadata to the configured service.
- `qqmusic`: public QQ Music search and lyric endpoint.
- `kugou`: public Kugou search and lyric download endpoint.
- `qishui`: user-configured HTTP endpoint supporting `{title}`, `{artist}`, and
  `{album}` placeholders.
- `apple_music`: Apple Music catalog and lyrics request using manually supplied
  developer and optional user tokens.
- `spotify`: Spotify search and color-lyrics request using a manually supplied
  access token or `sp_dc`.
- `musixmatch`: Musixmatch subtitle request using a manually supplied usertoken.
- `mpris`: embedded `xesam:asText` lyrics from the selected player.
- `custom`: existing generic HTTP endpoint.
- `external`: lyrics pushed through Noctalia IPC.

Source APIs can change or reject requests by region or account. Failure of one
source in automatic mode moves to the next source without logging credentials.

## Credential warning

Noctalia currently exposes these as normal string settings, not secret fields.
Spotify, Apple Music, Musixmatch, and Qishui credentials may therefore be stored
in plaintext in Noctalia's settings. The plugin never scans browser cookies,
never logs credential values, and deletes its temporary credential request file
as soon as the source adapter reads it. The service applies mode `0700` to the
request directory before writing any credential-bearing file.

## Settings

The plugin settings control source selection and fallback order, translation
language, lyric timing offset in milliseconds, MPRIS polling interval in
milliseconds, double-line translation and romanization, karaoke highlighting,
marquee behavior, transitions, fonts, spacing, and side padding.

Per-widget settings control the fallback glyph, artist visibility, paused-state
visibility, album-cover shape and size, and primary, inactive, and secondary
lyric colors. Credential and source-specific fields are shown only when their
matching source is selected; source order, credentials, polling, marquee
metrics, player filters, and fine layout controls are under Advanced settings.

## Feature test checklist

The normal settings view contains everyday source, lyric-layer, display, font,
and animation controls. Open Advanced settings for credentials, source order,
polling, marquee metrics, player filters, and fine padding.

1. Language: change Noctalia's global language and reload the config. Plugin
   settings and runtime text follow the host language. Noctalia currently
   supports English and Simplified Chinese from the originally requested locale
   set; Japanese, Korean, and Traditional Chinese are not host language options.
   Close and reopen Settings, then disable and enable the plugin if the runtime
   tooltip still uses the previous language.
2. Chinese translation: use NetEase/QQ/Musixmatch with `show_translation=true`
   and `translation_language=zh-Hans`.
3. Romanization: enable `show_romanization` and select a NetEase/QQ track that
   returns romanized lyrics.
4. Sources: select each `lyrics_source` directly, then test custom fallback order
   through `lyrics_sources`.
5. Delay: set `lyrics_offset_ms` to `1000` and `-1000`; positive values should
   show the next lyric one second earlier.
6. Polling: test `poll_interval_ms` at `100`, `500`, and `2000`.
7. Cover: test circle, rounded, square, and custom radius; change `cover_size`.
8. Double line: enable `double_line` and switch `secondary_line_mode`.
   On horizontal bars keep `double_line_auto_fit` enabled and lower
   `double_line_height_budget` if the bar clips the second line.
9. Karaoke: toggle `karaoke_enabled`; line transitions must continue when off.
10. Hide layers: independently disable `show_translation` and
    `show_romanization`.
11. Track-only: select `display_mode=track`; no lyric source request should run.
12. Font and double-line sizing: test `font_family`, `primary_font_size`,
    `secondary_font_size`, `line_gap`, `font_weight`, and `font_style`.
13. Animations: test karaoke, cascade, wave, fade, typewriter, pulse, blink, and
    none.
14. Layout: test `padding_left`, `padding_right`, and `line_gap` on horizontal and
    vertical bars.

## External protocol

Address the singleton service with:

```sh
noctalia msg plugin h465855hgg/lyrics:service all <event> '<payload>'
```

Supported events:

- `push-lrc`: synchronized or plain LRC text.
- `push-json`: JSON with `lines` or `lyrics`.
- `push-state`: also updates track, position, playing, and cover.
- `clear`: clears current lyrics.

MPRIS track duration and playback position are microseconds. Lyric line,
duration, and character timestamps are milliseconds.
