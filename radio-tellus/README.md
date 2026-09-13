# Radio Tellus

Browse and play community-maintained internet radio by country, genre, and
mood. Radio Tellus provides recent popular stations, while Favorites and
Recent history lets you keep track of your listening.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mirenel/radio-tellus` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `player-status`; launcher provider: `launcher` |
| Launcher Prefix | `/radio` |

## Requirements

- Required on `PATH` for playback: `bash`, `chmod`, `dirname`, `env`, `head`, `ip`, `mkdir`, `mpv`, `python3`, `rm`, `rmdir`, `setpriv`, `sh`, `sleep`, and `socat`
- A working PulseAudio-compatible audio service (PipeWire-Pulse works)

`bwrap` is optional and must be on `PATH` only for Full isolation.
Automatic isolation uses it when its capability test succeeds and otherwise
uses Compatible isolation. Radio Tellus does not install packages or change
system configuration.

## Usage

Add `mirenel/radio-tellus:bar` under **Settings → Bar**, then click the widget
to open the panel. The bar also supports right-click to stop playback, the
mouse wheel for volume, and middle-click for widget settings. Its glyph can
show connecting, playing, paused, or silent playback states; disable **Show
playback status** to keep the configured glyph fixed.

The panel can browse Discover, Moods, Genres, Places, Favorites, and Recent.
Type a station, country, or tag in Search and press Enter to fetch current
matches. **Random** requests and plays one fresh station without replacing the
current list. HTTP stations are shown but require the explicit insecure-HTTP
setting before playback.

Open the panel from a terminal with:

```sh
noctalia msg panel-toggle mirenel/radio-tellus:panel
```

The headless `player-status` service starts automatically while Radio Tellus is
enabled; no separate setup is required.

The launcher provider uses `/radio` for these actions:

- **Open Radio Tellus** toggles the panel.
- **Play a random station** selects from the cached Discover list.
- Favorites can be searched by station name, country, or tag and played directly; for example, `/radio jazz`.

With the panel focused, Up/Down selects a station, Enter plays it, Space
toggles playback, `R` plays a random station, `F` toggles its favorite state,
and `M` toggles mute. These shortcuts can be changed or disabled in settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `startup_view` | `select` | `discover` | View selected when the panel opens. |
| `station_limit` | `int` | `40` | Maximum stations shown in catalog and search views. |
| `history_limit` | `int` | `30` | Number of Recent stations retained; 0 disables history. |
| `row_click_action` | `select` | `play` | Play a station immediately or only select it. |
| `stop_on_panel_close` | `bool` | `false` | Stop playback when the panel closes, except while opening settings. |
| `cache_hours` | `int` | `6` | Hours catalog results may be reused. |
| `allow_insecure_http` | `bool` | `false` | Allow unencrypted HTTP streams; HTTPS remains the default. |
| `isolation_mode` | `select` | `auto` | Choose Automatic, Full, or Compatible playback isolation. |
| `report_clicks` | `bool` | `true` | Report successful playback to Radio Browser after audio starts. |
| `shortcut_previous` | `select` | `Up` | Panel shortcut for the previous station. |
| `shortcut_next` | `select` | `Down` | Panel shortcut for the next station. |
| `shortcut_play` | `select` | `Return` | Panel shortcut for playing the selected station. |
| `shortcut_toggle` | `select` | `space` | Panel shortcut for toggling playback. |
| `shortcut_random` | `select` | `r` | Panel shortcut for playing a random station. |
| `shortcut_favorite` | `select` | `f` | Panel shortcut for toggling a favorite. |
| `shortcut_mute` | `select` | `m` | Panel shortcut for toggling mute. |
| `glyph` | `glyph` | `radio` | Bar glyph used when stopped or status display is off. |
| `show_playback_status` | `bool` | `true` | Show connecting, playing, paused, and silent states in the bar. |
| `show_station_name` | `bool` | `true` | Show the current station name in the bar. |
| `station_name_limit` | `int` | `24` | Maximum Unicode characters shown for the bar station name. |
| `volume_step` | `int` | `5` | Volume percentage points changed per bar wheel step. |

## IPC

After opening the panel once in the current Noctalia session, these commands
are available:

```sh
noctalia msg plugin mirenel/radio-tellus:panel all random
noctalia msg plugin mirenel/radio-tellus:panel all discover
```

## Notes

### Privacy and playback safety

Catalog requests use `https://all.api.radio-browser.info` and the
`Radio-Tellus` user agent. Favorites, Recent, volume, and catalog
caches stay in Noctalia's per-plugin data directory. Radio Browser click
reporting (`report_clicks`) can be disabled.

HTTPS is required by default. Every stream goes through Radio Tellus's
destination-validating proxy; private and local destinations are rejected.
Automatic mode uses Bubblewrap when its capability probe succeeds, while
Compatible mode uses an authenticated loopback proxy. MPV's unsafe playlist,
script, extractor, and file-autoload features are disabled. These controls
reduce exposure but are not a formal sandbox, and MPV still parses untrusted
media.

## License

Radio Tellus is released under the MIT license. Playback isolation code
adapted from Radio Atlas is attributed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
