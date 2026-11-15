# Noctalia Synced Lyrics Bar Plugin

A native, high-performance plugin for **Noctalia Shell** that displays synchronized karaoke lyrics right on your Wayland bar.

Features **syllable-level synchronization** (word-by-word / syllable-by-syllable live karaoke highlighting) inspired by Apple Music, with seamless fallback to line-synced lyrics, multi-source provider selection popup panel, and automatic hiding when media playback stops.

---

## Features

- **True Syllable-Level Karaoke Syncing**: Each syllable and word highlights and sweeps letter-by-letter in real time with high-precision time interpolation as the artist sings.
- **Multi-Provider Architecture**:
  - **Spicy Lyrics (`api.spicylyrics.org`)**: Syllable-level Apple Music / Musixmatch karaoke lyrics via Spotify Track ID (tested & verified on **"Pattern Recognition" by Neuro-sama feat. ODDEEO**).
  - **`binimum / am-lyrics` (`lrc.red`, `lyrics-api.binimum.org`)**: Apple Music TTML via metadata matching, ISRC, or direct song records.
  - **`LyricsPlus` (`lyricsplus.binimum.org`)**: Word- or line-synced fallback using title, artist, album, duration, and optional ISRC.
  - **`BetterLyrics` (`api.betterlyrics.org`)**: Syllable-level TTML (supports public cache and optional `X-API-Key`).
  - **`Unison` (`unison.betterlyrics.org`)**: Community LRC/TTML fallback.
  - **`LRCLIB` (`lrclib.net`)**: Universal line-synced lyrics fallback.
  - **`Genius`**: Plain-text fallback through the public am-lyrics Genius worker.
  - **Local Cache**: Instant zero-network lookup for previously cached songs in `~/.cache/noctalia/lyrics/` and plugin cache.
- **Automated Spotify Track ID Resolver**:
  - Automatically extracts 22-character Spotify track IDs from MPRIS (`mpris:trackid` / `xesam:url`) when Spotify is running.
  - For non-Spotify streaming players (YouTube, Tidal, local files, browser, etc.), automatically resolves Spotify track IDs using DuckDuckGo open.spotify.com lookup verified against Spotify's public track page without requiring Spotify Premium.
  - Passes available MPRIS ISRC and track duration to metadata-based providers, so local and non-Spotify tracks can use lrc.red, BiniLyrics, LyricsPlus, Unison, and LRCLIB without a Spotify ID.
  - Also supports Spotify Search API client credentials if configured.
- **Interactive Source Picker Popup Panel (github-kanban style)**:
  - **Click Bar Widget**: Opens an attached pop-up panel displaying all providers that returned lyrics for the track.
  - Each source card shows the provider name, a badge (`Karaoke (Syllable)` vs `Line-synced`), active checkmark indicator, and the first 2–3 preview lines of lyrics.
  - Clicking any provider card switches the active lyrics instantly and closes the panel.
- **Smart Auto-Hide**: Automatically hides from the bar when no player is running or media stops, consuming zero bar space.
- **Bar Mouse Controls**:
  - **Left Click**: Opens the lyrics source selection panel.
  - **Scroll Up**: Increase timing offset (shift lyrics earlier to compensate for lagging lyrics).
  - **Scroll Down**: Decrease timing offset (shift lyrics later).
  - **Live Feedback**: Scrolling briefly displays a millisecond badge (e.g. `[+150ms]`) directly on the bar while lyrics highlight in real time.
  - **Hover Tooltip**: Displays current track, artist, status, active provider, and current timing offset.
- **Lightweight & Battery Friendly**:
  - Runs a 30ms (~33fps) fluid animation tick rate during playback.
  - Automatically throttles to 1000ms idle interval when paused or stopped.
  - Interpolates playback position locally to eliminate process spam.
- **Adaptive Noctalia Theming**: Seamlessly uses Noctalia theme tokens (`primary`, `on_surface`, `on_surface_variant`, `outline_variant`, etc.).

---

## Plugin

| Field   | Value                           |
| ------- | ------------------------------- |
| ID      | `kaler/synced-lyrics`           |
| Widget  | `lyrics` (bar)                  |
| Panel   | `lyrics-panel`                  |

**Widgets**:
- `kaler/synced-lyrics:lyrics` — The main bar widget showing synced lyrics

**Panels**:
- `kaler/synced-lyrics:lyrics-panel` — Source selection panel (opens on left-click of the widget)

**Command to toggle the panel**:
```bash
noctalia msg panel-toggle kaler/synced-lyrics:lyrics-panel
```

