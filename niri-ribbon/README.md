# Niri Ribbon

A bar widget for niri and Umbriel's scrolling layouts: it draws the active workspace's whole scrolling ribbon on each monitor as a slim overview strip and highlights the region currently inside the viewport, so you can see at a glance how many columns are hidden to the left and right — and scrolling over the widget moves the focused column.

## Plugin

| Field | Value |
| --- | --- |
| ID | `luochen1990/niri-ribbon` |
| Entries | Bar widget: `ribbon`; shared service: `compositor` |

## Requirements

- Either [niri](https://github.com/niri-wm/niri) or [Umbriel](https://docs.noctalia.dev/umbriel/ipc/), with its CLI in PATH. The shared service detects the compositor from the session environment.
- Noctalia `5.0.0-beta.4` or newer for the scroll interaction (the `onScroll` bar-widget API).

## Usage

Add the widget via Noctalia Settings → Bar → widgets: pick **Niri Ribbon** and place it in the start/center/end section. Each instance renders its own monitor's active workspace; the highlighted segment is the current viewport. Reported tile positions are used automatically when available; otherwise, estimated viewport positions are remembered separately by workspace ID.

The highlight smoothly animates position and width changes over 200 ms at the default **Animation Speed** of **1×**. Higher speeds are faster; **0** disables animations. Rapid changes continue from the current animated position; the initial state appears immediately.

Scroll up/left or down/right over the widget to run `focus-column-left` / `focus-column-right` on niri's currently focused monitor. The widget does not switch monitor focus, avoiding the pointer warp caused by `focus-monitor`. Each ribbon still displays its own monitor's active workspace.

Enable **Show Active Window** to mark the active tiled window within the viewport. **Active Window Color** (default: `secondary`) sets the solid marker color. The marker follows the window's horizontal tile footprint, animates on focus/size changes, and is clipped to the visible region. Stacked windows share a horizontal footprint; floating windows have no marker.

## Umbriel

Umbriel uses its window, workspace, and output snapshots plus one shared event subscription. Global window positions are translated relative to each monitor, including monitors with negative coordinates. Actual window extents supply spacing, so `gaps` and `viewport_model` apply only to niri. Umbriel reports window geometry rather than decorated tile sizes, so borders can introduce small differences.

Scrolling sends `umbriel msg window-focus-left` / `window-focus-right`, relative to compositor focus. Other layouts display a full-width highlight without an active-window marker or scroll actions. Enable **Hide Outside Scrolling Layout** to hide the widget on those Umbriel workspaces instead; it reappears when the monitor returns to a scrolling workspace. This setting is off by default and never hides niri's ribbon.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `hide_non_scrolling` | `bool` | `false` | Hide on Umbriel workspaces whose layout is not scrolling. |
| `animation_speed` | `double` | `1.0` | Speed multiplier from 0 to 3; 0 disables animations, 1 is normal, higher is faster. |
| `bar_color` | `color` | `outline` | Color of the ribbon track (the non-visible area). |
| `viewport_color` | `color` | `primary` | Color of the viewport highlight. |
| `show_active_window` | `bool` | `false` | Show the active tiled window inside the viewport with a solid color. |
| `active_window_color` | `color` | `secondary` | Color of the active-window marker. |
| `thickness` | `double` | `4.0` | Vertical thickness of the ribbon (logical pixels). |
| `radius` | `double` | `2.0` | Corner radius of the viewport highlight (logical pixels). |
| `viewport_model` | `select` | `fit` | Fallback when no tile position is reported; should match your niri `center-focused-column` setting: `fit` for `never` (niri default), `center` for `always`. |
| `gaps` | `double` | `0.0` | The `layout.gaps` value from your niri config (logical pixels); used for accurate canvas-width estimation. |

## Notes

- **Automatic position detection:** when niri supplies `layout.tile_pos_in_workspace_view` for a tiled window ([niri#4711](https://github.com/niri-wm/niri/pull/4711)), the ribbon derives the viewport offset from that position. Any visible tile can serve as the reference, including when a floating window has focus. Position-only layout events update the ribbon without extra queries. Off-screen tiles may report `null`; if no tiled position is available, the existing per-workspace `fit`/`center` estimate is used. No version check or opt-in setting is required.
- **Geometry settings:** keep `gaps` matched to your niri config: column widths plus gaps still determine the total ribbon width and each tile's canvas position. `viewport_model` only affects the fallback estimate. The ribbon uses the output's logical width as its viewport and clamps the highlight to the track, so blank space beyond the first/last column is not drawn separately.
- **Resource use:** one shared service maintains the compositor cache for all monitors. It applies window/workspace events directly, ignores title and vertical-only changes, and batches changed views over 33 ms. Widgets receive only their monitor’s active workspace geometry and stop animation updates when settled.
- **Recovery:** one shared snapshot round every 60 seconds covers missed events. Output topology/config changes also refresh output geometry, at most once per second. Failed queries preserve cached data, and older query responses cannot overwrite newer events. A stopped event stream reconnects after two seconds.
- **Umbriel processes:** `umbriel windows/workspaces/outputs --json`, one shared `umbriel subscribe windows,workspaces,outputs` stream, and `window-focus-*` actions on scroll.
- **Niri processes:** read-only `niri msg` IPC queries (`windows`, `workspaces`, `outputs`), one shared `niri msg -j event-stream` subscription with a reconnecting shell, and `focus-column-*` actions on scroll. No network access, no filesystem writes.
- **Credits:** the algorithm idea originates from [ews/noctalia-niri-ribbon](https://github.com/ews/noctalia-niri-ribbon) by J Pablo Puerta (quickshell/QML era); this plugin is a ground-up rewrite for the Noctalia v5 Luau plugin API.
