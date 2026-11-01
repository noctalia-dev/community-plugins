# WayVibes

Mechanical keyboard typing sounds for Noctalia on Wayland, powered by wayvibes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `viksit-garg/wayvibes` |
| Entries | Bar widget: `wayvibes`; panel: `panel`; service: `daemon` |

## Requirements

WayVibes integrates with the standalone `wayvibes` CLI daemon:

- Noctalia **5.4.0 or newer** (plugin API **43**) running in a supported Wayland session. The legacy Quickshell-based Noctalia v4 cannot load this plugin.
- `wayvibes`: install [`wayvibes`](https://github.com/sahaj-b/wayvibes) on `PATH` (on Arch Linux: `yay -S wayvibes-git`, or install from source).
- `pkill`: standard Linux utility for process lifecycle management.
- `pgrep`: checks whether the background daemon started successfully. Both `pgrep` and `pkill` are normally provided by `procps`/`procps-ng`.
- `sleep`: waits briefly before checking daemon startup; normally provided by coreutils.
- User membership in the `input` group to read keyboard events:

```sh
sudo usermod -aG input $USER
```

Log out and back in after adding your user to the `input` group.

For a clean CachyOS installation, follow the complete [CachyOS setup and verification guide](CACHYOS.md), including installation of the plugin and a soundpack. It does not assume an AUR helper or existing WayVibes configuration.

## Usage

Enable `viksit-garg/wayvibes` in Noctalia Settings, then add the `wayvibes` widget to your bar. Enabling the plugin starts its headless `daemon` service, which discovers soundpacks and keyboards; typing audio starts only when you choose a pack or enable `auto_start`. Click the widget or run the following command to toggle the panel:

```sh
noctalia msg panel-toggle viksit-garg/wayvibes:panel
```

Open **Input Device** to confirm the selected keyboard, then choose a soundpack in **Soundpacks**. When no device is configured, the service automatically selects the first detected keyboard. If you use a remapper such as `keyd`, select its virtual keyboard instead when appropriate.

### Features

1. **Soundpacks Library:** Automatically detects Mechvibes and Wayvibes soundpacks located in `~/.local/share/soundpacks/`, `~/wayvibes/soundpacks/`, or your custom configured directory.
2. **Instant Playback & Search:** Click any soundpack to switch audio playback immediately, or filter packs using the search bar.
3. **Random Playback:** Hit the shuffle button to select a random soundpack from your collection.
4. **Volume Control:** Adjust playback volume from level 1 to 10.
5. **Input Device Management:** View detected keyboard input devices in the "Input Device" tab and select your active keyboard with one click.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `executable_path` | `string` | `wayvibes` | Command name or absolute path to the wayvibes binary. |
| `soundpacks_dir` | `folder` | `""` | Optional custom directory containing soundpacks. |
| `default_volume` | `int` | `3` | Default playback volume level (1-10). |
| `auto_start` | `bool` | `false` | Restore the last saved soundpack and volume when the service starts, including on login. |
| `glyph` | `glyph` | `keyboard` | Bar widget icon glyph. |

## Notes

- **Attribution:** This plugin provides a native Noctalia desktop integration for [wayvibes](https://github.com/sahaj-b/wayvibes) by Sahaj B, supporting soundpacks adhering to the open Mechvibes soundpack specification.
- **Privacy:** Keystroke event detection occurs strictly in memory through `wayvibes` and `libevdev`. No typed text, keystrokes, or key sequences are ever written to disk or transmitted over the network.
- **Soundpacks:** Soundpacks are managed independently by the user in `~/.local/share/soundpacks/` or `~/wayvibes/soundpacks/`, ensuring no proprietary or unverified audio assets are bundled into the plugin repository.
- **Device discovery:** Reads `/proc/bus/input/devices` and matches the upstream daemon's `KEY_A` keyboard capability check. If that yields no keyboards, lists `*-event-kbd` entries in `/dev/input/by-id`. Discovery does not read keystroke events or invoke unsupported CLI options.
- **Device configuration:** Reads and writes `$XDG_CONFIG_HOME/wayvibes/input_device`, falling back to `~/.config/wayvibes/input_device` when the environment variable is unset or empty. Unique kernel names use `NAME:<name>`; duplicate names and fallback device links use `PATH:<path>`. Legacy `input_device_name` or `input_device_path` files in that directory are migrated, and the migrated file is removed only after a successful replacement write. This configuration is shared with the standalone daemon.
- **Saved playback:** Writes the selected pack's name, path, and volume to `state.json` in `noctalia.pluginDataDir()`. It does not copy soundpacks into the plugin directory.
- **Processes:** Starts the configured `wayvibes` executable with a soundpack path, `-v`, and `-bg`. Switching packs, changing volume during playback, and changing the active keyboard restart playback. Stop and restart use `pkill -x wayvibes`, which can also stop a separately started WayVibes daemon owned by the same user. Startup verification runs `sleep` and `pgrep -x wayvibes`. Shell arguments containing user-selected paths are quoted.
- **Network:** The plugin makes no network requests and does not download or execute remote code. The external daemon manages audio decoding; upstream may offer to convert unsupported audio using `ffmpeg`, which is separate from plugin discovery and device configuration.

## Development checks

Run the Noctalia settings linter and the service regression tests:

```sh
noctalia plugins lint /path/to/wayvibes
python3 tests/run.py --luau /path/to/luau
```

Python 3 and the Luau CLI are development tools, not runtime dependencies. The regression tests run the real service in Luau with an in-memory Noctalia host fixture; they do not access keyboard events, alter your configuration, or start or stop real daemons. See [COMMUNITY_REVIEW.md](COMMUNITY_REVIEW.md) for submission checks and remaining manual evidence.
