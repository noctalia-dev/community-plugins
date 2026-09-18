# Media Island for Noctalia

A playback-aware control widget used by this dotfiles repository's temporary
media island.

The island uses Noctalia's normal bar auto-hide behavior at the top screen
edge. The external `noctalia-media-island` watcher additionally reveals it
when playback starts or the current track changes. It temporarily suspends
auto-hide, keeps the island visible for 1.5 seconds, then hides it and restores
normal edge-triggered auto-hide. The plugin follows the same active MPRIS
player selected by Noctalia. The compact artwork/title stays native so its
marquee remains pixel-smooth; Play/Pause updates only the shared player state
and never rebuilds the bar. The plugin also supplies a playback-aware control
for the expanded island.

##Requirements

- `busctl`

## Plugin

| Field | Value |
|---|---|
| Plugin ID | `notoxus/media-island` |
| Compact pill | Native `media` widget managed by the plugin service |
| Island control | `notoxus/media-island:playback-toggle` |

## Settings

Three behavior overrides are exposed:

- **Always scroll long titles** keeps a long title moving continuously. It is
  off by default, so the title scrolls only while the pill is hovered. Changing
  this setting reloads the config once; Play/Pause never does.
- **Open full media panel on click** opens Noctalia's native Media panel when
  the compact pill is clicked. It is off by default, so a click briefly reveals
  the expanded media island instead; clicking the native media content inside
  that island then opens Noctalia's Media panel.
- **Use default panel position** makes that second click open the Media panel
  at Noctalia's default location instead of attaching it below the island. It
  is off by default.

## Installation

Copy this directory to:

```text
~/.local/share/noctalia/plugins/media-island/
```

Then enable **Media Island** under `Settings → Plugins`. The tracked bar
profiles already place the managed native media pill and playback widget.
