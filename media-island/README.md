# Media Island

A self-contained, top-center now-playing island for Noctalia. It shows album
art, track metadata, playback progress, and transport controls without editing
the user's Noctalia or compositor configuration.

The island briefly appears when playback starts or the current track changes.
Open it manually from the bar widget to keep it visible until closed.

## Plugin

| Field | Value |
| --- | --- |
| ID | `notoxus/media-island` |
| Entries | Bar widget: `now-playing`; panel: `island`; service: `media-state` |

## Requirements

Install `busctl` on `PATH`. It is provided by systemd on most Linux
distributions. A media application exposing an MPRIS player is also required.

## Usage

Enable **Media Island** in `Settings → Plugins`, then add the
`notoxus/media-island:now-playing` widget to a bar.

- Left click opens or closes the island.
- Right click toggles Play/Pause.
- Scroll, Back, and Forward gestures change tracks.
- The panel's transport buttons provide Previous, Play/Pause, and Next.
- The close button dismisses a manually opened island.

The panel can also be toggled from a terminal:

```sh
noctalia msg panel-toggle notoxus/media-island:island
```

The panel defaults to a persistent floating surface at the top center. Its
position and layer can be changed from the plugin's settings; choose the
`overlay` layer if the island should appear above fullscreen windows.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_show` | `bool` | `true` | Briefly show the island when playback starts or the track changes. |
| `preview_seconds` | `int` | `2` | Automatic preview duration, from 1 to 10 seconds. |

## IPC

The service accepts panel and playback actions:

```sh
noctalia msg plugin notoxus/media-island:media-state all show
noctalia msg plugin notoxus/media-island:media-state all hide
noctalia msg plugin notoxus/media-island:media-state all toggle-panel
noctalia msg plugin notoxus/media-island:media-state all previous
noctalia msg plugin notoxus/media-island:media-state all toggle
noctalia msg plugin notoxus/media-island:media-state all next
```

## Notes

The service polls Noctalia's MPRIS D-Bus facade with `busctl` every 500 ms so
it follows the same active player as the built-in media widget. It invokes the
Noctalia CLI to open and close the persistent panel idempotently.

Remote album artwork is downloaded through Noctalia's runtime API into the
plugin's persistent data directory. The plugin does not modify user
configuration files and does not require compositor autostart commands.
