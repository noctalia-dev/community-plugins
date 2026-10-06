# Spotify-launcher for niri

Noctalia v5 bar widget that toggles the official Spotify client on [niri](https://github.com/YaLTeR/niri).

| Gesture      | Action                                                                 |
|--------------|------------------------------------------------------------------------|
| Left click   | Launch Spotify if not running; otherwise show it on the focused workspace, or hide it if it is already focused |
| Right click  | Close Spotify                                                          |

niri has no minimize, so hiding moves the window to a parked named workspace.
Declare it in your niri config:

```kdl
workspace "spotify-scratch"
```

### Floating when launched from the widget

The widget starts Spotify as a native Wayland client, whose app-id is `spotify`
(lowercase). A normal `spotify-launcher` start runs under XWayland as `Spotify`.
niri regexes are case-sensitive, so this rule floats only widget-launched windows:

```kdl
window-rule {
  match app-id="^spotify$"
  open-floating true
  default-column-width { proportion 0.9; }
  default-window-height { proportion 0.9; }
}
```

Do not add the Wayland flags to `extra_arguments` in `spotify-launcher.conf`,
or every Spotify start will float.

## Requirements

- `spotify-launcher`
- niri (with `niri msg` IPC)
