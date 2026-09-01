# Changelog

## 1.5.0

- Move display mode, lyric layers, karaoke, animation, scrolling, sizing,
  typography, spacing, cue text, and alignment into per-widget settings.
- Keep lyric sources, player selection, timing, polling, and credentials shared
  by the singleton background service.
- Continue fetching lyrics when one widget uses track-only mode so other widget
  instances can display synchronized lyrics.
- Existing 1.4 display settings must be reapplied for each lyrics widget after
  upgrading; source and service settings are unchanged.

## 1.4.3

- Add an option to hide the fallback glyph when album artwork is unavailable.
- Hide the glyph picker while fallback glyph display is disabled.
- Add vertical mouse-wheel controls for switching to the next or previous track.

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
