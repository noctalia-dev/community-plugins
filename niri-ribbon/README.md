# Niri Ribbon

A bar widget for niri's scrollable-tiling layout: it draws the active workspace's whole scrolling ribbon on each monitor as a slim overview strip and highlights the region currently inside the viewport, so you can see at a glance how many columns are hidden to the left and right — and scrolling over the widget moves the focused column.

## Plugin

| Field | Value |
| --- | --- |
| ID | `luochen1990/niri-ribbon` |
| Entries | Bar widget: `ribbon`; shared service: `compositor` |

## Requirements

- The [niri](https://github.com/YaLTeR/niri) compositor (declared as the `niri` dependency; the widget shells out to `niri msg`).
- Noctalia `5.0.0-beta.4` or newer for the scroll interaction (the `onScroll` bar-widget API).

## Usage

Add the widget via Noctalia Settings → Bar → widgets: pick **Niri Ribbon** and place it in the start/center/end section. Each instance renders its own monitor's active workspace; the highlighted segment is the current viewport. Estimated viewport positions are remembered separately by workspace ID.

The highlight smoothly animates position and width changes over 200 ms at the default **Animation Speed** of **1×**. Higher speeds are faster; **0** disables animations. Rapid changes continue from the current animated position; the initial state appears immediately.

Scroll up/left or down/right over the widget to run `focus-column-left` / `focus-column-right` on niri's currently focused monitor. The widget does not switch monitor focus, avoiding the pointer warp caused by `focus-monitor`. Each ribbon still displays its own monitor's active workspace.

Enable **Show Active Window** to mark the active tiled window within the viewport. **Active Window Color** (default: `secondary`) sets the solid marker color. The marker follows the window's horizontal tile footprint, animates on focus/size changes, and is clipped to the visible region. Stacked windows share a horizontal footprint; floating windows have no marker.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `animation_speed` | `double` | `1.0` | Speed multiplier from 0 to 3; 0 disables animations, 1 is normal, higher is faster. |
| `bar_color` | `color` | `outline` | Color of the ribbon track (the non-visible area). |
| `viewport_color` | `color` | `primary` | Color of the viewport highlight. |
| `show_active_window` | `bool` | `false` | Show the active tiled window inside the viewport with a solid color. |
| `active_window_color` | `color` | `secondary` | Color of the active-window marker. |
| `thickness` | `double` | `4.0` | Vertical thickness of the ribbon (logical pixels). |
| `radius` | `double` | `2.0` | Corner radius of the viewport highlight (logical pixels). |
| `viewport_model` | `select` | `fit` | How the viewport position is estimated; must match your niri `center-focused-column` setting: `fit` for `never` (niri default), `center` for `always`. |
| `gaps` | `double` | `0.0` | The `layout.gaps` value from your niri config (logical pixels); used for accurate canvas-width estimation. |

## Notes

- **Viewport position is estimated.** Standard niri IPC does not expose the live viewport offset. The `fit` model remembers the position per workspace, scrolls in either direction to reveal an off-screen focused column, and keeps the position when the focused column is already visible. The initial position, scrolling without a focus change, and custom struts can still differ from niri. Match the viewport model and gaps settings to your niri config. Exact viewport IPC is tracked in [niri#4147](https://github.com/niri-wm/niri/pull/4147).
- **Resource use:** one shared service maintains the compositor cache for all monitors. It applies window/workspace events directly, ignores title and vertical-only changes, and batches changed views over 33 ms. Widgets receive only their monitor’s active workspace geometry and stop animation updates when settled.
- **Recovery:** one shared snapshot round every 60 seconds covers missed events. Output topology/config changes also refresh output geometry, at most once per second. Failed queries preserve cached data, and older query responses cannot overwrite newer events. A stopped event stream reconnects after two seconds.
- **Spawned processes:** read-only `niri msg` IPC queries (`windows`, `workspaces`, `outputs`), one shared `niri msg -j event-stream` subscription with a reconnecting shell, and `focus-column-*` actions on scroll. No network access, no filesystem writes.
- **Credits:** the algorithm idea originates from [ews/noctalia-niri-ribbon](https://github.com/ews/noctalia-niri-ribbon) by J Pablo Puerta (quickshell/QML era); this plugin is a ground-up rewrite for the Noctalia v5 Luau plugin API.
