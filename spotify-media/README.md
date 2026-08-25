# README.md

# Spotify Media for Noctalia

A compact Spotify media widget for the [Noctalia Shell](https://noctalia.dev/) bar.

Designed as a smaller alternative to a full media panel, with album artwork, scrolling track information, playback controls, and direct Spotify launching/focusing.

![Spotify Media preview](assets/preview.gif)

## Features

* Compact layout designed for small Noctalia bars
* Spotify album artwork
* Continuously scrolling `Artist – Title`
* Previous track
* Play / pause
* Next track
* Full track information tooltip
* Click artwork or track text to focus Spotify
* Launches Spotify when it is not already running
* Collapses to a Spotify icon when Spotify is closed
* Uses MPRIS through `playerctl`
* Low-frequency metadata polling

## Requirements

* Noctalia Shell
* Hyprland
* Spotify
* `playerctl`
* `spotify-launcher`

Currently developed and tested with:

* Noctalia `5.0.0_beta.9`
* Plugin API `24`
* Hyprland `0.56.2`
* `spotify-launcher`
* Wayland

## Installation

Clone the repository into your local Noctalia plugins directory:

```bash
git clone https://github.com/YOUR-USERNAME/noctalia-spotify-media.git \
  ~/.local/share/noctalia/plugins/spotify-media
```

Then enable **Spotify Media** from Noctalia's plugin settings and add the widget to your bar.

If necessary, restart Noctalia:

```bash
pkill -x noctalia
noctalia >/tmp/noctalia.log 2>&1 &
disown
```

## Dependencies

### playerctl

The widget uses `playerctl` to read Spotify's MPRIS metadata and control playback.

On Arch Linux:

```bash
sudo pacman -S playerctl
```

### Spotify

The current version expects Spotify to be installed through `spotify-launcher`:

```bash
spotify-launcher
```

If you use another Spotify package, the launch command in `bar.luau` will need to be changed.

## Hyprland integration

When Spotify is already running, the widget focuses its existing window instead of launching another instance.

The current implementation uses the Hyprland Lua dispatcher syntax:

```bash
hyprctl dispatch 'hl.dsp.focus({ window = "class:^Spotify$" })'
```

The Spotify window is expected to use:

```text
class=Spotify
```

Because of this, the current version is Hyprland-specific.

## Configuration

The widget is intentionally minimal at the moment.

Basic appearance and marquee behavior can be adjusted near the top of `bar.luau`:

```lua
local SCROLL_WIDTH = 16
local SCROLL_SPEED_TICKS = 2
local METADATA_TICKS = 4
```

The current update interval is:

```lua
noctalia.setUpdateInterval(250)
```

Metadata is refreshed approximately once per second while the marquee animation updates independently.

## Known limitations

* Spotify-specific rather than a generic MPRIS player widget
* Spotify launch command currently assumes `spotify-launcher`
* Window focusing currently depends on Hyprland
* Some visual properties are controlled by Noctalia's declarative button/theme system

## License

MIT License. See [LICENSE](LICENSE).
