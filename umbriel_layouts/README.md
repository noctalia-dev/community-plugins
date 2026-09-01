# Umbriel Layouts

A layout switcher for the [Umbriel](https://github.com/noctalia-dev/umbriel)
compositor. A bar capsule shows the focused workspace's layout, clicking it opens
a picker, and changing the layout raises an OSD — however the change was made.

Modelled on `ezequiel/mango_layouts`, which does the same job for MangoWC.

## Plugin

| Field | Value |
| --- | --- |
| ID | `soheil7799/umbriel_layouts` |
| Entries | Service: `poller`; bar widget: `btn`; panels: `panel_grid` (icon grid), `panel_list` (vertical list) |

## Requirements

Umbriel as the window manager, with `umbriel` on `PATH`: its own CLI both reports
the focused workspace's layout and applies a new one.

`socat` is also required, and carries the event subscription — umbriel exposes
`subscribe` on its unix socket but has no CLI subcommand for it. Without `socat`
the plugin still works, falling back to interval polling at `fallback_poll_s`.

## Usage

Add the widget to your Noctalia bar in Settings. Click it to open the picker and
change the focused workspace's layout.

The picker can also be opened directly. Each entry draws its own shape, so either
works whatever **Vertical List Mode** is set to -- that setting only decides which
one the capsule opens:

```sh
noctalia msg panel-toggle soheil7799/umbriel_layouts:panel_grid
noctalia msg panel-toggle soheil7799/umbriel_layouts:panel_list
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `list_mode` | `bool` | `false` | Show layouts as a vertical list instead of a grid. Also selects which panel entry the capsule opens. |
| `fallback_poll_s` | `int` | `10` | Safety net only, in seconds (2–120). Changes normally arrive from umbriel's `windows` event, not on this interval. |
| `notifications` | `bool` | `true` | Notify when a workspace's layout changes. Switching workspaces or moving between monitors does not count. |
| `show_scrolling` | `bool` | `true` | Offer the Scrolling layout. |
| `show_dwindle` | `bool` | `true` | Offer the Dwindle layout. |
| `show_master` | `bool` | `true` | Offer the Master layout. |

### Per-widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_glyph` | `bool` | `true` | Show the layout icon. |
| `show_text` | `bool` | `false` | Show the layout name beside the icon. |
| `custom_color` | `string` | `""` | Override icon/text colour, e.g. `primary`. |

## Layouts

Umbriel supports these three at present, and the plugin offers exactly those.
As umbriel gains more, they will be added here.

The names below are the window manager's own, used verbatim both when reading a
workspace's `.layout` and when writing `workspace-set-layout:<name>`.

- `scrolling`
- `dwindle`
- `master`

## Licence

MIT
