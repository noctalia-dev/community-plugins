# Flatpak Background Apps

Shows Flatpak apps that are still running but have no window open in niri,
such as chat, sync or download apps that keep running after you close their
window, and lets you stop them from the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `naijnus/flatpak-bg` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `scanner` |

## Requirements

- The niri compositor, with `niri` on `PATH`. Windows are read from niri's
  IPC, so other compositors are not supported.
- `flatpak`, used to find the installations and to force-stop apps.
- `sh`, `kill` and `sleep` from the base system, used to run the niri event
  stream, ask apps to quit and wait for the stop timeout.

## Usage

Add the **Flatpak Background Apps** bar widget (`bar`) to a bar in Settings.
It stays hidden while no Flatpak app runs in the background. Otherwise it
shows how many do, and its tooltip lists their names. If a scan fails, it shows
`!` and the tooltip says so.

Click the widget to open the panel. It lists each background app with its icon,
name and app id. **Stop** asks the app to quit; the button reads **Stopping…**
until the app is gone. The refresh button in the header rescans right away.

The panel can also be toggled from a keybind or script:

```sh
noctalia msg panel-toggle naijnus/flatpak-bg:panel
```

An app counts as running in the background when it has a running Flatpak
instance and none of its windows is open in niri. A window belongs to an app
when its process runs inside the app's sandbox, or when its niri `app_id`
matches the app id, the last part of the app id, or the `StartupWMClass` of the
app's desktop file. The last two cover X11 apps through xwayland-satellite.
A freshly started app gets 5 seconds to open its first window before it is
listed.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `interval` | `int` | `5` | Seconds between checks for Flatpak apps that started or exited (1 to 60). Window changes are picked up immediately and do not wait for this. |
| `stop_timeout` | `int` | `5` | Seconds an app gets to quit after **Stop** before it is killed with `flatpak kill` (1 to 30). |
| `glyph` | `glyph` | `box-multiple` | Icon shown in the bar widget and in the panel header. |

## IPC

Trigger an immediate rescan, for example from a script that starts an app:

```sh
noctalia msg plugin naijnus/flatpak-bg:scanner all refresh
```

## Notes

- **Stopping an app:** **Stop** sends `SIGTERM` to the app's main sandboxed
  process (`kill -TERM <pid>`), so it can save its state. If the app is still
  running after `stop_timeout` seconds, the plugin runs `flatpak kill <app-id>`,
  which ends it without a chance to clean up.
- **Processes started:** `flatpak --installations` once at startup;
  `niri msg -j event-stream` through `sh`, kept running while the plugin is
  enabled and restarted if niri restarts; `niri msg -j windows` only while that
  stream is down; and `kill`, `sleep` and `flatpak kill` when you stop an app.
  A regular check starts no process.
- **Files read:** Flatpak instance data in `$XDG_RUNTIME_DIR/.flatpak/`,
  `/proc/<pid>/root/.flatpak-info` of sandboxed processes, and the exported
  desktop files of the Flatpak installations, for app names. The plugin
  writes no files and makes no network requests.
