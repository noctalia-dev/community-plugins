# Game Launcher

Browse and launch games from Steam, Lutris, and Heroic Games Launcher directly from your bar. Opens a floating panel with search, cover art, and one-click launch.

## Plugin

| Field | Value |
| --- | --- |
| ID | `Alexander/game-launcher` |
| Entries | Bar widget: `launcher`; panel: `browser`; launcher provider: `search` |
| Launcher Prefix | `/g` |

## Requirements

Requires `libsqlite3-dev` and `curl` on PATH.

```sh
# Debian/Ubuntu
sudo apt install libsqlite3-dev curl

# Fedora
sudo dnf install sqlite-devel curl

# Arch
sudo pacman -S sqlite curl
```

The scanner binary (`gamelauncher`) is compiled automatically on first use — the plugin runs `cc` to build it when needed. No manual build step required.

## Usage

Add the bar widget `Alexander/game-launcher:launcher` to your bar. The widget shows a gamepad icon — click it to open the browser panel.

In the panel, use the search bar to filter by name or runner. Click **Launch** on any game to start it.

To open the panel via IPC:

```sh
noctalia msg panel-toggle Alexander/game-launcher:browser
```

From the launcher, type `/g` followed by a game name to search. Activate a result to launch the game.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `device-gamepad-2` | Bar widget icon |

## Notes

- Scans all detected Steam library folders, Lutris SQLite databases, and Heroic store caches (Legendary, GOG, Nile).
- Results are cached in `~/.cache/gamelauncher/games.json` and rescanned on click if sources changed.
- Cover art is fetched from Steam CDN on first scan when no local art is found.
- Requires `xdg-open` for launching games.
