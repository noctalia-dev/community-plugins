# Umbriel Scratchpad

Shows Umbriel's scratchpads in the bar, drawn like the native taskbar's workspace groups: one capsule per scratchpad
with its name badge and an icon for each window inside it. The native taskbar groups windows by workspace, and
scratchpad windows belong to no workspace, so this widget is the only place they appear in the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `samxu29/umbriel-scratchpad` |
| Entries | Bar widget: `bar`; service: `service` |

## Requirements

- An Umbriel session, with `umbriel` on `PATH`. On any other compositor the widget hides itself.
- Umbriel scratchpads, for example a `scratchpad-toggle:<name>` keybind and a `window-move-to-scratchpad:<name>`
  binding to fill it.

## Usage

Add the **Umbriel Scratchpad** widget to a bar from Settings → Bar. It fits naturally next to the native
**Taskbar** widget.

- **Click a scratchpad's badge** to show or hide that scratchpad (`scratchpad-toggle:<name>`).
- **Click a window's icon** to reveal and focus that window. Clicking the icon of the window that already has focus
  hides its scratchpad again.
- With **Single icon per app**, an app's windows share one icon with a count badge, and clicking it cycles through
  them.
- In **Count** or **Dots** mode, clicking the group toggles the scratchpad.

The badge uses the shown color while the scratchpad is visible and the hidden color while it is not. Icons of a
hidden scratchpad are dimmed. A dot under an icon marks the focused window. Icons keep the order in which their
windows entered the scratchpad, so they do not jump around as focus moves.

## Settings

The settings follow the native taskbar's order: windows, then grouping, then labels. Opacities range from `0.1` to
`1.0`.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_all_monitors` | `bool` | `true` | Include scratchpad windows from every monitor. When off, a bar lists only windows on its own output. Keep it on with several monitors: Umbriel reports a hidden scratchpad window on the output where it was last shown, so with it off the icons move between bars as scratchpads are toggled on different monitors. |
| `active_indicator` | `bool` | `true` | Show a small dot under the focused window's icon. |
| `indicator_color` | `color` | `primary` | Color of that dot. |
| `active_opacity` | `double` | `1.0` | Opacity of the focused window's icon. |
| `dim_unfocused` | `bool` | `true` | While a scratchpad window has focus, dim the other icons in its scratchpad. |
| `unfocused_opacity` | `double` | `0.5` | Opacity of those other icons. |
| `hidden_opacity` | `double` | `0.5` | Opacity of icons while their scratchpad is hidden. |
| `icon_size` | `double` | `16` | App icon size, in pixels (10 to 32). |
| `only_shown` | `bool` | `false` | Leave out scratchpads that are currently hidden. |
| `group_by_scratchpad` | `bool` | `true` | Draw one capsule per scratchpad. When off, every scratchpad window appears in one flat row of icons without labels. |
| `hide_empty` | `bool` | `true` | Leave out known scratchpads that have no windows. |
| `known_scratchpads` | `string_list` | `[]` | Scratchpad names listed first, in this order. With `hide_empty` off, they also appear while empty. The compositor only reports scratchpads that hold windows, so this list is how an empty one can be shown. |
| `hidden_scratchpads` | `string_list` | `[]` | Scratchpad names left out unless that scratchpad is shown. |
| `group_content` | `select` | `icons` | What each group shows: `icons`, a window `count`, or `dots` (up to five, then `+N`). |
| `single_icon_per_app` | `bool` | `false` | Collapse windows of the same app into one icon with a count badge. |
| `group_capsule` | `bool` | `true` | Draw the border around each group. |
| `hide_when_empty` | `bool` | `true` | Take no bar space when there is nothing to show. |
| `show_label` | `bool` | `true` | Show the scratchpad name badge on each group. |
| `label_placement` | `select` | `corner` | `corner` pins the badge to the group's top-left corner, `edge` centers it against the left border, `inside` pads it inside the group. |
| `minimal_style` | `bool` | `false` | Show the name as colored text without the disc. |
| `highlight_focused_monitor_only` | `bool` | `false` | Use the shown color only when the scratchpad is shown on the monitor that has keyboard focus. |
| `shown_color` | `color` | `primary` | Badge and border color of a shown scratchpad. |
| `hidden_color` | `color` | `secondary` | Badge color of a hidden scratchpad that holds windows. |
| `empty_color` | `color` | `secondary` | Badge color of an empty known scratchpad. |
| `urgent_color` | `color` | `error` | Badge color, and icon outline (with `urgent_outline`), when a window in the scratchpad is urgent. Takes priority over the other colors. |
| `urgent_outline` | `bool` | `false` | Outline urgent windows' icons in the urgent color. Off by default because many apps request attention right after launching. |

## Notes

- The `service` entry keeps one `umbriel subscribe windows` process running and shares its window list with every
  bar, so several bars on several monitors cost one subscription. It restarts the stream if it finds it has exited.
- Clicks run `umbriel msg` with one of `scratchpad-toggle:<name>` or `window-focus:<window-id>`. The plugin starts no
  other processes, makes no network requests, and writes no files.
- Plugin UI has no overlay layer, so the corner badge sits just inside the group's top-left corner rather than
  straddling the border as the native taskbar's does, and the `edge` placement is flush with the left border.
