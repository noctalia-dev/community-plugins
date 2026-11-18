# Mango Layouts

A clean, minimalist layout switcher plugin for MangoWC. It provides a bar widget and a fast popup panel to switch workspace layouts on the fly, directly from your desktop.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ezequiel/mango_layouts` |
| Entries | Bar widget: `btn`; panel: `panel` |

## Requirements

Install `mmsg` (MangoWC CLI) on `PATH`.
Requires MangoWC as the compositor, with support for `mmsg get layouts`.

## Usage

Add the widget to your Noctalia bar in Settings. Click the widget to open the layout switcher panel and change the current workspace layout. 

Alternatively, toggle the panel directly via command line or keybinding:

```sh
noctalia msg panel-toggle ezequiel/mango_layouts:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `list_mode` | `bool` | `false` | Display layouts in a vertical list instead of a grid. |
| `show_tile` | `bool` | `true` | Show Tile layout. |
| `show_scroller` | `bool` | `true` | Show Scroller layout. |
| `show_monocle` | `bool` | `true` | Show Monocle layout. |
| `show_grid` | `bool` | `true` | Show Grid layout. |
| `show_fair` | `bool` | `true` | Show Fair layout. |
| `show_deck` | `bool` | `true` | Show Deck layout. |
| `show_dwindle` | `bool` | `true` | Show Dwindle layout. |
| `show_center_tile` | `bool` | `true` | Show Center Tile layout. |
| `show_vertical_tile` | `bool` | `true` | Show Vertical Tile layout. |
| `show_right_tile` | `bool` | `true` | Show Right Tile layout. |
| `show_vertical_scroller` | `bool` | `true` | Show Vertical Scroller layout. |
| `show_vertical_grid` | `bool` | `true` | Show Vertical Grid layout. |
| `show_vertical_deck` | `bool` | `true` | Show Vertical Deck layout. |
| `show_vertical_fair` | `bool` | `true` | Show Vertical Fair layout. |

Widget Specific Settings:
| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_glyph` | `bool` | `true` | Show the widget icon. |
| `show_text` | `bool` | `false` | Show the active layout name as text. |
| `custom_color` | `string` | `""` | Custom icon/text color (e.g. primary, on_surface). |
| `update_interval` | `int` | `1000` | Time it takes to update the icon/label (ms) |

## Notes

The plugin discovers available layouts, their symbols, and their order directly from `mmsg get layouts`. This includes Floating and any future layouts exposed by Mango. Existing visibility settings still apply; newly discovered layouts are visible by default and use a generic icon and readable name when no presentation metadata exists. The list represents Mango's supported layouts, not the `circle_layout` cycling configuration.

The panel refreshes the list whenever it opens. The widget caches discovery for 30 seconds, with retries at most once every 5 seconds after failures or an unknown active symbol. Active monitor state is still polled at the configured update interval. Temporary discovery failures retain the last successful list; an initial failure shows an unavailable state rather than a hardcoded list.

The plugin uses `mmsg` to read the active monitor state and apply selected layouts by name. Make sure you don't use this plugin on compositors other than MangoWC. No Mango configuration parsing or `jq` dependency is required.

## Development

Run the discovery regression tests with the Luau CLI:

```sh
luau mango_layouts/layouts.test.luau
```

To also exercise the widget and panel in a mocked Noctalia host, run from the repository root with `jq` and the Luau CLI installed (neither is an additional plugin runtime dependency):

```sh
printf 'require("./mango_layouts/layouts.test")({widget = %s, panel = %s})\n' \
	"$(jq -Rs . mango_layouts/widget.luau)" \
	"$(jq -Rs . mango_layouts/panel.luau)" | luau
```
