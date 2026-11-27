# Desktop Lyrics

Time-synced lyrics for whatever your MPRIS player is doing, drawn by Noctalia itself. A background service reads the shell's active player, prefers a `.lrc`/`.elrc` file sitting next to the audio file, falls back to LRCLIB, and publishes the current line, the next one and karaoke progress to a desktop widget, a bar widget and a control panel.

Two things set it apart: the overlay is a real desktop widget, not a panel that has to stay open, and there is no daemon — local lyric files work offline, word by word when they carry word timestamps. The only program it ever starts is the optional wallpaper sampler described under Requirements.

## Plugin

| Field | Value |
| --- | --- |
| ID | `alitura/desktop-lyrics` |
| Entries | Service: `service`; desktop widget: `lyrics`; overlay layer: `overlay`; bar widget: `bar`; panel: `controls`; shortcut: `toggle` |

## Requirements

None for the desktop widget and the bar: the player comes from `noctalia.mediaPlayer()`, lyrics from `noctalia.http` against `lrclib.net`, and colours from the shell palette.

The optional full-screen overlay reads the wallpaper once per change to place the lyrics in its empty areas, which needs the `imagemagick` dependency (`magick` or `convert`) or **ffmpeg**. Each sample is one short-lived run that writes a 48x27 RGB frame to `<pluginDataDir>/wallpaper.rgb` and exits; nothing stays resident. Without either tool the overlay still works, starts no process and uses the centre zone.

## Usage

1. Enable the plugin:

   ```sh
   noctalia msg plugins enable alitura/desktop-lyrics
   ```

2. Add the desktop widget named **Lyrics** (`lyrics`) from the desktop widget editor. It keeps itself hidden while nothing is playing and while the plugin is off.
3. Optionally add the **Lyrics** bar widget (`bar`) next to your media widget. It shows the active line, hides when there is nothing to show, and opens the panel when clicked.
4. Open the control panel at any time:

   ```sh
   noctalia msg panel-toggle alitura/desktop-lyrics:controls
   ```

   The panel shows the track, the current / previous / next line, the sync offset and the source, plus **Refresh**, **Copy line** and **Settings** buttons.

5. The control-centre shortcut `toggle` hides or restores the overlay without changing your saved settings. Add it from Settings → Control Center shortcuts. Right-clicking it opens the panel.

## Overlay

The `overlay` layer entry draws the same synced lines on a full-screen, input-transparent
surface instead of inside a placed widget, so the block can sit anywhere on the wallpaper.

1. Turn on **Desktop overlay** (`overlay_enabled`) in the plugin settings. The service shows
   the layer only while a track with lyrics is playing and hides it again afterwards, so no
   surface exists while nothing plays.
2. With **Wallpaper-aware placement** (`wallpaper_aware`) on, the service keeps an eye on the
   wallpaper path while the feature is on, samples it once per change into a 48x27 frame at
   `<pluginDataDir>/wallpaper.rgb`, scores every screen zone by the detail under the type
   block, and publishes the calm zones. The overlay roams those zones, one per line, and
   skips the busy subject in the middle. If sampling is turned off, fails or finds no tool,
   the published zones are cleared and the overlay returns to the centre.
3. **Roaming order** (`wallpaper_order`) chooses between a sequential tour of the calm zones
   and a random shuffle.

