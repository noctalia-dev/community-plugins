# Mangowm Status

Shows the current Mangowm tiling layout and keymode on your bar. Click to open a picker and switch layouts instantly.

![Thumbnail](thumbnail.webp)

## Plugin

| Field | Value |
| --- | --- |
| ID | `x0d7x/mangowm-status` |
| Entries | Bar widget: `status`; panel: `layout-picker` |

## Requirements

- Noctalia v5
- [`mmsg`](https://github.com/mangowm/mango) — Mangowm's IPC CLI tool (must be on `PATH`)

## Usage

### Bar widget

Add the **Mangowm Status** widget from the Add-widget picker in your bar settings, or configure it by hand with:

```toml
[widget.mangowm-status]
type = "x0d7x/mangowm-status:status"
```

The widget displays the current layout's icon and letter code. When the active keymode is not `default`, the keymode name is shown beside the layout code.

- **Left-click** the widget → opens the **Layout Picker** panel. Click any layout to switch immediately.
- **Horizontal scroll** over the widget → cycles through the core layouts (T → S → G → …).

### Layout picker panel

Open with:

```sh
noctalia msg panel-toggle x0d7x/mangowm-status:layout-picker
```

A scrollable list of all 14 supported layouts. The current layout is highlighted. Click any other layout to switch — the panel closes automatically.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Hide on default | `bool` | `false` | Hide the widget when keymode is `default` |
| Show text | `bool` | `true` | Show the keymode name beside the layout glyph |
| Notify on change | `bool` | `true` | Show a notification when the keymode changes |

## IPC

Control the widget from the terminal:

```sh
# Refresh layout data
noctalia msg plugin x0d7x/mangowm-status:status focused refresh

# Get current status (logged as JSON)
noctalia msg plugin x0d7x/mangowm-status:status focused get-status

# Set layout by code (T, S, G, M, K, CT, RT, DW, F, VS, VT, VG, VK, VF)
noctalia msg plugin x0d7x/mangowm-status:status focused set-layout S
```

## Layout Codes

| Code | Layout | Icon |
|------|--------|------|
| T | Tile | columns |
| S | Scroller | menu |
| G | Grid | dashboard |
| M | Monocle | window |
| K | Deck | cards |
| CT | Center Tile | layout |
| RT | Right Tile | columns |
| DW | Dwindle | columns |
| F | Fair | layout |
| VS | Vertical Scroller | menu |
| VT | Vertical Tile | columns |
| VG | Vertical Grid | dashboard |
| VK | Vertical Deck | cards |
| VF | Vertical Fair | layout |

## Notes

- This plugin spawns `mmsg` subprocesses to query and change the compositor state. `mmsg` must be installed and on `PATH`.
- Layout changes use `mmsg dispatch setlayout,<name>`.
- The widget keeps two long-running `mmsg watch` streams (keymode + all-tags) for live updates, with a 1-second polling fallback.
- The panel entry fetches tag data on open and does not keep a persistent connection.

## License

MIT
