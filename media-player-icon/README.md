# Media Player Icon

Displays the current media player status as a single icon in the Noctalia bar.
It's useful if you only want to know when media is playing without displaying the artist, track title, or other metadata.

The plugin uses `playerctl` to monitor media player status and updates the indicator when playback changes.
The glyph and color can be customized individually for playing, paused, and stopped states.
You can also choose to hide the indicator when playback is stopped.

## Plugin

| Field   | Value                                               |
| ------- | --------------------------------------------------- |
| ID      | `ismay/media-player-icon`                           |
| Entries | Bar widget: `media-player-icon`; service: `service` |

## Usage

Add the `media-player-icon` widget to your Noctalia bar.
The plugin automatically detects available media players and monitors their playback status using `playerctl`.
No manual player configuration is required.

You can customize the glyph and color for each playback state in the widget settings.
Enable **Hide Stopped** to hide the indicator when a media player reports that playback is stopped.

Left-click the widget to toggle media playback between play and pause.
Right-click the widget to open the Noctalia Control Center with its Media tab selected.
These actions can be customized through the widget's action settings.

## Requirements

Requires `playerctl` to be installed and available on `PATH`.
`playerctl` communicates with media players that support the [MPRIS D-Bus interface](https://www.freedesktop.org/wiki/Specifications/mpris-spec/).

The plugin uses:

- `playerctl status` to query the initial media player status.
- `playerctl status --follow` to monitor playback status changes continuously.

## Settings

| Setting         | Type     | Default                | Description                                        |
| --------------- | -------- | ---------------------- | -------------------------------------------------- |
| `playing_glyph` | `glyph`  | `"player-play-filled"` | Glyph displayed when a media player is playing.    |
| `playing_color` | `color`  | `"primary"`            | Color used for the playing status glyph.           |
| `paused_glyph`  | `glyph`  | `"player-pause-filled"`| Glyph displayed when a media player is paused.     |
| `paused_color`  | `color`  | `"on_surface"`         | Color used for the paused status glyph.            |
| `hide_stopped`  | `bool`   | `false`                | Hide the indicator when a media player is stopped. |
| `stopped_glyph` | `glyph`  | `"player-stop-filled"` | Glyph displayed when a media player is stopped.    |
| `stopped_color` | `color`  | `"on_surface"`         | Color used for the stopped status glyph.           |

The `stopped_glyph` and `stopped_color` settings are only available when `hide_stopped` is disabled.

## Notes

- The widget is hidden when no media player is available or when the service encounters an error.
- Errors are logged to the Noctalia log.
