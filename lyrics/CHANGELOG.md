# Changelog

## 1.6.0

- Word-level lyric sources now drive per-character karaoke highlighting, while
  lines without complete word timings fall back to line mode: the whole line is
  highlighted at once and advances when the next line starts. No synthetic
  per-character fill is used for unsynchronized lines.
- Add a per-widget `force_karaoke` option that restores the previous behavior
  for lines without word timings: the line is filled character by character
  over its duration instead of being highlighted as a whole.
- Add dedicated `karaoke_active_color` and `karaoke_inactive_color` settings
  for word-synced lines. Line-mode lyrics continue to use `active_color` and
  `inactive_color`.
- Turn the compact double-line mode (`double_line_auto_fit`) off by default.
- Group per-widget settings into functional categories with a **Settings
  category** selector: Basic display, Lyrics and translation, Karaoke and
  animation, Cover and colors, Font and layout, Scrolling and width, and
  Intro/interlude cues. Only the selected category's controls are shown; other
  values are preserved. Noctalia's plugin manifest has no section-header field
  for widget settings and each setting supports only one `visible_when`
  condition, so categories are implemented as pages instead of headers.
- Update the shipped defaults to the current configuration: glyph off, custom
  cover shape, hide when no lyrics, gradient and translation off, fixed font
  style, custom cue font, 35 max characters, and an
  automatic source order that starts with `splayer_next`.
- Fix missing translation/romanization on word-synced results: pair layers
  with the same line count by order when their timestamps drift, merge every
  available translation/romanization field instead of stopping at the first
  non-empty one, and fill missing SPlayer Next layers from NetEase for
  NetEase-sourced tracks (looked up by track id).
- Filter credit and production metadata lines in every format and language.
  NetEase YRC/KRC credit lines such as "词版权管理方：..." and "录音作品及MV版权：..."
  are removed, as are English, Japanese, Korean, and other localized
  "Lyrics by"/"作詞"/"작사" style headers, plus instrumental markers.
- Report lyric quality metadata from every adapter: `format`, `sync`
  (`word`/`line`/`plain`), `word_lines`, `timed_lines`, `coverage`,
  `has_translation`, and `has_romanization`. The service logs the chosen
  format and sync level for each source.
- Add a configurable format priority chain (`yrc > qrc > krc > ttml >
  richsync > syllables > enhanced_lrc > lrc > plain`) with optional per-source
  overrides. Each source tries its supported formats in that order and falls
  back to the next format when a higher-priority format is unavailable or
  invalid.
- Prefer the source that matches the active player or media URL (NetEase, QQ
  Music, Kugou/MoeKoe, SPlayer, Spotify). This only reorders the existing
  source list; it never adds requests or delays word-level lyrics.
- Add an `splayer_next` lyric source for SPlayer Next's external API
  (`/api/now-playing` and `/api/lyrics`). It reads the app's parsed AMLL lines,
  including word timings, translations, romanization, background lines, and
  duet markers. Enable External API in SPlayer Next settings first; the default
  URL is `http://127.0.0.1:14558`. SPlayer Next players are routed to this
  source automatically, and older saved source orders keep it in the automatic
  fallback chain (right after `splayer`).
- Bump the plugin version to 1.6.0.

## 1.5.8

- Declare the widget's left-click, right-click, and scroll bindings as editable
  Actions defaults instead of hiding them in Luau callbacks. The commands keep
  using the service's selected MPRIS player, and only the hovered lyrics widget
  changes view on left click when several instances are active.
- Raise `plugin_api` to 14, required for widget gesture defaults.
- Turn double-line lyrics off by default. Existing widgets with an explicit
  `double_line = true` setting keep the second line.
- Use the QQ Music desktop catalogue and lyric endpoints, with the legacy
  endpoints as fallback, and prefer NetEase cloud search plus the newer lyric
  endpoint. This restores lyrics when the old endpoints fail or return empty
  results.
- Match catalogue entries by artist, version, and duration, and try additional
  matched entries when the first one has no lyrics.
- Retry the same track with exponential backoff after every source fails, and
  log per-source diagnostics instead of silently showing no lyrics.
- Normalize control characters in MPRIS metadata from Electron/Chromium-based
  players such as the QQ Music Flatpak.
- Report a clear diagnostic when `python3` lacks the `_ssl` module, and check
  HTTPS support in `setup-deps.sh`, instead of treating every source as a
  generic network failure.

## 1.5.7

- Keep the lyrics capsule visible while lyrics are loading and retry transient
  empty player polls instead of clearing the current track immediately.
- Open the selector only from its shortcut or IPC; hovering no longer opens the
  panel and can no longer interfere with the widget's left-click action.
- Add a per-widget intro/interlude cue toggle, cue text and font controls, and
  adjustable timing thresholds.

## 1.5.6

- Keep runtime cache in Noctalia's plugin data directory so plugin source
  updates do not break lyric requests or artwork downloads.

## 1.5.5

- Retry MPRIS discovery after a short startup failure instead of leaving the
  service stuck while `playerctl` waits for the session bus.
- Add a timeout to each `playerctl` poll so the service remains recoverable
  when a player is unavailable during login.
- Use the translated no-lyrics message when the widget is visible without
  lyrics; the existing hide-when-no-lyrics option still hides it completely.

## 1.5.4

