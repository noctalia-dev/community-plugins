# Media Island

A self-contained, top-center now-playing island for Noctalia. You can also change its position to suit yourself. It shows album art, track metadata, playback progress, and transport controls without editing
the user's Noctalia or compositor configuration.

The island briefly appears when playback starts or the current track changes.
The bar gets a thin, full-width audio wave along its lower edge; click the
track title pill to show the island for the configured preview duration. The
pill is hidden when playback has no artwork or title; the visualizer can still
run on its own.

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

- Click the track title to show the island briefly.
- Right click toggles Play/Pause.
- Scroll, Back, and Forward gestures change tracks.
- The panel's transport buttons provide Previous, Play/Pause, and Next.

The panel can also be toggled from a terminal:

```sh
noctalia msg panel-toggle notoxus/media-island:island
```

The panel attaches below the bar widget. Automatic previews and title-click
previews close after the configured duration; opening the panel directly from
the command line leaves it open until toggled closed.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `auto_show` | `bool` | `false` | Briefly show the island when playback starts or the track changes. Off by default, so it appears on click. |
| `preview_seconds` | `int` | `2` | Preview duration for automatic and title-click previews, from 1 to 10 seconds. |
| `click_action` | `string` | `island` | Clicking the track title opens the island preview (2 seconds by default). |
| `audio_visualizer` | `bool` | `true` | Show the full-width audio-reactive wave along the bar (requires Noctalia 5.4 / plugin API 36). |

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