---

## Requirements

- Noctalia v5.0.0 or higher.
- **`python3`** — Required for the lyric fetching scripts.
- **`busctl`** — Required to query Noctalia's MPRIS service for track metadata (part of `systemd`).

Ensure all are installed and available in your PATH:

```bash
# On Arch-based systems (including Nyarch)
sudo pacman -S python systemd

# On Debian/Ubuntu
sudo apt install python3 systemd

# On Fedora
sudo dnf install python3 systemd
```

---

## Usage

### 1. Enable the Plugin in Noctalia

The plugin is deployed to:
`~/.local/state/noctalia/plugins/materialized/community/synced-lyrics/`

Ensure `"kaler/synced-lyrics"` is present in your `[plugins].enabled` array in `~/.local/state/noctalia/settings.toml`:

```toml
[plugins]
enabled = [
  "kaler/synced-lyrics",
  # ... other plugins
]
```

### 2. Add the Widget to Your Bar

In `~/.local/state/noctalia/settings.toml`:

1. Define the widget:
```toml
[widget.lyrics]
type = "kaler/synced-lyrics:lyrics"
```

2. Add `"lyrics"` to your bar's `start`, `center`, or `end` lane:
```toml
[bar.top-bar]
center = [ "clock", "lyrics" ]
```

When Noctalia starts or reloads, the widget will automatically appear whenever a song plays!

### 3. Using the Plugin

- **Left-click** the widget to open the lyrics source selection panel
- **Scroll** on the widget to adjust timing offset (shift lyrics earlier/later)
- Open the panel via command: `noctalia msg panel-toggle kaler/synced-lyrics:lyrics-panel`

### 4. Configure Settings

Open Noctalia Settings GUI or edit `settings.toml` directly. See [## Settings](#settings) for all available options.

---

## Settings

Configurable via Noctalia Settings GUI or in your `settings.toml`:

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `auto_hide` | `bool` | `true` | Hide the bar widget when media is stopped or no player is open. |
| `hide_when_paused` | `bool` | `true` | Also hide the bar widget when media is paused. |
| `max_words` | `int` | `6` | Maximum number of words displayed before shifting onto the next line chunk/page. |
| `word_wrapping_mode` | `select` | `"words"` | Strategy for splitting long lyric lines across the bar: `"words"` (shift after max words), `"chars"` (sliding window), or `"full"` (no wrapping). |
| `font_size` | `int` | `12` | Text size of lyrics displayed on the bar. |
| `smooth_sweep` | `bool` | `true` | Progressive character-by-character color sweep across syllables in real time. |
| `show_countdown` | `bool` | `true` | Display seconds remaining until the first vocal line starts. |
| `timing_offset_ms` | `int` | `0` | Manual timing offset in milliseconds (range: `-10000` to `+10000` ms). Also dynamically adjusted via mouse wheel scroll on the bar widget. |
| `scroll_offset_step_ms` | `int` | `50` | Milliseconds added or subtracted per mouse wheel scroll notch (default: `50ms`). |
| `invert_scroll` | `bool` | `false` | Invert mouse wheel scroll direction for timing offset adjustment. |
| `preferred_source` | `select` | `"auto"` | Preferred lyric provider: `"auto"`, `"spicylyrics"`, `"binimum"`, `"lyricsplus"`, `"betterlyrics"`, `"unison"`, `"lrclib"`, or `"genius"`. |
| `spicy_lyrics_api_key` | `string` | *(user key configured)* | API key for querying syllable-level lyrics on api.spicylyrics.org. |
| `spotify_client_id` | `string` | `""` | Optional Spotify app Client ID for track ID resolution. |
| `spotify_client_secret` | `string` | `""` | Optional Spotify app Client Secret for track ID resolution. |
| `betterlyrics_api_key` | `string` | `""` | Optional API key for uncached BetterLyrics requests. |
| `active_color` | `string` | `"primary"` | Theme color token for the currently sung syllable/word. |
| `sung_color` | `string` | `"on_surface"` | Theme color token for already completed syllables. |
| `upcoming_color` | `string` | `"on_surface_variant"` | Theme color token for upcoming syllables in the line. |
| `max_chars` | `int` | `34` | Maximum characters visible on the bar before sliding windowing (when using character limit mode). |
| `show_glyph` | `bool` | `true` | Show music glyph next to active lyrics. |
| `parsenix_base_url` | `string` | `"https://noctalialyrics.vercel.app"` | Base URL of your deployed Parsenix Spotify Lyrics API instance. Requires SP_DC cookie configured server-side. |