- Bound MPRIS metadata output and field processing so unusually large song
  metadata is discarded instead of exhausting the async callback CPU budget.

## 1.5.3

- Replace pattern-based MPRIS metadata parsing with a linear separator scan so
  unusually large or malformed player metadata cannot exhaust the async
  callback CPU budget.

## 1.5.2

- Filter duplicate Musixmatch subtitle entries at the same timestamp so
  repeated API entries do not flash several unrelated lyric lines during
  playback.

## 1.5.1

- Fix the service exceeding Noctalia's async callback CPU budget when playback
  starts by skipping the potentially very large MPRIS `xesam:asText` field
  unless MPRIS lyrics are enabled as a source.

## 1.5.0

- Move display mode, lyric layers, karaoke, animation, scrolling, sizing,
  typography, spacing, cue text, and alignment into per-widget settings.
- Keep lyric sources, player selection, timing, polling, and credentials shared
  by the singleton background service.
- Continue fetching lyrics when one widget uses track-only mode so other widget
  instances can display synchronized lyrics.
- Existing 1.4 display settings must be reapplied for each lyrics widget after
  upgrading; source and service settings are unchanged.

## 1.4.6

- Fix MPRIS player detection on systems where `/bin/sh` is `dash` rather than
  Bash, contributed by @Dioxane123 in [#404](https://github.com/noctalia-dev/community-plugins/pull/404).

## 1.4.5

- Add a per-widget option to hide the lyrics widget when no lyrics are
  available, contributed by @NullSeile in [#216](https://github.com/noctalia-dev/community-plugins/pull/216).
- Keep the widget visible in track-only mode when that option is enabled.

## 1.4.4

- Add ranked, selectable LRCLIB results through an attached selector panel and
  `open_selector` shortcut.
- Bind candidate requests and selected results to the current track so stale
  responses cannot replace current lyrics.

## 1.4.3

- Add controls to hide the fallback glyph and its picker when it is disabled.
- Add mouse-wheel previous/next track controls.
- Use Noctalia's host scroll handling for the widget.

## 1.4.2

- Add Simplified Chinese translations.
- Restore `splayer` in the automatic-source settings help text.
- Add matched-provider and iTunes Search artwork fallbacks when MPRIS artwork is
  unavailable, with content-type detection, bounded cache cleanup, and stale
  request protection.

## 1.4.1

- Add an SPlayer preset that consumes SPlayer's complete current lyric data,
  including line and word timing, translations, romanization, background lines,
  and duet markers.
- Preserve SPlayer word boundaries and expose character timing for karaoke
  highlighting without tying the preset to a specific upstream music service.
- Pass MPRIS track IDs and media URLs through the service for stable track
  identity.
- Detect pseudo word-timed lines whose inferred end time is stretched to the
  next LRC timestamp, restoring instrumental-break cues without changing real
  multi-word timing.

## 1.4.0

- Add English and Simplified Chinese localization following Noctalia's global
  language, without exposing unsupported per-plugin language overrides.
- Add translation and romanization lyric layers with double-line display,
  independent visibility controls, and secondary-line priorities.
- Add unified LRCLIB, NetEase, QQ Music, Kugou, Qishui, Apple Music, Spotify,
  Musixmatch, MPRIS, custom HTTP, and external IPC source handling.
- Add manually supplied Spotify, Apple Music, Musixmatch, and Qishui credentials
  without automatic browser-cookie discovery or credential logging.
- Add lyrics timing offset and configurable MPRIS polling interval.
- Add cover shape, custom radius, and cover size controls.
- Add track-only mode, per-character karaoke toggle, font family/size/weight,
  secondary font size, supported baseline styles, line spacing, and side padding.
- Add typewriter, pulse, and blink transitions alongside existing animations.
- Cancel stale source callbacks when changing sources on the same track, and
  show credential settings only for their selected source.
- Add independent primary/secondary lyric font sizes and inter-line spacing.
- Reorganize settings into a focused common view and a collapsed advanced view
  for credentials, source ordering, polling, marquee metrics, and fine layout.

## 1.3.0

- Add an option for intro/interlude characters to follow the interface font or
  use a custom installed font family.
- Change the default active lyric color to `on_surface`.
- Change the default maximum visible character count to 15.

## 1.2.0

- Select the active MPRIS player across all available `playerctl` players.
- Add optional player allowlist and blocklist settings with wildcard matching.
- Send play/pause commands to the selected player instead of the global default.
- Prevent stale lyric and artwork requests from replacing the current track.

## 1.1.0

- Add per-widget active and inactive lyric color controls.
- Keep theme-aware semantic colors as defaults while allowing custom colors.

## 1.0.0

- Initial public release.
- Synchronized status-bar lyric widget with karaoke highlighting and animated
  line transitions (karaoke, cascade, wave, fade, none).
- Long-line smooth marquee scrolling with end pauses.
- Intro/instrumental cue text with configurable characters.
- Lyric sources: auto, LRCLIB, public NetEase, MPRIS text, custom HTTP, and
  external IPC push.
- Album artwork display with circular crop and runtime cache.
- Track-information fallback (`title + artist`) when no lyrics are available.
- Right-click pause/resume via `playerctl` with dimmed paused state.
- KRC dynamic-lyric parsing (plain, prefixed, and three-argument formats).
