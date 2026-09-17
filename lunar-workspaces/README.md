# Lunar Workspaces (Noctalia v5)

A workspace indicator widget for [Noctalia](https://github.com/noctalia-dev/noctalia)
with moon-phase-style icons for focused, urgent, occupied, and empty
workspaces. Click a workspace to jump to it, scroll the widget to step
through workspaces. Supports **Hyprland** and **Niri**, auto-detected.

Port from [Lunar Workspaces V4](https://github.com/Niko-Cloud/Lunar-Workspace-Noctalia-Plugin).

## Plugin

| Field | Value |
| --- | --- |
| ID | `yuki/lunar-workspaces` |
| Entries | Bar widget: `lunar_workspaces`; service: `workspace-state` |

- Service `workspace-state` runs in the background: watches the compositor
  and publishes workspace state.
- Widget `lunar_workspaces` is the bar widget.

## Features

- 🌕 🌟 🌗 🌙 Separate icon, size, and pill color per workspace state
  (focused / urgent / occupied / empty): emoji, static image, or animated gif
- Optional smooth size-easing animation on focus/state changes
  (`enable_animation`)
- Fill or ghost pill style per state, with per-state custom colors
  (palette role, role with alpha like `primary/0.6`, or hex like `#rrggbbaa`)
- Click-to-switch and scroll-to-switch workspaces
- Three display modes: show all workspaces, only active/occupied ones, or
  all occupied plus one upcoming empty slot
- Per-monitor focus tracking: on a multi-monitor setup, each monitor's own
  active workspace is shown as focused, not just the single globally
  input-focused one
- Live updates via compositor IPC (Hyprland socket / Niri event stream),
  with a periodic resync as a fallback

## Usage

Add the widget to a bar in Noctalia's Add-widget picker, or add it to your
bar config manually:

```toml
type = "yuki/lunar-workspaces:lunar_workspaces"
```

Click a workspace pill to switch to it. Scroll over the widget to step to
the next/previous visible workspace.

## Requirements

- [Noctalia](https://github.com/noctalia-dev/noctalia) 5.0.0+ with plugin
  support (`plugin_api` 12+)
- Hyprland or Niri
- [`socat`](https://linux.die.net/man/1/socat), optional. Used for instant
  Hyprland IPC updates; without it the widget still works via periodic
  polling (60s resync plus event-driven refresh on Niri, which doesn't need
  socat).
- ImageMagick (`magick`, or the legacy `convert`/`identify` pair), optional,
  only needed if an icon setting points at a `.gif`. Without it, a gif icon
  still renders, just as a static first frame instead of animating.

## Installation

```bash
mkdir -p ~/.local/share/noctalia/plugins/lunar-workspaces
cp -r ./* ~/.local/share/noctalia/plugins/lunar-workspaces/
```

Enable the plugin:

```bash
noctalia msg plugins list                          # confirm it's discovered
noctalia msg plugins enable yuki/lunar-workspaces
```

Then add the **Lunar Workspaces** widget from Noctalia's Add-widget picker,
or add it to your bar config manually (see Usage above).

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Compositor | select | `auto` | `auto`, `hyprland`, or `niri` |
| Workspace visibility | select | `all` | `all`, `active_occupied`, or `once` (occupied + one upcoming empty slot) |
| Workspace count | int (1-20) | `9` | How many workspace slots to check |
| Animate transitions | bool | `true` | Smoothly ease icon size on focus/state changes instead of snapping instantly |
| Focused / Urgent / Occupied / Empty icon | file | 🌕 / 🌟 / 🌗 / 🌙 | Emoji, or an absolute path to an image or gif. Animated gifs need ImageMagick installed |
| Focused / Urgent / Occupied / Empty size | int (8-64) | `22` / `20` / `18` / `16` | Icon size in pixels per state |
| Focused / Urgent / Occupied / Empty pill background | select | `fill` / `fill` / `ghost` / `ghost` | `fill` (colored pill behind the icon) or `ghost` (bare icon, no background at all) |
| Focused / Urgent / Occupied / Empty pill color | color | `primary` / `error` / `secondary` / `surface_variant` | Fill color, used when the matching pill background is `fill`. Accepts a palette role, a role with alpha (`primary/0.6`), or a hex color (`#rrggbbaa`) |

## IPC

- **Compositor:** shells out to `hyprctl -j workspaces/activeworkspace/clients/monitors`
  on Hyprland, or `niri msg --json workspaces/windows/event-stream` on Niri,
  to build workspace state. No other IPC surface is used.

## Notes

- **Process:** spawns `hyprctl`/`niri msg` on a timer and on compositor
  events, `socat` for the Hyprland event socket (optional), and
  `magick`/`convert`/`identify` once per distinct gif icon file (optional,
  only when a `.gif` is configured).
- **Filesystem:** when an icon is set to a `.gif`, its frames are extracted
  once to `pluginDataDir()/gif-frames/<hash>-<mtime>/` and cached there
  indefinitely (not automatically pruned) so re-extraction isn't needed on
  every reload. No other files are read or written.
- **Network:** none.
- **Privacy:** window class/title text is read from the compositor (to
  build a per-workspace window list for a possible future tooltip feature;
  not yet surfaced in the widget itself) and truncated to 24 characters.
  It stays in local in-memory plugin state and is never written to disk or
  sent anywhere.

## Development

```bash
cd ~/.local/share/noctalia/plugins/lunar-workspaces
python3 -c "import tomllib; tomllib.load(open('plugin.toml','rb'))"  # validate manifest
```

Run Noctalia from a terminal (not autostarted) while testing so
`noctalia.log(...)` output and Luau errors print live. `.luau` file edits
hot-reload; `plugin.toml` changes require a config reload
(`noctalia msg config-reload`) or restart.

## License

This project is licensed under the [MIT License](LICENSE).
