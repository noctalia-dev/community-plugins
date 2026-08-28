# Spotify Media

A compact Spotify now-playing widget for the Noctalia bar, with album artwork, continuously scrolling track information, playback controls, and direct Spotify launch/focus behavior.

## Plugin

| Field   | Value                   |
| ------- | ----------------------- |
| ID      | `azokyen/spotify-media` |
| Entries | Bar widget: `bar`       |

## Requirements

The following dependencies must be installed and available on `PATH`:

* `playerctl` — reads Spotify MPRIS metadata and controls playback.
* `hyprctl` — detects and focuses an existing Spotify window under Hyprland.
* `spotify-launcher` — launches Spotify when it is not already running.

The current implementation is designed for Hyprland and expects Spotify to expose the MPRIS player name `spotify`, the plugin supports Spotify window classes `spotify` (native Wayland) and `Spotify` (XWayland).

## Usage

Enable `azokyen/spotify-media` in Noctalia and add its `bar` widget to a Noctalia bar.

When Spotify is running, the widget displays:

* Album artwork
* Continuously scrolling `Artist – Title`
* Previous track
* Play / pause
* Next track

Hovering over the track text shows the full track information in a tooltip.

Click the album artwork or track text to open Spotify:

* If Spotify is already running, the existing Spotify window is focused.
* If Spotify is not running, `spotify-launcher` is started.

When Spotify is closed, the widget collapses to a Spotify icon.

## Notes

The widget uses `playerctl --player=spotify` to read metadata and send playback commands.

Spotify window detection is performed with:

```text
hyprctl clients -j
```

An existing Spotify window is focused with:

```text
hyprctl dispatch 'hl.dsp.focus({ window = "class:^Spotify$" })'
```

If no Spotify window is found, the plugin spawns:

```text
spotify-launcher
```

Album artwork URLs are obtained from Spotify's MPRIS metadata. Remote artwork is downloaded into the plugin data directory and cached using two alternating cover image files.

The widget polls metadata approximately once per second. The marquee animation updates separately at a 250 ms interval.

The current version is Spotify-specific and Hyprland-specific.
