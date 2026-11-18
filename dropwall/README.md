# DropWall

Drag a local image anywhere onto the desktop to set it as the wallpaper in
Noctalia v5.

The image is applied through Noctalia's own wallpaper API, so the regular fill
mode, fill color, transitions, and wallpaper state remain in effect.

## Plugin

| Field | Value |
| --- | --- |
| ID | `whyoolw/dropwall` |
| Entries | Service: `service` (`service.luau`) |

DropWall is a headless service plugin. It does not add a bar widget or panel;
enabling the plugin starts the desktop drop target service.

## Usage

1. Enable `whyoolw/dropwall` from Noctalia's plugin store or with
   `noctalia msg plugins enable whyoolw/dropwall`.
2. Drag a local image file onto the bare desktop.
3. Drop it on any monitor to apply it as the wallpaper through Noctalia's
   wallpaper settings.
4. Optional: open **Settings -> Plugins -> DropWall** to enable per-monitor
   drops, safe copying into the wallpaper directory, notifications, or the
   alternate `bottom` layer.

## Features

- Full-desktop drop targets on every connected monitor.
- Optional per-monitor application based on the monitor receiving the drop.
- Optional safe copy into Noctalia's wallpaper directory.
- A subtle dashed highlight while a file is dragged over the desktop.
- Automatic monitor hotplug handling and helper recovery.

## How it works

- A headless service opens one long-lived stream to
  `dropwall_supervisor.py`. The supervisor owns a GTK3 + gtk-layer-shell
  worker and restarts it after an unexpected exit without consuming extra
  Noctalia stream slots.
- The worker keeps one fully transparent layer-shell surface per monitor,
  anchored to all edges. A runtime lock, parent-death signals, and pipe
  heartbeats prevent orphaned or duplicate workers.
- Dragging a file over the desktop shows a subtle dashed drop highlight.
- On drop, the worker accepts only a local regular file with a supported
  extension (`jpg`, `jpeg`, `png`, `webp`, `bmp`, or `gif`). It reports a
  percent-encoded path and the monitor's logical geometry to the service.
- The service matches that geometry against `noctalia.outputs()` and applies
  the image with `noctalia.setWallpaper()`. Ambiguous per-monitor matches fail
  safely instead of changing every output.
- When copying is enabled, the service resolves the current theme's wallpaper
  directory for that drop and starts `dropwall_copy.py`. The copier writes a
  private hidden temporary file, flushes it, then publishes the complete file
  atomically without replacing anything. `photo-1.jpg`, `photo-2.jpg`, and so
  on are used for name collisions.

## Requirements

- `python3`
- Python GObject bindings (`python-gobject` / `python3-gi`)
- GTK 3 and the GTK Layer Shell typelib (`gtk3`, `gtk-layer-shell`)
- A compositor with wlr-layer-shell support (niri, Hyprland, sway, …)

Package names vary between distributions. Install the packages that provide
Python 3, PyGObject, GTK 3, and the GTK Layer Shell typelib on your system.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| Per-monitor drop | off | Set only on the monitor you dropped on; off = system behavior |
| Copy into wallpaper directory | off | Create a non-overwriting copy in Noctalia's wallpaper directory before applying |
| Notify on set | on | Notification when applied |
| Drop surface layer | background | Use `bottom` if drops do not register; the service restarts automatically |

## Process, filesystem, and network behavior

DropWall keeps two local Python processes running: a small supervisor and its
GTK worker. It writes a PID lock named `noctalia-dropwall.lock` in
`$XDG_RUNTIME_DIR`. With **Copy into wallpaper directory** enabled, each drop
starts one short-lived Python copier and writes a mode-0600 image to the
directory returned by Noctalia. A completed copy appears atomically and
existing files are never overwritten. The copier watches the exact GTK worker
that accepted the drop and cleans up if the plugin is stopped or reloaded.
Before a copy, the copier removes only
owned `.dropwall-copy-*.tmp` files older than 24 hours that an unclean shutdown
may have left in that directory. With copying disabled, Noctalia keeps
referring to the original file, so moving or deleting that file can break the
wallpaper.

DropWall makes no network requests and never downloads or executes remote
code.

## Notes

- The drop surface accepts pointer input over the bare desktop (that's what
  makes Wayland DnD target it). Noctalia desktop widgets live on their own
  surfaces and are unaffected.
- Files dragged from browsers as remote URLs (not `file://`) are ignored —
  save the image first.
- If the highlight does not appear, switch **Drop surface layer** from
  `background` to `bottom`. If startup still fails, check Noctalia's log for
  messages prefixed with `dropwall helper:` and verify the dependencies above.

## License

MIT — see [LICENSE](LICENSE).
