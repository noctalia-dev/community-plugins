# Smart Taskbar

A compact application dock inside the Noctalia bar: grouped windows, focused-app switching, optional hover enlargement, and a clipped icon strip that stays within its width budget.

**Requires plugin API 52+.** Version 1.0.0 release candidate supports Umbriel, niri, Hyprland, Mango and Sway through public compositor protocols. Umbriel and niri prefer native subscriptions on API 54+. Native desktop acceptance and real screenshots remain pending. The images below are labeled offline fixture previews.

## Plugin

| Field | Value |
| --- | --- |
| ID | `omardardery/smart-taskbar` |
| Entry | Bar widget: `taskbar` |
| Full widget type | `omardardery/smart-taskbar:taskbar` |
| License | MIT |

## Requirements

- Noctalia with API 52 or newer. Use the host's reported API range rather than the version label alone.
- Umbriel: `umbriel` and `sleep` on PATH on API 52/53. API 54+ native events need neither helper.
- niri: `niri` for explicit focus/close actions; `niri` and `sleep` for the event stream on API 52/53.
- Hyprland: Python 3.9+ (`python3`) for public local socket events/snapshots; `hyprctl` for explicit focus/close actions.
- Mango: Python 3.9+ (`python3`) and public `watch all-clients` / `watch all-monitors` support; `mmsg` for explicit focus/close/minimize actions.
- Sway: Python 3.9+ (`python3`) for public i3 IPC; `swaymsg` for explicit focus/close actions.
- `gtk-launch` only for launching pinned desktop entries. Preserve their original desktop-entry ID case. Launches are detached from widget reload; immediate launch failures are reported, but desktop-entry utility errors are not captured.
- Install only the dependencies for your compositor and enabled features. Missing helpers are reported without a repeated process-start loop. Other compositors, including labwc and KDE, stay hidden.

## Usage

```sh
noctalia msg plugins source add smart-taskbar git https://github.com/OmarDardery/smart-taskbar-noctalia
noctalia msg plugins enable omardardery/smart-taskbar
```

For an existing installation:

```sh
noctalia msg plugins update smart-taskbar
noctalia msg plugins enable omardardery/smart-taskbar
```

Use your configured source name if it differs from `smart-taskbar`. Add **Smart Taskbar / taskbar** in Settings → Bar. Its full type is `omardardery/smart-taskbar:taskbar`.

For a hand-written configuration, define the instance below and include `smart_taskbar` in your existing bar's `start`, `center`, or `end` list:

```toml
[widget.smart_taskbar]
type = "omardardery/smart-taskbar:taskbar"
capsule = false
capsule_padding = 0
scale = 1.0
max_width = 420
collapsed_width = 64
```

Use bar and widget scale 1, no custom label, and no capsule-group wrapper padding for a matching outer width budget. The plugin's extent includes its own padding and arrows. Output DPI scaling preserves logical pixels. On side bars the main-axis limit applies to height.

The widget **disappears completely when no matching windows are open**: no icon, capsule, or count placeholder. It reappears from compositor events when a matching window opens. Pinned launchers also hide while there are no matching running windows; keep Noctalia's launcher available for starting the first application. Including minimized windows is enabled by default.

Hover to expand, then leave to collapse after the configured delay. Click capsule padding to toggle, or choose click/always-expanded mode. Clicking an app focuses or cycles its windows. A single-window app shows just its icon; duplicate windows add a numeric corner badge. There are no dot indicators, dashes, or empty count lanes. When windows remain open but focus is on the desktop, the collapsed capsule shows a running application.

Wheel vertically or horizontally to navigate overflowing applications. The strip renders a bounded subset with discrete item/page navigation and reveals newly focused apps. Each new wheel/touchpad gesture moves one configured step; the host accumulates fine touchpad input into whole detents. Arrows indicate hidden content. This is not pixel-continuous scrolling.

For a dock-style layout, choose **Always expanded**, application grouping, numeric badges, and optionally pinned applications. Remove your old taskbar and disable the dock after verifying the replacement on your desktop.

### Hover enlargement

Expand **Widget** in the settings dialog and enable **Enlarge icons on hover**. The default factor is 1.15. Icons scale smoothly inside fixed cells, so neighboring apps, count badges, and the rest of the bar stay in place. The maximum size is reserved while the option is enabled; there is no width growth while moving the pointer.

Choose a bar thickness of at least `ceil(icon_size × hover_scale) + 8` logical pixels. A 22 px icon at 1.15 fits a 34 px bar. Larger scales need more room; the host clips drawing to bar thickness. Disable **Animate transitions** for immediate enlargement and reduced motion. This is in-bar magnification, not a floating macOS-style surface extending beyond the bar.

### Actions and ordering

