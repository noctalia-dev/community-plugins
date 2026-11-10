# Changelog

## 1.7.1

- Add `candidate_mode`: **Choose** shows the picker when several results exist,
  **Best match** always uses the best-ranked result and disables the picker
  (the shortcut explains this instead of opening an empty panel).
- A failed candidate selection now falls back to the best match automatically,
  and the picker has a **Best match** button to discard the manual pick.
- Show the lyric format and the applied format in the picker: LRCLIB rows are
  labelled `LRC · Synced` / `PLAIN · Unsynced`, and the footer reports the format
  and timing granularity actually used (`Applied: YRC · word`).
- Prefer duration-matched versions when automatically choosing a result. LRCLIB
  ranking now weighs duration closeness before album identity, so a longer
  album version no longer wins over the version whose length matches the track.
  The picker also shows a `Δ` offset next to durations that differ from the
  playing track; `同步歌词`/`Synced` still describes the lyric format (timed
  lines) rather than duration.
- The picker redraws from `noctalia.state.watch` callbacks instead of a panel
  update loop. Plugin panels have no periodic `update()` timer, so previously
  the rows and selection stayed stale until the picker was reopened; applying a
  row, a new candidate list, or a track change is now reflected immediately.
- Document the runtime dependencies inline in `README.md` (purpose table,
  Arch/Debian/Fedora/NixOS install commands, `PATH`/OpenSSL checks) and drop the
  bundled `scripts/setup-deps.sh` helper: users run their package manager, and
  the installed plugin location differs from the repository checkout.
- Reclassify the bar widget settings categories: Display & behavior, Lyrics,
  Cover & colors, Karaoke & animation, Font & layout, Scrolling & width, and
  Intro/interlude cues. Cover visibility now lives with cover options, text
  alignment with font and layout, and the hover-picker toggle with behavior.
- Restore hover access to the alternate-lyrics picker: hovering the widget for
  0.55 s opens the selector when the current track has more than one matching
  lyric result from any source. It opens once per hover and only after that delay, so pointer
  pass-overs no longer pop the panel. New `selector_enabled` widget setting
  (default on) turns the picker off completely for that widget.
- Rework the picker from a dropdown into a list of clickable result rows: the
  current result is highlighted, hovering a row gives feedback, the header
  shows the result count, and each row shows the lyric source (`LRCLIB`), artist,
  duration, and synced/unsynced state. Applying a result highlights that row
  immediately and keeps the picker open so the selection is visible; a
  hover-opened picker closes itself after 8 s without interaction or when the
  track changes.
- Candidates are now collected from any source that can return more than one
  match: LRCLIB search results (up to 20), ranked NetEase and QQ Music search
  hits (up to 3 each), and Kugou lyric versions. Every candidate carries its
  source name, so the picker labels rows with `LRCLIB`, `NetEase`, `QQ Music`,
  `Kugou`, etc., and applying a row fetches that exact source entry.
- Translate every new string: settings labels/descriptions and picker strings
  are localized in English and Simplified Chinese (other locales fall back to
  English for the new keys).

## 1.7.0

- Marquee scrolling is pixel-smooth and follows the rendered text width: the
  whole line renders once inside a clipped viewport whose width is
  `max_chars * char_width`, and a paint-only `translateX` scrolls it at
  `marquee_speed` pixels per second using real font metrics (a full-width CJK
  character is one font size), so the scroll always reaches the final character
  before the line loops. Changing Max characters or Character width visibly
  changes the widget width and the clipped scroll area, and Character width now
  defaults to 14 to match the inherited body font size.
- Clip every transition frame to the marquee viewport: transitions used to
  render the raw row, so a long line flashed at full width for the length of
  the animation before snapping back to the clipped, scrolling viewport. Push
  transitions now also clamp their track/viewport width. The line is clipped
  from the first frame of every preset.
- Animate a lyric line as one block: the primary row and its
  translation/romanization row travel together through every transition, and
  both rows share an explicit slot height so a line no longer nudges up when a
  transition starts and settles back down when it ends (this also removed the
  same vertical jump from the cover-art widget).
- Replace the old animation presets with one set of twelve distinct lyrics
  animations: karaoke fill + fade, slide up, slide down, swoosh left, swoosh
  right, spring push, drop + bounce, zoom, character cascade, character wave,
  typewriter, flip, spin, squash, random, and none. `random` re-rolls the
  line motion for every line change and never repeats the previous one. The separate `line_transition` experiment and the
  near-duplicate Lyricify lookalikes are gone; every remaining preset has a
  visibly different motion in a one-line bar.
- Bold motions use the paint-only compositing props: clipped two-row pushes for
  slide/spring/drop, full-width horizontal swooshes, a zoom from 170%,
  spring/bounce overshoot curves, and the new `rotation` / `scaleX` / `scaleY`
  props for the flip, spin, and squash presets.
- Keep the configured lyric colors through every animation: outgoing and
  incoming rows share the karaoke palette, and word fill keeps running.
- Requires plugin API 52 (paint-only `translateX`/`translateY`, `scale`,
  `clip`). Older shells keep loading the 1.6.x release from the plugin source
  and its previous animations.

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
