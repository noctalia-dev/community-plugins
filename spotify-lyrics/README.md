# Noctalia Synced Lyrics Plugin

A seamless, time-synced scrolling lyrics panel for the Noctalia desktop shell. It integrates directly into your Noctalia bar and displays a beautifully formatted, auto-scrolling lyrics card when you click the `♫` icon.

## Why it's great
* **Zero Configuration:** No Spotify `sp_dc` cookies, API keys, or web scraping required! It pulls lyrics from public databases like LRCLIB and NetEase automatically.
* **Blazing Fast:** Uses a lightweight Python background daemon that caches lyrics to your disk so subsequent plays load in 0ms.
* **Native Shell Integration:** Doesn't feel like a clunky third-party app. It uses Noctalia's native declarative UI framework for buttery smooth, theme-aware rendering.

## Plugin
- **Id:** `noctalia/spotify-lyrics`
- **Widgets:**
  - `lyrics`: The bar icon that toggles the lyrics panel.
- **Panels:**
  - `lyrics-panel`: The scrolling lyrics panel.
  - To toggle it manually via IPC, run: `noctalia msg panel-toggle noctalia/spotify-lyrics:lyrics-panel`

## Usage

### 1. Install Dependencies
You need `playerctl` and the `syncedlyrics` python package.
```bash
# Arch Linux
sudo pacman -S playerctl
pip install syncedlyrics
```

### 2. Set up the Background Daemon
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

### 3. Enable the Noctalia Plugin
1. Install this plugin from the plugin manager or download the folder to `~/.local/share/noctalia/plugins/spotify-lyrics/`.
2. Enable the plugin via CLI:
```bash
noctalia msg plugins enable noctalia/spotify-lyrics
```
3. Add the `lyrics` widget to your bar's layout in your `~/.local/state/noctalia/settings.toml` (next to the `media` widget).

```toml
start = [ "launcher", "workspaces", "media", "lyrics" ]
```

That's it! Play a song on Spotify and a `♫` icon will appear in your bar. Click it to view the synced lyrics.