Positioning is done with `ui.column` alignment and a margin, so the overlay keeps working in
every shell theme and needs no compositor-specific rules.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `bool` | `true` | Master switch for the desktop overlay and the bar widget. |
| `font_size` | `int` | `44` | Active line size in pixels on the desktop (18–120). |
| `max_lines` | `int` | `3` | Context lines the overlay may draw at once (1–6). |
| `display_mode` | `select` | `karaoke` | `karaoke` fills the line as it is sung, `line` keeps previous and next lines, `focus` shows one line only. |
| `text_align` | `select` | `center` | Alignment of the lyric block: `center`, `start` (left) or `end` (right). |
| `show_next_line` | `bool` | `true` | Dim preview of the upcoming line. |
| `hide_on_pause` | `bool` | `true` | Fade the lyrics out 1.5 s after playback pauses and bring them back when it resumes. |
| `show_title` | `bool` | `false` | Print track title and artist above the lyrics. |
| `show_progress` | `bool` | `true` | Karaoke fill for the active line and a thin playback bar in the other modes. |
| `sync_offset` | `int` | `0` | Timing shift in milliseconds (-2000…2000); negative values show lines earlier. |
| `filter_mode` | `select` | `allowAll` | `allowAll` accepts every source, `whitelist` accepts known media sites plus `custom_domains`. |
| `custom_domains` | `string_list` | empty | Extra domains treated as valid media sources in whitelist mode. |
| `disabled_domains` | `string_list` | empty | Hosts that never trigger lyrics, in either mode. Matched on the host only (lower case, trailing root dot and any port or credentials ignored), so none of those can bypass the block. |
| `disabled_players` | `string_list` | empty | MPRIS identities or bus-name fragments to ignore. |
| `local_lyrics` | `bool` | `true` | Read a `.lrc`/`.elrc` file next to the playing audio file before asking LRCLIB. |
| `cache_enabled` | `bool` | `true` | Cache LRCLIB answers in the plugin data directory. |
| `overlay_enabled` | `bool` | `false` | Draw the lyrics on the full-screen overlay layer instead of a placed desktop widget. |
| `overlay_font_size` | `int` | `52` | Active line size of the overlay, in pixels (18–140). |
| `overlay_margin` | `int` | `80` | Free space between the overlay text and the screen edge, in pixels (0–400). |
| `wallpaper_aware` | `bool` | `true` | Sample the wallpaper once per change and keep the overlay in its calm, empty zones. |
| `wallpaper_order` | `select` | `tour` | `tour` visits the calm zones in order, `shuffle` hops between them. |

## Notes

- **Local files:** for a local track (`xesam:url` = `file:///…` or `file://localhost/…`), `<name>.lrc` and then `<name>.elrc` next to the audio file are used before anything else and are never cached, so edits show up on the next track change. A `file://` URL naming another host is ignored, and a sidecar is only read when it is a regular, non-empty file up to 512 KiB. With `local_lyrics` off, the LRCLIB lookup is used directly.
- **Word timing:** enhanced LRC (`[00:12.34]<00:12.34>word`) drives the karaoke fill through `ui.fillLabel`'s `fillRanges`: one segment per timed word, so each word fills only while it is being sung. Plain LRC still fills the line linearly.
- **Network:** `lrclib.net` only. The exact lookup (`/api/get`) and the search fallback (`/api/search`) start together under one 2.5 s deadline, and the exact answer always wins; a search hit is accepted only when its normalized title matches exactly, its first artist matches and its duration is present and within 3 s, and only accepted answers are cached. Repeat plays are served from disk; **Refresh** rereads the sidecar and skips the network cache so it really asks LRCLIB again.
- **Filesystem:** reads `<track>.lrc` / `<track>.elrc` next to a locally played audio file when `local_lyrics` is on. Writes only inside Noctalia's plugin data directory (`cache/` plus an `index.json` of cached track keys, and `wallpaper.rgb` while wallpaper-aware placement is on); file names are derived from the track key. The active media URL is tracked separately from the cache key, so two local files with identical tags still load their own sidecar.
- **Sidecar size:** the 512 KiB ceiling is checked with `noctalia.fileInfo` before the read and again on the result. Luau's `readFile` has no open-with-limit form, so a file replaced between the check and the read is not bounded during that read; a FIFO is still rejected up front because it reports size 0.
- **Processes:** none by default. With `wallpaper_aware` on, one `magick`, `convert` or `ffmpeg` runs per wallpaper change and writes `<pluginDataDir>/wallpaper.rgb`, then exits. No `playerctl`, `curl`, daemon or Python helper is used.
- **Unsynced tracks:** when LRCLIB only has plain lyrics, the overlay stays hidden and the panel says so; there is nothing to time.
- **Browsers:** source filtering needs `xesam:url` in the MPRIS metadata. Source URLs are matched against the built-in list and your custom domains.

## Acknowledgment

The cinematic renderer this overlay's look grew out of is a separate Quickshell/QML project: <https://github.com/alitura1/noctalia-lyrics-3d>.
