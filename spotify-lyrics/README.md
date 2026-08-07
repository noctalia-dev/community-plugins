# Spotify Lyrics

A seamless, time-synced scrolling lyrics panel for the Noctalia desktop shell. It integrates directly into your Noctalia bar and displays a beautifully formatted, auto-scrolling lyrics card — no API keys, cookies, or web scraping required.

## Plugin

| Field | Value |
| --- | --- |
| ID | `goatnath/spotify-lyrics` |
| Entries | Bar widget: `lyrics`; panel: `lyrics-panel`; desktop widget: `lyrics-desktop` |

## Requirements

This plugin requires `playerctl`, `python3`, and the `syncedlyrics` Python package.

```bash
# Arch Linux
sudo pacman -S playerctl python
pip install syncedlyrics
```

## Usage

### 1. Set up the Background Daemon

The daemon listens to your media player (Spotify, MPD, etc.) and fetches the lyrics.

1. Copy the `spotify_lyrics_daemon.py` file to your preferred location (e.g., `~/.local/bin/`).
2. Set it up to run in the background. The recommended way is using a systemd user service:

```ini
# ~/.config/systemd/user/noctalia-lyrics.service
[Unit]
Description=Noctalia Lyrics Daemon
After=graphical-session.target

[Service]
ExecStart=/usr/bin/python3 /path/to/spotify_lyrics_daemon.py
Restart=always

[Install]
WantedBy=default.target
```

Start and enable the daemon:

```bash
systemctl --user daemon-reload
systemctl --user enable --now noctalia-lyrics.service
```

### 2. Enable the Plugin

1. Install this plugin from the plugin manager or download the folder to `~/.local/share/noctalia/plugins/spotify-lyrics/`.
2. Enable the plugin via CLI:

```bash
noctalia msg plugins enable goatnath/spotify-lyrics
```

3. Add the `lyrics` widget to your bar's layout in your `~/.local/state/noctalia/settings.toml` (next to the `media` widget).

```toml
start = [ "launcher", "workspaces", "media", "lyrics" ]
```

### 3. Toggle the Lyrics Panel

Click the `♫` bar icon to toggle the panel, or run:

```sh
noctalia msg panel-toggle goatnath/spotify-lyrics:lyrics-panel
```

## Notes

- **Zero Configuration:** Lyrics are pulled from public databases (LRCLIB, NetEase) automatically.
- **Caching:** The daemon caches lyrics and album art to `~/.cache/noctalia/lyrics/` so subsequent plays load instantly.
- **Network:** The daemon makes HTTPS requests to LRCLIB and NetEase for lyrics, and to the album art URL provided by MPRIS metadata.
- **Processes:** Requires a separate `spotify_lyrics_daemon.py` process running as a systemd user service.
