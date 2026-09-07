# Niri Ribbon

A bar widget for niri's scrollable-tiling layout: it draws the focused workspace's whole scrolling ribbon as a slim overview strip and highlights the region currently inside the viewport, so you can see at a glance how many columns are hidden to the left and right — and scrolling over the widget moves the focused column.

## Plugin

| Field | Value |
| --- | --- |
| ID | `luochen1990/niri-ribbon` |
| Entries | Bar widget: `ribbon` |

## Requirements

- The [niri](https://github.com/YaLTeR/niri) compositor (declared as the `niri` dependency; the widget shells out to `niri msg`).
- Noctalia `5.0.0-beta.4` or newer for the scroll interaction (the `onScroll` bar-widget API).

## Usage

Add the widget via Noctalia Settings → Bar → widgets: pick **Niri Ribbon** and place it in the start/center/end section. It renders the focused workspace's scrolling ribbon; the highlighted segment is the current viewport.

Scroll up/left or down/right over the widget to move the focused column (equivalent to `focus-column-left` / `focus-column-right`).

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `bar_color` | `color` | `outline` | Color of the ribbon track (the non-visible area). |
| `viewport_color` | `color` | `primary` | Color of the viewport highlight. |
| `thickness` | `double` | `4.0` | Vertical thickness of the ribbon (logical pixels). |
| `radius` | `double` | `2.0` | Corner radius of the viewport highlight (logical pixels). |
| `viewport_model` | `select` | `fit` | How the viewport position is estimated; must match your niri `center-focused-column` setting: `fit` for `never` (niri default), `center` for `always`. |
| `gaps` | `double` | `0.0` | The `layout.gaps` value from your niri config (logical pixels); used for accurate canvas-width estimation. |

## Notes

- **Viewport position is estimated.** The niri IPC currently exposes neither the live viewport offset nor a viewport-scroll event, so the highlight is derived geometrically from the focused column (see the "Viewport estimation" section in `ribbon.luau` for the full model and its limitations). In short: the `fit` model is accurate for the common left-to-right focus flow and slightly off when focusing columns right-to-left or clicking a non-adjacent column inside the viewport. Exact rendering is tracked in [niri#4147](https://github.com/niri-wm/niri/pull/4147).
- **Spawned processes:** read-only `niri msg` IPC queries (`windows`, `workspaces`, `outputs`), one persistent `niri msg -j event-stream` subscription, and `focus-column-*` actions on scroll. No network access, no filesystem writes.
- **Credits:** the algorithm idea originates from [ews/noctalia-niri-ribbon](https://github.com/ews/noctalia-niri-ribbon) by J Pablo Puerta (quickshell/QML era); this plugin is a ground-up rewrite for the Noctalia v5 Luau plugin API.
