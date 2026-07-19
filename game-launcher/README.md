# Game Launcher

Browse and launch games from Steam, Lutris, and Heroic Games Launcher directly from your bar. Opens a floating panel with search, cover art, and one-click launch.

## Plugin

| Field | Value |
| --- | --- |
| ID | `leo/game-launcher` |
| Entries | Bar widget: `launcher`; panel: `browser`; launcher provider: `search` |
| Launcher Prefix | `/g` |

## Requirements

Install the build dependencies, then compile the scanner:

```sh
# Debian/Ubuntu
sudo apt install build-essential libsqlite3-dev curl

# Fedora
sudo dnf install gcc sqlite-devel curl

# Arch
sudo pacman -S base-devel sqlite curl
```

Build the scanner inside the plugin directory:

```sh
cc -o gamelauncher gamelauncher.c -lsqlite3 -lpthread
```

## Usage

Add the bar widget `leo/game-launcher:launcher` to your bar. The widget shows a gamepad icon — click it to open the browser panel.

In the panel, use the search bar to filter by name or runner. Click **Launch** on any game to start it.

To open the panel via IPC:

```sh
noctalia msg panel-toggle leo/game-launcher:browser
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
