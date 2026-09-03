# Awwwall

Animated (GIF) wallpapers for Noctalia, powered by
[awww](https://codeberg.org/LGFae/awww) — using Noctalia's own wallpaper
picker and directory, not a separate one.

Noctalia's built-in wallpaper surface only shows static images. This plugin
runs a headless service that watches the wallpaper Noctalia's *official*
picker already recorded for each output and, whenever it changes, hands that
same file to `awww img`. Because Noctalia itself still owns the selection,
its Material You palette generation from the wallpaper keeps working exactly
as before.

The bar widget's toggle owns the whole `awww` lifecycle, so there is nothing
to set up by hand: turning it on starts `awww-daemon` (if it isn't already
running) and asks Noctalia to drop its own wallpaper surface on each output
(`setWallpaperEnabled`); turning it off restores Noctalia's surface and kills
the daemon.

## Plugin

| Field | Value |
| --- | --- |
| ID | `0lucasmatheus/awwwall` |
| Entries | Service: `mirror`; bar widget: `toggle` |

## Requirements

- `awww` (which includes `awww-daemon`) on `PATH`.
- A `wlr-layer-shell` compositor (Niri, Hyprland, Sway, Mango, ...).

## Usage

1. Add the **Awwwall** bar widget from the widget picker.
2. Click it to turn mirroring on. It starts `awww-daemon` for you if needed.
3. Pick a wallpaper the normal way (Noctalia's own **Wallpaper** widget /
   picker) — including GIFs from your configured wallpaper directory. Awwwall
   detects the change and applies it through `awww` within about a second.
4. Click the widget again to turn mirroring off; this restores Noctalia's own
   wallpaper rendering and kills the `awww` daemon.

## IPC

- `noctalia msg plugin 0lucasmatheus/awwwall:mirror all toggle` — toggles
  mirroring, same as clicking the bar widget.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `resize` | `select` | `crop` | How `awww` fits the image to the screen (`no`/`crop`/`fit`/`stretch`). |
| `transition_type` | `select` | `random` | `awww` transition effect. |
| `filter` | `select` | `Nearest` | Scaling filter `awww` uses when resizing. |
| `transition_duration` | `int` | `1` | Transition length in seconds (ignored by the `simple` transition). |

## Notes

Turning the bar widget on runs `awww query` to check whether `awww-daemon` is
already running (a plain process-name match can false-positive on unrelated
processes), starts it if not, and disables Noctalia's own wallpaper surface
per output. From then on, the `mirror` service polls
`noctalia.wallpaperPath(connector)` once a second and runs
`awww img <path> -o <connector>` with the settings above whenever it changes.
Turning the widget off restores Noctalia's surface on every output it had
hidden and runs `awww kill`; the same cleanup runs if the plugin is disabled
or Noctalia exits while mirroring is on. The on/off state persists across
Noctalia restarts in the plugin's data directory.
