# Noctalia Lyrics 1.7.0

Synchronized lyrics for the Noctalia bar, with multiple MPRIS players,
translation and romanization layers, configurable sources, karaoke highlighting,
line-slide transitions, album artwork, and layout controls.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h465855hgg/lyrics` |
| Entries | Bar widget: `lyrics`; panel: `selector`; shortcut: `open_selector`; service: `service` |

## Requirements

Install these commands on `PATH`:

- `playerctl`: read and control MPRIS players.
- `python3`: run the unified lyric-source adapter and dynamic lyric parser.
- `cp`: preserve local MPRIS artwork in the plugin cache.
- `chmod`: secures the temporary request directory before credentials are
  written.
- `timeout`: bounds each `playerctl` metadata poll during startup and runtime.

For a dependency table and package-manager install commands, see
[DEPENDENCIES.md](DEPENDENCIES.md).

The line-slide animation needs a Noctalia build with plugin API 52 (the
paint-only `translateX`/`translateY`, `scale`, and `clip` declarative UI props).
Older shells are held back to the 1.6.x release from the plugin source and keep
the previous fade-based transitions.

## Usage

Enable `h465855hgg/lyrics`, start its `service` entry, and add the `lyrics` bar
widget. The widget declares default pointer bindings that appear under Actions
in its bar settings:

| Gesture | Default command | Behavior |
| --- | --- | --- |
| Left click | `plugin h465855hgg/lyrics:lyrics all toggle-view` | Switch between lyrics and track information when `display_mode` is `toggle` |
| Right click | `plugin h465855hgg/lyrics:service all toggle-playback` | Pause or resume the selected player |
| Scroll up | `plugin h465855hgg/lyrics:service all next` | Next track on the selected player |
| Scroll down | `plugin h465855hgg/lyrics:service all previous` | Previous track on the selected player |

Override or clear any binding per widget in the bar widget's Actions section.
The left-click command is broadcast to every lyrics widget, and only the
instance under the pointer changes its view. When LRCLIB returns multiple
matches, open the `selector` panel from the
`open_selector` control-center shortcut and apply another result. The widget no
longer opens the selector on hover; it can also be opened directly through IPC:

```sh
noctalia msg panel-toggle h465855hgg/lyrics:selector
```

## Screenshots

Double-line widget with translated or romanized lyrics:

![Lyrics 1.4 widget](<screenshots/widget - 1.4.0.png>)

Plugin-wide settings:

![Lyrics 1.4 settings](<screenshots/settings - 1.4.0.png>)

Per-widget bar settings:

![Lyrics 1.4 bar widget settings](<screenshots/bar widget settings - 1.4.0.png>)

Per-widget settings categories and word-level colors (1.6):

![Lyrics 1.6 settings categories](<screenshots/settings - 1.6.0.png>)

## Local development

Add the parent directory of this checkout as a local Noctalia source:

```sh
noctalia msg plugins source add lyrics-dev path /path/to/plugin-parent
noctalia msg plugins enable h465855hgg/lyrics
noctalia msg config-reload
```

Run validation after every change:

```sh
python3 .github/workflows/scripts/validate-plugins.py
noctalia plugins lint lyrics
sh lyrics/scripts/setup-deps.sh --check
cd lyrics
python3 -m py_compile lyric_sources.py music_sources.py krc_decode.py lrclib_lyric.py
python3 -m unittest discover -v
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

`chars` is only kept when it aligns one-to-one with the visible characters and
increases monotonically. A line with complete word timings uses per-character
karaoke highlighting; a line without them uses line mode instead: the whole
line is highlighted and simply advances when the next line starts. Word-synced
lines use the dedicated `karaoke_active_color` and `karaoke_inactive_color`
settings, while line-mode lyrics keep using `active_color` and
`inactive_color`. Enable the per-widget `force_karaoke` option to restore the
old behavior for unsynchronized lines (evenly filling the line character by
character). Credit and production lines (for example `作词：...`,
`Lyrics by ...`, `작사: ...`, or `词版权管理方：...`) are filtered out before
display.

