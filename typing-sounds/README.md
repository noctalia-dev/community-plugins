# Typing Sounds

Play mechanical keyboard sounds as you type on your keyboard.

## Plugin

| Field | Value |
| --- | --- |
| ID | `hthienloc/typing-sounds` |
| Entries | Service: `daemon` |

## Requirements

- `evtest` installed on `PATH`.
- User added to the `input` group (`sudo usermod -aG input $USER`).
- PipeWire installed with `pw-play` on `PATH`.

## Usage

Enable the plugin in Noctalia Settings (`Plugins -> Typing Sounds`).

All configuration, including toggling sounds on/off, volume level, and choosing switch sound profiles, is managed directly in the plugin settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `bool` | `true` | Toggle typing sounds on or off. |
| `volume` | `int` | `100` | Sound volume percentage from 0% to 200% (min=0, max=200, step=5). |
| `sound_pack` | `select` | `nk-cream` | Select mechanical switch sound profile (18 profiles available). |
| `mouse_enabled` | `bool` | `false` | Play click sound on mouse button press. |
| `input_devices` | `string_list` | `["/dev/input/by-id/*kbd*", "/dev/input/by-id/*Keyboard*", "/dev/input/by-path/*kbd*"]` | List of input paths or globs to monitor. |
| `executable_path` | `file` | `evtest` | Path to the `evtest` binary. |

## IPC

Toggle or control typing sounds from external scripts and shortcuts:

```sh
noctalia msg plugin hthienloc/typing-sounds:daemon all toggle
noctalia msg plugin hthienloc/typing-sounds:daemon all enable
noctalia msg plugin hthienloc/typing-sounds:daemon all disable
```

## Notes

- Uses `pw-play` (PipeWire) to stream sounds with minimal latency.
- Binds to keyboard devices directly via `evtest` stream with automatic symlink deduplication and event debouncing.