Manual sorting lets you drag an application onto another to place it before that app. It changes taskbar order, not compositor layout. Expansion stays open until clicked in manual mode because the public API has no drag-start/end callback. Manual order is per instance and resets on reload/restart. IPC previous/next provides a non-drag overflow alternative; the bar does not take keyboard focus.

Right click opens settings. Middle click retains Noctalia's built-in settings gesture. To use optional Close or Minimize/Restore actions, explicitly free middle click and select its action in **Widget**:

```toml
[widget.smart_taskbar.actions]
middle = "none"
```

The action targets the hovered group, preferring its focused window, or the group's first window. Capsule padding targets the focused group. Host bindings take precedence over widget-level callbacks; inline app controls consume their own left-clicks. Right, middle, and scroll use the host gesture path.

## Settings

Expand **Widget** in the normal settings dialog. All plugin controls are shown together, in related order: behavior, applications, layout, appearance, interaction, and diagnostics. There is no page dropdown and no hidden plugin-controls toggle. The public manifest API does not expose custom accordion sections, so these areas are logical ordering, not separate host sections. The normal host-owned Content, Colors, Size and Text, Capsule, Behavior, and Actions sections remain separate.

| Area | Setting | Default | Meaning |
| --- | --- | --- | --- |
| Behavior | `expand_mode` | `"hover"` | Hover to reveal running apps, click to toggle, or keep the dock expanded. |
| Behavior | `hover_delay` | `150` | Wait before opening the application strip on hover. |
| Behavior | `collapse_delay` | `400` | Wait after the pointer leaves. Manual sorting stays open until clicked to protect drags. |
| Behavior | `animations` | `true` | Smooth expansion fades and optional icon enlargement. Turn off for reduced motion. |
| Behavior | `animation_duration` | `120` | Duration of short fades and hover enlargement; no idle frame loop. |
| Applications | `display_mode` | `"running"` | Additional workspace and output filters below apply to running windows. |
| Applications | `grouping` | `"app"` | Unknown application IDs remain separate. Workspace groups use a representative application icon. |
| Applications | `workspace_filter` | `"all"` | Active uses compositor active or focused workspaces; combines with output filtering. |
| Applications | `output_filter` | `"all"` | Current means this bar instance’s output, not the globally focused monitor. |
| Applications | `show_minimized` | `true` | Umbriel and Mango report minimized state; unavailable state is treated as not minimized. |
| Applications | `sorting` | `"launch"` | Launch order means first observed order. Manual order is per instance and resets on reload. |
| Applications | `pinned_apps` | `[]` | Exact desktop-entry IDs for launchers. Launchers appear with matching open windows; the entire widget hides when no matching windows remain. |
| Applications | `exclusions` | `[]` | Exact normalized desktop/application IDs. No shell patterns. |
| Layout | `min_width` | `64` | Minimum expanded extent in logical pixels, limited by maximum width. |
| Layout | `max_width` | `420` | Main-axis limit, including padding and arrows. Use bar/widget scale 1 and host capsule padding 0 for the same outer limit. |
| Layout | `collapsed_width` | `64` | Fixed collapsed extent in logical pixels. Hidden completely when no matching windows are open. |
| Layout | `icon_size` | `22` | Base size in logical pixels. Leave room for hover enlargement within your bar thickness. |
| Layout | `icon_spacing` | `4` | Gap between application cells. Single-window apps have no count lane or marker. |
| Layout | `overflow_behavior` | `"items"` | Wheel navigation replaces visible items; the viewport is clipped. |
| Layout | `show_scroll_indicators` | `true` | Subtle direction indicators inside the width budget. |
| Appearance | `collapsed_label` | `"none"` | Optional text within the fixed width. Single-window apps never show a count; side bars show the icon only. |
| Appearance | `duplicate_indicator` | `"badge"` | Numeric corner badges appear only for applications with more than one window. |
| Appearance | `badge_placement` | `"after"` | Place duplicate-window count badges at the upper left or upper right of the icon. |
| Appearance | `hover_enlarge` | `false` | Magnify the hovered application inside a fixed cell. No bar movement; respects reduced motion. |
| Appearance | `hover_scale` | `1.15` | Maximum icon scale. Set bar thickness to at least icon size × scale + 8 logical pixels; 1.15 fits a 22 px icon in a 34 px bar. |
| Appearance | `capsule_radius` | `14` | Logical pixels for the plugin’s own theme-colored capsule. |
| Appearance | `opacity` | `0.9` | Background alpha only; icons and text stay opaque. |
| Appearance | `border` | `false` | Use the active theme outline role. |
| Appearance | `active_indicator` | `true` | Use the theme primary container role. |
| Appearance | `minimized_indicator` | `true` | Dim a group only when every member is minimized. |
| Appearance | `urgent_indicator` | `true` | Use the theme error role when compositor events provide urgency. Umbriel does not guarantee this field. |
| Interaction | `click_behavior` | `"cycle"` | Grouped apps always cycle windows. Minimize requires compositor support. |
| Interaction | `middle_click` | `"settings"` | Host defaults to widget settings. To use these actions, explicitly set this instance’s actions.middle = "none". |
| Interaction | `scroll_step` | `1` | Application items per wheel gesture in item mode. |
| Interaction | `auto_reveal_focused` | `true` | Reveal on focus changes and expansion. Manual wheel navigation remains usable until focus changes. |
| Advanced | `app_aliases` | `{}` | Map normalized unusual application IDs to desktop-entry IDs. Matching ignores case and a .desktop suffix. |
| Advanced | `refresh_fallback` | `60` | Retry interval if subscription startup fails. Umbriel/niri CLI streams reconnect after two seconds; socket bridges back off from 1 to 30 seconds. |
| Advanced | `diagnostic_logging` | `false` | Log subscription and action errors. Window titles are not logged. |
| Advanced | `compositor_compatibility` | `"auto"` | Auto-detect Umbriel, niri, Hyprland, Mango or Sway; explicit selection validates the detected compositor. |

