# AI GENERATED CONTENT

# Scroll Tools for Noctalia

ScrollWC-specific bar widgets  for [Noctalia Shell v5](https://github.com/noctalia-dev/noctalia-shell) running under the [Scroll](https://github.com/dawsers/scroll) compositor. Mirrors the `ScrollScroller` / `ScrollTrails` / `ScrollSubmap` integration from `dawsers/gtkshell` for Noctalia.

> Noctalia core already treats Scroll as Sway-IPC-compatible (Scroll exports `SWAYSOCK`), so generic workspaces, window-title, and keyboard-layout widgets work out of the box. This plugin only adds the **Scroll-specific extras** that have no sway/i3 equivalent: scroller modifiers, trails, and binding mode.

## Features

| Surface | ID | Type | Description |
|---------|----|------|-------------|
| **Scroller HUD** | `scroller` | Bar widget (`scroller_widget.luau:1`) | Compact one-line HUD of the focused workspace's scroller state: direction, insert position, focus, reorder, fit, centering, overview, and scale. Click to open the control panel. |
| **Trails Counter** | `trails` | Bar widget (`trails_widget.luau:1`) | Displays `active/length (marks)` for Scroll trails. |
| **Binding Mode Indicator** | `submap` | Bar widget (`submap_widget.luau:1`) | Shows the current Scroll binding mode / submap name. Auto-hides when in `default` mode. |
| **Scroller Controls** | `scroller-controls` | Panel (`scroller_panel.luau:1`) | Interactive control panel for all scroller modifiers on the focused workspace. |

## Requirements

- **Noctalia Shell v5** (plugin API `8`)
- **Scroll compositor** running
- **`scrollmsg`** on `PATH` — the Scroll IPC CLI (ships with Scroll)
- A valid IPC socket — resolved as `SCROLLSOCK` → `SWAYSOCK` (or the `socket_path` setting override)

When `scrollmsg` is missing or no socket is found, all widgets hide themselves gracefully and set `scroll.available = false` in `noctalia.state`.

## Widgets

### 1. Scroller (`scroller`) — `scroller_widget.luau:26`

Event-driven via `scrollmsg -t subscribe -m -r '["scroller"]'` (`scroll_ipc.luau:39`). No polling — the widget stretches Noctalia's update interval to 1 hour (`scroller_widget.luau:12`) and updates only on IPC events.

**Bar text format** (`scroller_widget.luau:26`):

```
<mode> <insert> <focus> <reorder> <fit><centerH><centerV><overview>[ scale]
```

| Field | Icon mode (`show_icons = true`) | Text mode | Source |
|-------|----------------------------------|-----------|--------|
| Mode | `-` (horizontal) / `|` (vertical) | `H` / `V` | `scroller.mode` |
| Insert | `→` after / `←` before / `⇥` end / `⇤` beginning | `>` / `<` / `E` / `B` | `scroller.insert` |
| Focus | `◉` focus / `◎` nofocus | `f` / `-` | `scroller.focus` |
| Reorder | `A` auto / `M` manual | `a` / `-` | `scroller.reorder` |
| Fit | `·` nofit / `S` fitsplit / `F` fitfraction | `-` / `S` / `F` | `scroller.fit` |
| Center H | `⇔` when on | `h` / `` | `scroller.center_horizontal` |
| Center V | `⇕` when on | `v` / `` | `scroller.center_vertical` |
| Overview | `󰆾` when on | ` *` | `scroller.overview` |
| Scale | ` 1.25x` when `scaled == true` | same | `scroller.scale` |

Hover shows a tooltip with all fields expanded (`scroller_widget.luau:69`). Clicking the widget toggles the `scroller-controls` panel (`scroller_widget.luau:133`).

The widget also publishes the latest scroller object to `noctalia.state["scroll.scroller"]` for the control panel, deduplicated by fingerprint (`scroll_state.luau:15`).

### 2. Trails (`trails`) — `trails_widget.luau:11`

Subscribes to `["trails"]` events (`trails_widget.luau:52`).

**Format:** `active/length (marks)` — e.g. `2/5 (3)` (`trails_widget.luau:18`)

- `active` → `trails.active`
- `length` → `trails.length`
- `marks` → `trails.trail_length`

Tooltip: `Scroll trails: position / length (marks)`.

### 3. Submap / Binding Mode (`submap`) — `submap_widget.luau:16`

Subscribes to `["mode"]` events (`submap_widget.luau:60`).

- Hidden when mode is `nil`, empty, or `"default"` — only appears when a non-default binding mode is active.
- Icon mode: `⌨ <mode>` · Text mode: `MODE: <mode>` (`submap_widget.luau:16`).
- Handles both live events (`{change: "<mode>"}`) and the initial `get_binding_state` fetch (`{name: "<mode>"}`) (`submap_widget.luau:41`).

## Panel: Scroller Controls (`scroller-controls`) — `scroller_panel.luau:1`

Attached panel (`320×380`, auto-placed, dismiss on outside click — `plugin.toml:42`) that mirrors the popover in `ScrollScroller` (`gtkshell/scroll.cpp`).

| Control | Type | Command sent via `scrollmsg -- <cmd>` |
|---------|------|----------------------------------------|
| Direction | Select: Horizontal / Vertical | `set_mode h` / `set_mode v` (`scroller_panel.luau:143`) |
| Insert position | Select: After / Before / Beginning / End | `set_mode after` / `before` / `beginning` / `end` (`scroller_panel.luau:146`) |
| Focus new window | Toggle | `set_mode focus` / `nofocus` (`scroller_panel.luau:153`) |
| Auto reorder | Toggle | `set_mode reorder_auto` / `noreorder_auto` (`scroller_panel.luau:157`) |
| Fit | Select: No fit / Split / Fraction | `set_mode nofit` / `fitsplit` / `fitfraction` (`scroller_panel.luau:161`) |
| Center column | Toggle | `set_mode center_horiz` / `nocenter_horiz` (`scroller_panel.luau:168`) |
| Center window | Toggle | `set_mode center_vert` / `nocenter_vert` (`scroller_panel.luau:172`) |
| Refresh | Button | Re-fetches `get_scroller` via IPC (`scroller_panel.luau:176`) |

The panel watches `scroll.scroller` state and re-renders only when its semantic fingerprint changes (`scroller_panel.luau:130`, `scroll_state.luau:50`), avoiding churn from irrelevant fields like scale precision.

If Scroll is not detected, the panel shows a placeholder message (`scroller_panel.luau:47`).

## Settings — `plugin.toml:15`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `socket_path` | string (advanced) | `""` | Override IPC socket path. When empty, resolves `SCROLLSOCK` → `SWAYSOCK` via `scroll_ipc.luau:9`. |
| `show_icons` | bool | `true` | Use compact glyphs in `scroller` and `submap` widgets instead of plain-text labels (`translations/en.json:7`). |

Configure via Noctalia Settings → Plugins → Scroll Tools, or directly in your Noctalia config.

## How It Works

```
scroll_state.luau          Semantic fingerprints + publishIfChanged
        ▲
        │
scroller_widget ──┬──► scroll_ipc.luau ──► scrollmsg -t get_scroller / subscribe
                  │         ├─ socketPath():  SCROLLSOCK → SWAYSOCK → socket_path override
trails_widget ────┤         ├─ scrollmsgBase(): builds `scrollmsg -s '<socket>'`
                  │         ├─ subscribe(eventsJson, onLine): runStream
submap_widget ────┤         └─ fetch(ipcType, onEnvelope): runAsync
                  │
scroller_panel ───┘──► noctalia.state["scroll.scroller"] (watch) + scrollmsg -- set_mode …
```

- Each widget owns its own `scrollmsg subscribe` long-lived stream (`scroll_ipc.luau:39`), matching `ScrollIpc::working_thread` in `gtkshell`.
- One-shot state is fetched via `scroll_ipc.fetch()` (`scroll_ipc.luau:44`) on startup (`get_scroller`, `get_trails`, `get_binding_state`).
- `scroll_state.luau:15` provides three fingerprints — full scroller (bar display, scale rounded to `%.2f`), trails, and panel scroller (excludes scale/overview) — so watchers only fire on visible changes.
- Commands from the panel are sent as `scrollmsg -- <command>` via `runAsync` (`scroller_panel.luau:9`).

## Project Structure

```
scroll-tools/
├── plugin.toml              # Plugin manifest, settings, widget/panel declarations
├── scroll_ipc.luau          # Shared scrollmsg helpers (socket resolution, subscribe, fetch)
├── scroll_state.luau        # Fingerprinting + deduplicated state publishing
├── scroller_widget.luau     # Bar widget: scroller HUD
├── trails_widget.luau       # Bar widget: trails counter
├── submap_widget.luau       # Bar widget: binding-mode indicator
├── scroller_panel.luau      # Panel: interactive scroller controls
└── translations/
    └── en.json              # English strings for settings
```

## Compatibility

- Tested with Noctalia plugin API `8`.
- Scroll is supported natively by Noctalia's Sway-IPC compatibility layer; no extra Noctalia configuration is needed beyond this plugin.
- The plugin is a no-op (widgets hidden) on non-Scroll compositors (Sway, Hyprland, etc.).

## License

MIT — see `plugin.toml:6`. Author: n3ptune-plan3t (n3ptune-plan3t).
