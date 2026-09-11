# Animated SVG Wallpaper

Renders a CSS-animated SVG as your wallpaper, **with the animation actually
running**. Ordinary wallpaper tools rasterize an SVG to a single frozen frame;
this one hands the file to a WebKit view on a `wlr-layer-shell` background
surface, so `@keyframes` play live behind your desktop.

While it is active the plugin asks noctalia to release its own Background
surface on the affected outputs, so the two never draw over each other.

## Plugin

| Field | Value |
| --- | --- |
| ID | `theta/wl-svg-bg` |
| Entries | Service: `takeover` |

## Requirements

- **`wl-svg-bg`** on `PATH` — the renderer itself, a separate program that this
  plugin only drives. It is a single Python script from
  [M4jor-Tom/wl-svg-bg.py](https://github.com/M4jor-Tom/wl-svg-bg.py) and needs
  PyGObject with the GTK 4, WebKitGTK 6.0 and gtk4-layer-shell typelibs. On
  Arch that is `python-gobject gtk4 webkitgtk-6.0 gtk4-layer-shell`; a Nix flake
  and a home-manager module are in the repo.
- **`systemd`** — supplies `systemctl` and `systemd-run`, which start and stop
  the renderer's user unit.
- A compositor with **`wlr-layer-shell`**: niri, sway, Hyprland, labwc, and the
  rest of the wlroots family. This does not work on GNOME or KDE, which do not
  implement that protocol.

## Usage

1. Install `wl-svg-bg` and enable this plugin.
2. Open the plugin's settings and set **Animated SVG** to a CSS-animated `.svg`.
   One ships with the plugin at `examples/aurora.svg` if you do not have one —
   animated SVGs are rare, so start there.
3. The wallpaper starts immediately. noctalia stops drawing its own on every
   connected output, and monitors plugged in later are picked up automatically.

**To turn it off, clear the Animated SVG field.** That is the off-switch: it
stops the renderer and gives the outputs back to noctalia. Disabling the plugin
also stops the renderer, but the outputs stay released until noctalia restarts,
because the host discards side effects issued during teardown — so clearing the
field is the clean path.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `svg` | `file` | *(empty)* | Path to the CSS-animated SVG to render. Empty means the plugin claims nothing and starts nothing, which is also how you switch it off. |

## Notes

**Cost.** This runs a WebKit view per monitor, continuously, for as long as the
wallpaper is up. That is more expensive than a static wallpaper and it does not
pause when the screen is locked, occluded, or on battery — the compositor gives
a background surface no visibility signal to react to. Budget for it on a
laptop, and prefer SVGs that animate slowly and over large soft shapes:
`examples/aurora.svg` is built that way on purpose. A file full of fast
per-element transforms will cost far more.

**If the renderer dies**, its unit is restarted automatically
(`Restart=on-failure`). While it is down the outputs stay released, so the
screen shows the bare compositor background rather than your old wallpaper. If
it cannot start at all, the plugin hands every output back to noctalia and
notifies you, so a broken setup fails to your normal wallpaper instead of to
black.

**Processes spawned.** `systemctl --user start|restart|stop wl-svg-bg.service`,
and — only when no `wl-svg-bg.service` has been declared, which is every install
that does not use the project's home-manager module — `systemd-run --user` to
create a transient unit of the same name. The plugin never writes a unit file
and never runs `daemon-reload`.

**Files written.** One: `~/.local/state/wl-svg-bg/env`, holding
`WL_SVG_BG_SVG=<the path you picked>`. The renderer reads the SVG path from
there rather than from a command line, so paths containing spaces survive. The
plugin compares this file's contents before writing, and only restarts the
renderer when the path actually changed — which is what keeps a plain
`systemctl --user restart noctalia` from reloading your wallpaper.

**Network.** None. Nothing is fetched, and the rendered SVG is loaded from a
local `file://` URL.