## IPC

```sh
noctalia msg plugin omardardery/smart-taskbar:taskbar focused expand
noctalia msg plugin omardardery/smart-taskbar:taskbar focused collapse
noctalia msg plugin omardardery/smart-taskbar:taskbar focused next
noctalia msg plugin omardardery/smart-taskbar:taskbar focused previous
```

Use `all`, a connector, or `connector:bar-name` instead of `focused` for other instances. Always-expanded mode ignores collapse; empty states stay hidden in every mode.

## Previews

Offline fixture renders use the actual Luau UI trees with an illustrative palette and symbolic icons. They do not verify native rendering, device input, or scaling.

![Collapsed offline preview](screenshots/collapsed.png)
![Expanded offline preview](screenshots/expanded.png)
![Grouped numeric badge offline preview](screenshots/grouped.png)
![Overflow offline preview](screenshots/overflow.png)

## Notes

Umbriel window/workspace snapshots normalize stable IDs, identity, output, focus and minimized state. Focus, close and minimize use `noctalia.umbriel.action`; restore uses focus. Scratchpads without a workspace are excluded. Urgency appears only if supplied by the compositor.

niri uses native events on API 54+ or its JSON CLI event stream on API 52/53. Hyprland, Mango and Sway use one host-owned Python standard-library helper per widget, reading public local UNIX sockets. Hyprland and Sway reconcile snapshots after relevant events, coalescing bursts; Mango merges its two watched snapshot streams. No polling or query subprocesses run while idle. Mango multi-tag windows remain visible on any active matching tag and count once. Focus and close use validated argument-array CLI commands with a five-second timeout. Minimize is available only on Umbriel and Mango; focus restores supported minimized windows. No scratchpad workaround is used for other compositors.

Disconnection clears stale state and reconnects automatically. Subscription replay reuses the existing helper. Compatibility is protocol-tested, with live desktop acceptance pending; see the source repository's `docs/COMPATIBILITY.md`.
Application grouping uses exact normalized IDs without fuzzy-merging distinct applications. Missing IDs stay separate. Cached `noctalia.appIconPath` handles desktop-entry, StartupWMClass and fuzzy icon matching; a theme glyph replaces missing icons. Use `app_aliases` for unusual IDs. Settings are read-only from plugins, so pin lists are edited through the normal settings GUI. Native context menus are public only for panels; this single-widget plugin offers settings on right click.

The plugin makes **no network calls or filesystem writes**. Native Umbriel/niri subscriptions need no helper. API 52/53 starts one host-managed reconnecting shell/CLI stream. Hyprland/Mango/Sway start one Python helper, blocked on local socket events while idle. Noctalia owns process-group cleanup on reload/disable. Compatibility toggles pause delivery and replay cached snapshots without duplicating streams. Explicit pin launches and window actions also spawn processes; nothing starts per icon or animation frame. Snapshot framing stays below the host stream-line limit, and complete snapshots are applied atomically. Geometry-only updates do not rebuild the widget.

Animations run briefly at about 30 Hz while changing. No render loop runs while idle or hidden, and hover animation does not resolve icons repeatedly. Theme colors are host palette roles. Badges are paint-transformed over fixed icon cells using public API 52 controls.

Compilation, fixture tests, two shell-stream lifecycle tests and local socket protocol tests, and canonical manifest validation run automatically. Native desktop screenshots, multi-monitor/DPI acceptance, real gesture delivery, and resource measurements remain pending; see the source repository's `docs/TESTING.md`.
