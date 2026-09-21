# Lyrics Desktop

Lyrics Desktop is a Noctalia desktop widget that displays synchronized song lyrics using MPRIS media players.

It automatically detects currently playing media through `playerctl`, retrieves lyrics from LRCLIB, caches them locally, and keeps timed lyrics synchronized with playback.

## Features

* Synchronized LRC lyrics with automatic line progression.
* Plain-text lyrics fallback when synchronized lyrics are unavailable.
* Automatic lyric lookup using song title and artist.
* LRCLIB search fallback when an exact track lookup does not return lyrics.
* Local lyric cache to avoid repeatedly downloading lyrics.
* Supports up to two MPRIS players simultaneously.
* Independent playback clock for smooth lyric progression between MPRIS queries.
* Automatic seek detection and synchronization recovery.
* Preserves loaded lyrics when seeking instead of downloading them again.
* Configurable number of lyric lines displayed above and below the current line.
* Configurable colors, font sizes, opacity, and widget width.
* Works with any MPRIS-compatible player supported by `playerctl`.

## Requirements

* Noctalia with desktop widget support.
* `playerctl`.
* An MPRIS-compatible media player.
* Internet access when lyrics are not already present in the local cache.

The plugin expects `playerctl` at:

```text
/run/current-system/sw/bin/playerctl
```

## Plugin

| Field      | Value                    |
| ---------- | ------------------------ |
| ID         | `dinho/lyrics-desktop` |
| Name       | `Lyrics Desktop`         |
| Entry      | Desktop widget: `lyrics` |
| Dependency | `playerctl`              |
| Plugin API | `23`                     |
| License    | `MIT`                    |

## Usage

Add **Lyrics Desktop** from Noctalia's desktop widget picker.

Once a compatible media player is playing a track, the widget automatically:

1. Detects the player through MPRIS.
2. Reads the title, artist, playback status, and position through `playerctl`.
3. Looks up lyrics using the track title and artist.
4. Uses synchronized lyrics when available.
5. Falls back to plain lyrics when synchronized lyrics are unavailable.
6. Saves the result to the local cache.
7. Displays and synchronizes the lyrics with playback.

No manual lyric lookup is required.

## Lyrics Sources

Lyrics are retrieved from **LRCLIB**.

The plugin first attempts an exact track lookup using the title and artist. If that request does not provide lyrics, it performs a broader search and looks for synchronized lyrics first, followed by plain lyrics.

For synchronized lyrics, the plugin parses LRC timestamps and uses them to determine the currently active line.

If only plain lyrics are available, the lyrics are displayed without timed synchronization.

## Local Cache

Lyrics are cached under:

```text
~/.cache/noctalia/lyrics/
```

The plugin maintains two cache files:

```text
~/.cache/noctalia/lyrics/lyrics_1.lrc
~/.cache/noctalia/lyrics/lyrics_2.lrc
```

One file is associated with each supported player slot.

The cache allows lyrics to remain available locally after they have been retrieved.

## Synchronization

The widget uses the MPRIS playback position as its external timing reference while maintaining a continuously advancing local display clock.

MPRIS is queried periodically rather than for every rendered frame. Between queries, the local clock advances through Noctalia's frame tick system, allowing the lyrics to progress smoothly.

Small differences between the MPRIS position and the local display clock are ignored to prevent the active lyric line from constantly jumping forward and backward.

Larger discrepancies are treated as seeks.

### Seek Recovery

When a seek is detected, the plugin does not:

* restart the plugin;
* delete the cached lyrics;
* download the lyrics again;
* reload the lyrics from LRCLIB.

Instead, it temporarily enters a recovery state and performs a short pause/play cycle through `playerctl`:

```text
Playing
   ↓
Paused
   ↓
Playing
```

The first reliable MPRIS position received after the player returns to `Playing` becomes the new synchronization reference.

This allows the already-loaded LRC data to remain in memory while the playback clock is resynchronized.

## Multiple Players

The plugin maintains two independent player slots.

Each slot stores its own:

* MPRIS player;
* title and artist;
* playback position;
* lyrics;
* lyric loading state;
* synchronization reference;
* current lyric line;
* seek recovery state;
* cache file.

The active slot follows the currently playing player.

## Settings

| Setting               | Type    |     Default | Description                                             |
| --------------------- | ------- | ----------: | ------------------------------------------------------- |
| `current_color`       | `color` |   `primary` | Color of the currently active lyric line.               |
| `secondary_color`     | `color` | `secondary` | Color of the surrounding lyric lines.                   |
| `width`               | `int`   |       `700` | Controls the width of the lyrics widget.                |
| `current_font_size`   | `int`   |        `36` | Font size of the currently active lyric line.           |
| `secondary_font_size` | `int`   |        `27` | Font size of surrounding lyric lines.                   |
| `current_opacity`     | `int`   |       `100` | Opacity of the currently active lyric line.             |
| `secondary_opacity`   | `int`   |        `73` | Opacity of surrounding lyric lines.                     |
| `lines_above`         | `int`   |         `2` | Number of lyric lines displayed above the current line. |
| `lines_below`         | `int`   |         `2` | Number of lyric lines displayed below the current line. |

### Width

The `width` setting uses a `0–1000` range and is converted to the widget's actual width.

The resulting widget width ranges from approximately:

```text
300 px → 1200 px
```

### Lyric Lines

`lines_above` and `lines_below` control how many surrounding lyric lines are rendered around the active line.

For example, with both values set to `2`, the widget displays:

```text
line above
line above
CURRENT LINE
line below
line below
```

## Lyric States

The widget displays different states depending on the current player and lyric availability:

* **No player** — no compatible player is currently detected.
* **Searching** — lyrics are being retrieved.
* **Lyrics** — lyrics are available and being synchronized.
* **Paused** — playback is paused while the current lyric position is preserved.
* **Not found** — no lyrics were found for the current track.

## Player Detection

Player information is collected through:

```text
playerctl -a metadata
```

The plugin reads:

* playback status;
* title;
* artist;
* playback position;
* player name.

This makes the widget independent of any specific media application as long as the player exposes the required information through MPRIS.

## Notes

The plugin communicates with the LRCLIB service to retrieve lyrics when they are not already available in the local cache.

Lyrics are cached locally under `~/.cache/noctalia/lyrics/`. The plugin creates and updates cache files for its two supported player slots.

The plugin uses `playerctl` to read MPRIS metadata and to perform the short pause/play recovery cycle used after detected seeks.

No user credentials or authentication tokens are required. The plugin does not upload local files or cached lyrics to LRCLIB; network requests are used only to retrieve lyrics.

## License

MIT
, and rejected-type targets).
