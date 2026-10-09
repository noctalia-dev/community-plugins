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
| Entries | Bar widgets: `now-playing`, `playback-toggle`; panel: `island`; service: `media-state` |

## Requirements

Install `busctl` on `PATH`. It is provided by systemd on most Linux
distributions. A media application exposing an MPRIS player is also required.

## Usage

Enable **Media Island** in `Settings → Plugins`, then add the
`notoxus/media-island:now-playing` widget to a bar.

- Left click opens or closes the island, or opens Noctalia's Media panel when
  `open_media_panel_on_click` is enabled.
- Right click toggles Play/Pause.
- Scroll, Back, and Forward gestures change tracks.
- The panel's transport buttons provide Previous, Play/Pause, and Next.
- Clicking the artwork or title in the panel opens Noctalia's Media panel.
- The close button dismisses a manually opened island.
- Add `notoxus/media-island:playback-toggle` for a standalone Play/Pause button.

The panel can also be toggled from a terminal:

```sh
noctalia msg panel-toggle notoxus/media-island:island
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_show` | `bool` | `true` | Briefly show the island when playback starts or the track changes. |
| `preview_seconds` | `int` | `2` | Automatic preview duration, from 1 to 10 seconds. |
| `open_media_panel_on_click` | `bool` | `false` | Left-clicking the bar widget opens Noctalia's Media panel instead of toggling the island. |

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
