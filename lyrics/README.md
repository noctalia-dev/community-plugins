# Noctalia Lyrics 1.7.1

Synchronized lyrics for the Noctalia bar: word-level karaoke highlighting, animated line transitions, translations and romanization, multiple lyric sources, and a hover picker for choosing between alternative matches.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h465855hgg/lyrics` |
| Entries | Bar widget: `lyrics`; panel: `selector`; shortcut: `open_selector`; service: `service` |

The line-slide animation requires Noctalia with plugin API 52. Older shells are held back to the 1.6.x release from the plugin source and use fade transitions.

## Requirements

The plugin needs these commands on `PATH`:

| Command | Purpose |
| --- | --- |
| `playerctl` | Read and control MPRIS players (metadata, play/pause, next/previous). |
| `python3` | Run the lyric-source adapter and parser (standard library only). |
| `cp` | Cache local MPRIS artwork. |
| `chmod` | Secure the temporary request directory before credentials are written. |
| `timeout` | Bound each `playerctl` metadata poll. |

`cp`, `chmod`, and `timeout` are part of `coreutils` and are usually already installed.

```sh
# Arch-based
sudo pacman -S python playerctl coreutils

# Debian / Ubuntu
sudo apt install python3 playerctl coreutils

# Fedora
sudo dnf install python3 playerctl coreutils

# NixOS (configuration.nix)
environment.systemPackages = with pkgs; [ playerctl python3 coreutils ];
```

Restart Noctalia after changing packages so its process sees the same `PATH` as your shell. Verify from a terminal:

```sh
command -v playerctl python3 cp chmod timeout
python3 -c 'import ssl; print(ssl.OPENSSL_VERSION)'
```

The second command must print an OpenSSL version; Python builds without `_ssl` cannot fetch HTTPS lyrics. On NixOS use `pkgs.python3`, not `pkgs.python3Minimal`. If lyrics stay empty, check Noctalia's log for the Python command and confirm it resolves the same `PATH` as your shell.

## Usage

Enable `h465855hgg/lyrics`, start its `service` entry, and add the `lyrics` bar widget. The widget adds these default pointer bindings under Actions:

| Gesture | Default command | Behavior |
| --- | --- | --- |
| Left click | `plugin h465855hgg/lyrics:lyrics all toggle-view` | Switch between lyrics and track information. |
| Right click | `plugin h465855hgg/lyrics:service all toggle-playback` | Pause or resume the selected player. |
| Scroll up | `plugin h465855hgg/lyrics:service all next` | Next track. |
| Scroll down | `plugin h465855hgg/lyrics:service all previous` | Previous track. |

The left-click binding is broadcast to every lyrics widget; only the instance under the pointer changes its view.

### Choosing a lyric version

When a source returns several matches, the `selector` panel lists them with source, duration, a `Δ` offset when the duration differs from the playing track, and the known format (`LRC` / `PLAIN`). The footer shows the applied format, for example `Applied: YRC · word`. The automatically chosen result prefers the closest duration.

Open the picker by hovering the widget for about half a second (the `selector_enabled` widget setting), from the `open_selector` shortcut in Settings → Keybinds, or directly:

```sh
noctalia msg panel-toggle h465855hgg/lyrics:selector
```

`candidate_mode` selects **Choose** (show the picker) or **Best match** (always use the best-ranked result and disable the picker). A failed manual pick falls back to the best match, and the picker's **Best match** button discards the manual pick.

## Settings

Plugin-level settings are on the Lyrics page under Settings → Plugins:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `lyrics_source` | select | `auto` | Fixed source, `auto` fallback mode, `mpris`, `external`, or `custom`. |
| `lyrics_sources` | list | built-in order | Source order used by `auto`. |
| `auto_source_routing` | bool | `true` | Try the source matching the player or media URL first. |
| `candidate_mode` | select | `choose` | Show the picker or always use the best match. |
| `translation_language` | select | `zh-Hans` | Preferred translation language. |
| `lyrics_offset_ms` | int | `0` | Shift lyric timing (−10000…10000 ms). |
| `poll_interval_ms` | int | `500` | MPRIS polling interval (100…5000 ms). |
| `format_priority` | list | yrc…plain | Lyric format order. |
| `source_format_priority` | list | empty | Per-source overrides such as `netease=yrc,krc,lrc`. |

Credential and endpoint fields for Spotify, Apple Music, Musixmatch, Qishui, SPlayer, SPlayer Next, and custom sources appear when their source is selected. Credentials are stored in plaintext in Noctalia's settings; the plugin never logs them and deletes the temporary request file after the adapter reads it.

Per-widget settings use a **Settings category** selector: Display & behavior, Lyrics, Cover & colors, Karaoke & animation, Font & layout, Scrolling & width, and Intro/interlude cues. Only the selected category is shown; other values are kept. The `selector_enabled` hover toggle lives under Display & behavior.

## IPC

Service events:

```sh
noctalia msg plugin h465855hgg/lyrics:service all toggle-playback
noctalia msg plugin h465855hgg/lyrics:service all next
noctalia msg plugin h465855hgg/lyrics:service all previous
noctalia msg plugin h465855hgg/lyrics:service all clear
noctalia msg plugin h465855hgg/lyrics:service all push-lrc '<lrc text>'
noctalia msg plugin h465855hgg/lyrics:service all push-json '<json>'
noctalia msg plugin h465855hgg/lyrics:service all push-state '<json>'
```

Widget event: `noctalia msg plugin h465855hgg/lyrics:lyrics all toggle-view`.

`push-json` accepts `lines` or `lyrics`; `push-state` also updates track, position, playing, and cover. MPRIS durations and positions are microseconds; lyric timestamps are milliseconds.

## Notes

Supported sources: LRCLIB, NetEase, QQ Music, Kugou, SPlayer, SPlayer Next, Qishui, Apple Music, Spotify, Musixmatch, a custom HTTP endpoint, MPRIS metadata, and an external push protocol. Network requests go to the selected sources; cached files live in Noctalia's plugin state directory.

Lyrics are translated in English and Simplified Chinese; other catalogs fall back to English for new keys.

## Screenshots

![Lyrics on the bar with album art](<screenshots/lyrics - 1.7.1.png>)

![Selector with source, format, and duration offsets](<screenshots/selector - 1.7.1.png>)

![Widget settings categories](<screenshots/widget settings - 1.7.1.png>)

## Local development

```sh
noctalia msg plugins source add lyrics-dev path /path/to/plugin-parent
noctalia msg plugins enable h465855hgg/lyrics
noctalia msg config-reload
```

Run the Python tests from this directory:

```sh
python3 test_lyric_sources.py
python3 test_music_sources.py
```

For repository validation, follow the [shared validator setup](../README.md#manifest-validation) in the
community-plugins README and run its command from the repository root with `--profile community`.