Each adapter also reports quality metadata: `format`, `sync`
(`word`/`line`/`plain`), `word_lines`, `timed_lines`, `coverage`,
`has_translation`, and `has_romanization`. The service logs the chosen format
and sync level for every source.

## Sources

`auto` tries the IDs listed in `lyrics_sources` from top to bottom. Supported
IDs are:

- `lrclib`: public LRCLIB search with automatic synchronized-result ranking and
  manual result selection.
- `netease`: public NetEase cloud search and lyric endpoint with legacy
  fallback, synchronized lyrics, translations, and romanization when returned.
- `splayer`: SPlayer's complete current lyric data, including line and word
  timing, translations, romanization, background lines, and duet markers.
  SPlayer must be running; the default API URL is `http://127.0.0.1:25884`.
  Changing this URL sends current track metadata to the configured service.
- `splayer_next`: SPlayer Next's external HTTP API (`/api/now-playing` and
  `/api/lyrics`). Requires **External API** to be enabled in SPlayer Next
  settings; the default URL is `http://127.0.0.1:14558`. It returns the app's
  parsed lyric lines with word timings, translations, romanization, background
  lines, and duet markers, so it can drive per-character karaoke. When its
  translation or romanization layers are incomplete and the track comes from
  NetEase, the adapter fills the missing fields from NetEase's `tlyric` /
  `romalrc` by track id. It is kept in the automatic fallback chain even when an
  older saved `lyrics_sources` list predates it.
- `qqmusic`: QQ Music desktop catalogue search and lyric endpoint with legacy
  endpoint fallback.
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
Album artwork uses MPRIS first, then the matched lyric source when available.
LRCLIB, Qishui, and Musixmatch matches use the public iTunes Search API as an
artwork fallback. Cached covers retain their detected image format and the
oldest files are removed after the cache reaches 80 covers.

Within a source, lyric formats are tried in the configurable `format_priority`
chain (default `yrc > qrc > krc > ttml > richsync > syllables >
enhanced_lrc > lrc > plain`). A source only tries formats it can decode, and
falls back to the next format when the higher-priority one is missing or
invalid. Word timings therefore become karaoke highlighting when available;
sources without word timings use line mode. When `auto_source_routing` is
enabled, a player or media URL matching NetEase, QQ Music, Kugou/MoeKoe,
SPlayer, SPlayer Next, or Spotify puts that source first; this only reorders
the existing source list and never adds a request.

Runtime cache files are stored in `noctalia.pluginDataDir() .. "/cache"`, which
honors `NOCTALIA_STATE_HOME` and survives plugin source updates. Existing
source-local caches are not migrated; artwork is fetched again as needed.

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
milliseconds, player filters, and source credentials. Advanced settings also
expose `format_priority` (lyric format order), `source_format_priority`
(optional per-source overrides such as `netease=yrc,krc,lrc`), and
`auto_source_routing` (prefer the source matching the active player/URL).

Per-widget settings are grouped by a **Settings category** selector at the top of
the widget settings panel: Basic display, Lyrics and translation, Karaoke and
animation, Cover and colors, Font and layout, Scrolling and width, and
Intro/interlude cues. Only the selected category's controls are shown; the
other categories keep their saved values. Noctalia's plugin manifest has no
section-header support for widget settings, so the categories are implemented
with `visible_when` instead of headers. The controls cover the fallback glyph,
artist visibility, paused-state visibility, visibility when no lyrics are
available, album-cover shape and size, primary, inactive, and secondary lyric
colors, display mode, lyric layers, karaoke behavior (including forced karaoke
for lines without word timings), scrolling, fixed lyric width, and the lyric
animation (karaoke fill + fade, slide up/down, swoosh left/right, spring push,
drop + bounce, zoom, flip, spin, squash, character cascade, character wave,
typewriter, flip, spin, squash, random, or none),
plus typography, spacing, padding, intro/interlude cue visibility and text, and
text alignment. The Actions section lists the default left-click, right-click,
and
scroll bindings described above. Credential and source-specific fields are
shown only when their matching source is selected; source order, credentials,
polling, player filters, and other plugin-wide controls remain on the plugin
page.

