# Changelog

All notable changes to **Media Lyrics** are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.7] — 2026-10-02

A seekable progress bar, a pinned mini panel, and two display fixes: the seek
no longer freezes after a rewind, and the lyric block no longer runs onto the
bottom edge of the panel.

### Added

- **Seekable progress bar** — the progress line under the artwork is now a real
  `ui.slider` (the same control the shell's own control-center media tab uses),
  so you can click anywhere on it to jump and drag to scrub. It spans the full
  inner width and reuses the existing `seekTo` transport, so lyric-line clicks
  and the keyboard cursor keep working through the same path. Replaces the
  display-only `ui.progress`: the host hands a plugin no click coordinates, and
  `ui.progress` takes no input, so a slider is the only canonical way to make
  the bar seekable. Thanks to @klntsky, whose seek-bar contribution pointed at
  the same missing capability.
- **Mini panel is now pinned** — `panel-mini` declares `persistent = true`, so
  the always-on karaoke chip survives opening another panel (the control centre,
  the launcher, …). Previously a normal panel was dismissed the moment any other
  panel opened, which made the "pin to desktop" placement unusable.

### Changed

- **Visible lyric lines: 9 / 12 / 16** (compact / medium / large) — down from
  10 / 14 / 16. The row budget is no longer a hardcoded count but is derived from
  the measured lyrics area and the real row pitch (29 px), so it can never
  overshoot the panel. Medium drops from 14 to 12 rows; the area simply does not
  fit 14.

### Fixed

- **The progress bar froze after a rewind** — after seeking (by dragging the bar
  or by clicking a lyric line) the bar could stay pinned to the target for the
  rest of the track. The pending-target hold tested "the player has NOT arrived
  yet?" first, so once playback ran *past* the target that condition became true
  again and the bar kept drawing the target; the branch that was supposed to
  release it also required the age timeout at the same instant, so it never ran.
  The hold now clears as soon as the player reaches the target (and still times
  out after 15 s if the seek is refused), and all three seek routes go through
  one entry point.

- **The last lyric line climbed onto the panel's bottom edge** — both the row
  budget and the empty slot heights were computed from a stale `fs × 1.25`
  estimate (27 px) while a rendered row measures 29 px, so a full block overshot
  the lyrics area by ~50 px and clipped. Every row height now comes from one
  measured pitch constant, and the countdown slot box uses it too.

## [0.9.6] — 2026-10-02

A layout pass over the header, lyric wrapping and the mini panel, plus the
karaoke centering feature and the lyrics-offset repair.

### Added

- **Karaoke centering + 3-2-1 countdown** - the active lyric line is pinned to
  the vertical centre of the lyrics area and the window is symmetric around it
  (the cursor while the user scrolls, otherwise the playing line): the first
  line starts centred on load, the anchor stays on the centre line through the
  track, and the last line returns to the centre at the end instead of sticking
  to the bottom edge. A 3-2-1 countdown is drawn in the free space above the
  centred first line, shown only in the last three seconds before it starts
  (never from the top of the track); a track whose first line begins within
  three seconds just starts at its real digit. Nothing is highlighted before
  the first line starts. Compact / medium / large only - panel-mini untouched.

### Fixed

- **Lyrics offset setting was inert and sign-inverted** - declared without
  min/max the host fell back to a 0..100 slider (a tenth of a second, no
  negative values), and `parseLrc` ADDED the offset while the description
  promises "positive shows lines earlier". Now `min = -2000` / `max = 2000`
  and the offset is SUBTRACTED, so positive shows lines earlier and negative
  later, matching the label.

- **Header: title now fills the whole slot width** - the marquee window was
  measured with a flat 0.72 em/char estimate, which over-runs mixed-case titles
  by ~30%, and the capacity also subtracted 26 px of button inner padding that
  `ui.label` does not have. A title therefore stopped ~90 px short of the
  transport block (only 132 px of a 224 px slot used). The window now uses the
  same measured per-glyph advance table as the lyric wrapper.
- **Header: uniform gaps and one cover size** - the info column was a fixed
  slot with a `flexGrow` spring beside it, so a truncated title sat next to
  ~127 px of dead space; gaps differed per preset (8/12/14) and compact ran a
  36 px cover while medium/large ran 50/56. The gaps are now a uniform 12 px and
  the cover is 50 px in every preset. The title/artist lines render as
  `ui.label` with `textAlign = "start"` (a stretched button centred its caption;
  `contentAlign` had no effect in a panel).
- **Lyric wrapping uses the real preset width and font metrics** - the compact
  panel wrapped long lines early: `LYR_WIDTH` was ~36 px under the measured
  surface width and the glyph table came from the fallback font, not Noto Sans
  (the actual UI font), overestimating mixed text by 5-6%. Widths are now
  440 / 520 / 640 and the advances are read from the font file, with the
  measured bold/medium bumps (1.062 / 1.023).
- **Wrap safety gutter** - a line whose advance width landed exactly on the
  content width rendered its last glyph flush against the panel border. The wrap
  budget now keeps a 24 px gutter (`WRAP_GUTTER`), so a flush-fitting line
  breaks where it should.
- **Mini panel** - a long lyric line ran past the panel edge (the label had no
  width bound); it now carries an explicit `maxWidth` so the host soft-wraps
  into the reserved second row, plus a 12 px gutter so the last glyph is not
  flush, and uniform margins (the root row added 8 px on top of the ~13 px host
  inset, so the text column now adds no padding of its own).
- **Hover highlight no longer lingers** - the background tint stayed behind
  after the pointer left a row. The hover cue is now a text colour/opacity
  shift only, which clears reliably and matches the active-line treatment.

## [0.9.5] — 2026-10-01

### Fixed

- **Album art from online players (Spotify, web players) now renders** — the
  MPRIS `art_url` may be an HTTP(S) URL rather than a local file, and
  `ui.image` renders local files only, so the panel drew an empty cover box.
  Remote artwork is now fetched into the plugin data directory (alternating
  `cover-0` / `cover-1` slots to dodge a stale read, memoised per URL, with an
  in-flight guard so a track change cancels a pending download). Local
  `file://` artwork is unaffected. Fixes #705.

## [0.9.4] — 2026-09-09

### Fixed

- **panel-mini: the cover no longer shifts down when the lyric line wraps** —
  the mini panel reserved no vertical space for the second lyric sub-line, so
  a wrapping line grew the info column and the root row's vertical centering
  moved the cover between renders. The lyric row now holds a fixed
  two-sub-line height, keeping the whole band layout constant.

### Added

- **Lyrics variants picker (switch on the fly)** — the header "list" button is
  now always visible while a track is loaded (previously it only appeared when
  the automatic chain ended with several tied LRCLIB search candidates, i.e.
  never for tracks whose lyrics loaded normally). Clicking it asks the service
  to fetch the full LRCLIB search result list on demand (`openLyricChoices`);
  the currently playing lyrics are never interrupted while the list loads.
  The selector shows a "Default (provider)" row — restoring the automatic
  chain result — plus deduplicated candidates (title — artist (album)), with
  the active variant marked. The list is kept in the snapshot after a pick,
  so variants can be switched again at any time without re-fetching. Picking
  a variant applies it through the same accept/cache path as the chain and
  survives the 150 ms poll (same track-key claim).
- Also accepts the fixed status contract: a `choose` snapshot with lyrics
  loaded (picker closed or a picked variant live) renders the karaoke/plain
  lyrics and the footer provider label instead of a false "No lyrics found".

### Fixed

- **`chooseLyrics` request crashed in the host** — the handler called
  `acceptAndCache`, a closure private to `loadLyricsForTrack` (nil at module
  scope), so applying a picked candidate would error. Variant application now
  uses the file-level `acceptLyrics` + `cacheLyrics` with the current track key.
- The bar-widget "current lyric line" chip now keeps working while the variant
  picker is open (`lyricsStatus == "choose"` with live lyrics is accepted).

## [0.9.3] — 2026-09-06

### Changed

- **plugin_api 24 → 30** — the plugin now declares the full Noctalia 5.0.1
  plugin API (context menus, graph pointer tracking, panel layer). Requires
  Noctalia 5.0.1+.
- **Lyrics panel floats above fullscreen content** — all three panel presets
  (`panel`, `panel-compact`, `panel-large`) declare `layer = "overlay"`, so
  the lyrics window stays visible over fullscreen video (karaoke over a
  film/YouTube). A per-entry **Layer** dropdown in Settings → Plugins can
  switch any preset back to `top` without editing the manifest.

## [0.9.2] — 2026-09-06

### Added

- **Current lyric line in the bar chip** — new widget setting
  `show_lyric_line` (off by default; widget settings popup, visible when the
  chip shows text). When on and synced lyrics are ready, the chip shows
  `Title · <current line>` instead of `Title - Artist`; the line steps with
  the playback position (snapshot polls every 150 ms) and long lines scroll
  with the existing marquee. Falls back to the artist line while lyrics are
  not ready or unsynced.
- **Embedded MPRIS lyrics (`xesam:asText`)** — a zero-network source: players
  that embed lyrics in their own `Metadata` (the Noctalia aggregator does not
  forward the field, so the service asks the player bus directly, once per
  track change) feed the chain at position 2:
  local `.lrc` → **embedded** → cache → LRCLIB exact → LRCLIB search →
  NetEase. Footer provider label: "Embedded". Placeholders are filtered like
  any other source. (Few players ship `xesam:asText` today; LRCLIB remains
  the workhorse.)

## [0.9.1] — 2026-09-05

### Added

- **NetEase Cloud Music fallback source** — when LRCLIB finds nothing (or a
  transport error occurs), the service queries NetEase's public
  cloudsearch/lyric endpoints (no API key; browser User-Agent + Referer only)
  and accepts the best-ranked candidate. Synced LRC wins over plain text;
  candidates are ranked by title/artist match plus a duration bonus against
  the playing track; NetEase LRC metadata lines (作词/作曲/Artist: …) are
  stripped before parsing. The chain is: local `.lrc` → cache → LRCLIB exact
  → LRCLIB search → NetEase fallback.
- **Instrumental / placeholder guard** — NetEase's placeholder "lyrics" for
  instrumentals and missing words (纯音乐/暂无歌词) are filtered both at fetch
  time and at cache-read time, so a cached placeholder cannot short-circuit
  the chain into a fake "no lyrics".

### Changed

- `service.lyrics-unreachable` copy: "LRCLIB unreachable" → "Lyrics services
  unreachable" (LRCLIB is no longer the only network source).

## [0.9.0] — 2026-09-03

### Added

- **Bar widget album cover** — the `now-playing` chip shows the artwork
  (squircle, ~0.62 em glyph budget for text, `noctalia.fileExists` guard with
  a state-glyph fallback when the art is missing; render deduped by a content
  key so the 150 ms service publishes never flicker the chip). Paused
  playback dims the chip like the built-in media widget.
- **Widget display settings** — the same knobs as the shell's built-in media
  widget, edited in the widget's own settings popup (middle click):
  `album_art_only`, `hide_album_art`, `hide_artist`, `artist_first`,
  `min_length`, `max_length`, `art_size`, `title_scroll` (none/always/on
  hover), `hide_when_no_media` (chip hides via `barWidget.setVisible`).
- **Gesture parity with the built-in media widget** — right click toggles
  play/pause, mouse back/forward and the wheel skip tracks (declared in
  `[widget.actions]` so they show up in the settings editor); middle click is
  left to the host default `settings-open-widget`. Vertical bars show the
  artwork only (like `media_widget.cpp`: `artOnly = isVertical`).

### Fixed

- **Chip stayed dimmed after resume** — the paused-dim `opacity` was sent as
  `nil` on resume, and the host reads a nil prop as "unchanged", leaving the
  0.65 dim applied forever. Opacity is now always an explicit number
  (`m.playing and 1 or 0.65`); verified live (play → pause → resume pixel
  luminance returns to baseline).
- Bar widget now shows the artist too (default `Title - Artist`), matching
  the built-in widget, instead of the title alone.

## [0.8.13] — 2026-09-02

### Fixed

- **Review-hardening round 2** (community review prep):
  - i18n coverage extended: widget title fallback, panel "Unknown artist",
    and the footer provider labels ("Local"/"Cache") now route through
    `noctalia.tr()` (keys: `common.*`, `provider.*`).
  - Network failures are no longer reported as "no lyrics found": a
    transport error (curl exit ≠ 0 and ≠ 22) surfaces
    `service.lyrics-unreachable` through the lyrics-error state, which the
    panel now reaches for the first time.
  - No nil children in the UI tree: the unsynced-list chevron was emitted
    as `cond and node or nil` inside a children array (the host logs
    "ui tree node is not a table"); children are now appended conditionally.
  - UTF-8-safe cuts: `wrapLyric` hard-slices and the bar-widget title
    truncation never split a multi-byte sequence (Cyrillic titles/lines).
  - Karaoke class (font size/weight) is precomputed once into arrays shared
    by the window budget and the render loop — they cannot drift apart.
  - README/docs: "14 visible lines" corrected to 10/14/16 per preset; the
    "Bilingual UI (en/ru)" claim softened to "translatable via Noctalia
    i18n" (no ru file ships by community rule); stale comments in
    plugin.toml/service.luau/panel.luau updated (150 ms poll, no "ring",
    no "zero external tools").

## [0.8.12] — 2026-09-02

### Fixed

- **README Plugin section documents every panel entry** — the Plugin table
  now lists `panel`, `panel-compact` and `panel-large` (the size presets
  added in 0.8.7); the community `validate` CI requires each panel entry id
  to appear in the README.

## [0.8.11] — 2026-09-02

### Fixed

- **Long lyric lines no longer spill past the panel edge** (reported live on
  the compact preset): a `ui.label` wider than the panel is clipped at the
  surface edge, cutting 47+ char lines mid-word. The host does not auto-wrap,
  so long lines are now soft-wrapped into balanced sub-lines via `\n`
  (verified that `ui.label` renders `\n`). The wrap budget uses a glyph
  advance factor of ~0.62 em measured live at scale 1.5 (bold 0.66) and
  per-preset content widths (compact 404 / medium 484 / large 604).
- **Karaoke window now fits a vertical sub-line budget** — the visible
  window shrinks when wrapped lines would push the active line below the
  panel edge (previously the fixed 10/14/16-row window could clip the
  bottom rows once lines wrapped).

## [0.8.10] — 2026-09-02

### Fixed

- **Community review compliance** (noctalia-dev/community-plugins #592):
  - `curl` now declared in `dependencies` and the README Requirements —
    the service spawns it for LRCLIB fetches (`-sSf -m 8 -4`, argv-only, no
    shell). `sleep` (coreutils) documented in the README Notes.
  - Plugin description no longer claims "no external dependencies" — it
    states the real runtime needs (`busctl` + `curl`).
  - Panel chrome is fully routed through `noctalia.tr()` with keys in
    `translations/en.json` ("Loading lyrics…", "Lyrics error: ", "No lyrics
    found", "No media player", "(no title)", "NOW PLAYING", "Reload lyrics",
    "synced"/"unsynced") — other locales can now be provided via Noctalia
    Translate instead of rendering hardcoded English.
  - Thumbnail regenerated with the official thumbnail generator
    (assets.noctalia.dev, 960×540 WebP).

## [0.8.9] — 2026-09-01

### Fixed

- **Compact panel: layout fix actually wired up** — `panelLayout()` was
  defined but never used in `buildInfoRow`; the header still rendered with
  the fixed 520px metrics and the transport block stayed clipped at 440px.
  `buildInfoRow` now applies the preset layout (cover size, gap, text width,
  transport button sizes, no-player row height).

## [0.8.8] — 2026-09-01

### Fixed

- **Compact panel: transport block clipped** — the header (cover + title +
  transport + time) overflowed 440px. `panelLayout()` now scales cover size,
  text column width and transport button sizes per preset (compact 36/168/14,
  medium 50/286/18, large 56/370/20); the disc placeholder glyph scales too.
- **Per-preset placement/position settings removed** — only the medium
  `panel` declares `placement`/`position`; compact and large inherit the
  default so the settings UI shows one placement/position block, not three.

## [0.8.7] — 2026-09-01

### Added

- **Panel size presets** — `panel_size` setting (compact 440 / medium 520 /
  large 640) selects which panel preset the bar widget and control-center
  tile open. Three `[[panel]]` entries share one `panel.luau`; the visible
  lyric lines scale with the preset (10 / 14 / 16). Medium keeps the
  historical `panel` id for IPC compatibility.

## [0.8.5] — 2026-09-01

### Added

- **Clickable lyric lines** — click a synced line to seek the player to that
  timestamp. Lines without a timestamp (plain lyrics) are not clickable.
  Implemented as a `ui.row` click target wrapping the label — `ui.label`
  takes no `onClick` and `ui.button` ignores `color`/`fontWeight` (would
  break the karaoke gradient).
- **Manual lyric scroll + line selection** — Up/Down step the lyric cursor
  (highlighted with a chevron marker), Return/Space seek to the cursor line.
  Works for synced AND plain lyrics (plain: highlight only, no seek).
  Before the first timestamp the window starts at line 1 (was frozen).
  `keyboard_focus = "exclusive"` so the panel receives keys; the host's chord
  validator accepts only basic names (PageUp/PageDown/Home/End are rejected
  and would drop the plugin from the store).
- `onScroll` declared on the panel (the host documents it as bar-widget-only;
  if a future build delivers wheel events, scrolling steps the cursor).

### Fixed

- **Seek used the wrong D-Bus method** — `SeekActive` is RELATIVE (MPRIS
  Seek): seeking to a line jumped by the timestamp instead of to it. Now uses
  `SetPositionActive` (ABSOLUTE, verified live: 2:00 lands at 2:00).
- **`busctlCall` dropped the D-Bus signature** — typed arguments were passed
  without their type (`SetPositionActive 90000000` instead of
  `SetPositionActive x 90000000`), so busctl failed with «Too few parameters
  for signature» and seek/shuffle/loop silently did nothing. Now the type is
  passed for every argument (`b`, `s`, `x`).
- **Bar widget mixed render() and setGlyph/setText** — the host warns that
  setGlyph/setText have no visible effect once a render() tree is active;
  the empty state now renders a disc glyph tree too.

## [0.8.3] — 2026-09-01

### Changed

- `dependencies = ["busctl"]` declared in the manifest (community-plugins
  review rule: every shelled-out command must be declared).
- `description` fixed — «ring progress» was removed in v0.8.0 (replaced by
  the header progress bar); catalog copy now reads «progress bar» (111/120).

### Removed

- `translations/ru.json` — community rule is en.json only; other locales are
  handled via Noctalia Translate.
- ROADMAP link from the plugin README (roadmap lives outside the plugin
  directory in the community-plugins layout).

## [0.8.1] — 2026-09-01

### Changed

- Bar widget honors the instance's `Color` / `Icon Color` settings: explicit
  color roles removed from the `barWidget.render()` tree (they silently
  ignored the user's per-widget color configuration; the host colors the
  built-in glyph/text row, which the empty state already used).
- `[widget.actions] middle = "none"` declared in the manifest — the host
  default (`settings-open-widget`) swallowed `onMiddleClick`, so middle-click
  play/pause never fired out of the box.

### Removed

- Custom URL from the planned additional lyric sources (contradicts the
  install-and-use philosophy).

## [0.8.0] — 2026-09-01

### Added

- Marquee (scrolling) titles for long track/artist names: 2 s static hold,
  then slow scroll; per-slice button keys prevent glyph overlap.
- Per-font-size marquee capacity and speed (`vwUnits(fs)`, `MARQUEE_SPEED/fs`).
- `singleLine` sanitizer for MPRIS metadata containing embedded newlines.
- Progress bar between header and lyrics (replaces the old separator).
- Localization: English + Russian UI strings.
- Screenshots, thumbnail, docs (`ROADMAP.md`), MIT license — publication-ready.

### Changed

- Visible lyric lines: 11 → 14 (carousel window).
- Lyric timing: marquee clock driven by `watch("media")` publishes
  (the host never calls panel `update()`); service publish cadence 500 → 150 ms
  for smooth animation.
- Title/artist pinned flush-left via ghost buttons with `contentAlign="start"`
  (host ignores `textAlign` on labels).
- Lyric source fallback: LRCLIB `/api/get` → `/api/search` → local `.lrc` → cache.

### Fixed

- Lyric lines wrapping and letter overlap (newline sanitizer, integer
  button heights, per-slice keys).
- Marquee not starting (host tick probe: `update()` never called on panels).
- Titles/artists drifting to center or clipping on long names.
- Progress ring under the cover removed; progress bar layout stable.

### Removed

- Shuffle/repeat randomness, progress seek buckets, cover progress ring
  (replaced by the header progress bar).
