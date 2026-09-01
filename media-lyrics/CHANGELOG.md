# Changelog

All notable changes to **Media Lyrics** are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