### 1.5 configuration change

Display settings are now stored per lyrics widget. After upgrading from 1.4,
open each lyrics widget's settings and reapply its preferred display, animation,
scrolling, typography, and layout options. Source, player, timing, and credential
settings remain plugin-wide.

## Feature test checklist

The plugin settings page contains source selection, translation language,
timing, polling, player filters, and credentials under Advanced. Each widget has
a Settings category selector that shows one functional group at a time
(display, lyrics, karaoke, cover/colors, font/layout, scrolling, cues).

1. Language: change Noctalia's global language and reload the config. Plugin
   settings and runtime text follow the host language. This plugin ships English,
   Simplified Chinese, Brazilian Portuguese, and Turkish catalogs; other locales
   fall back to English until the community i18n service fills them in. Close
   and reopen Settings, then disable and enable the plugin if the runtime
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
11. Track-only: select `display_mode=track`; other lyrics widget instances still
    fetch and display lyrics normally.
12. Font and double-line sizing: test `font_family`, `primary_font_size`,
    `secondary_font_size`, `line_gap`, `font_weight`, and `font_style`.
13. Animations: test karaoke, slide up/down, swoosh left/right, spring, drop,
    zoom, flip, spin, squash, cascade, wave, typewriter, random, and none; each must
    keep the configured karaoke colors while it plays.
14. Layout: test `max_chars` and `text_alignment` with short and long lyrics,
    plus `padding_left`, `padding_right`, and `line_gap` on horizontal and vertical
    bars.
15. LRCLIB selection: play a track with multiple results, open the selector from
    its shortcut or IPC, and switch between synchronized and plain entries without
    changing tracks.
16. Cues: toggle `show_cues` and verify the widget hides cue text but keeps lyrics
    visible; adjust the cue thresholds under the widget's Intro/interlude cues category.
17. Actions: open the widget's Actions section and confirm the left, right,
    scroll-up, and scroll-down rows show the defaults above; rebind one, then
    clear it to restore the default.
18. Word/line mode: play a word-synced NetEase/SPlayer track and confirm the
    per-character fill; then play an LRC-only track and confirm the whole line
    is highlighted at once and switches at the next line. Lines with incomplete
    word timings must not use synthetic per-character fill.
19. Credit filtering: play a NetEase YRC/KRC track whose payload starts with
    credits and confirm lines such as `作词：...`, `词版权管理方：...`,
    `录音作品及MV版权：...`, or `Lyrics by ...` are not displayed.
20. Format priority: move `lrc` before `yrc` in `format_priority` and confirm
    the same source switches to line mode; test a `source_format_priority`
    override; toggle `auto_source_routing` and confirm the matching source is
    tried first without any additional request.
21. SPlayer Next: enable **External API** in SPlayer Next settings, play a
    track, and select `splayer_next` (SPlayer Next players are routed there
    automatically). Verify per-character lyrics, translation/romanization, and
    that disabling External API falls through to the next source.
22. Forced karaoke: play an LRC-only track and toggle `force_karaoke` under the
    widget's karaoke settings. Off: the whole line highlights at once. On: the
    old character-by-character fill returns for lines without word timings.
23. Settings categories: switch the widget's Settings category selector between
    Basic display, Lyrics and translation, Karaoke and animation, Cover and
    colors, Font and layout, Scrolling and width, and Intro/interlude cues.
    Only the selected category's controls appear; values are kept when switching
    back.

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
