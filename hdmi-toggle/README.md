# Monitor Manager

A bar widget and panel for listing and toggling connected monitors on and off. Click the bar widget to open a panel with each monitor listed and a toggle button.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rael2pac/hdmi-toggle` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Usage

The bar widget shows a monitor icon. Click it to open the panel listing all connected monitors with toggle buttons to turn them on or off.

```sh
noctalia msg panel-toggle rael2pac/hdmi-toggle:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refreshInterval` | `int` | `10` | Seconds between monitor status polls (min 5, max 60). |

## Notes

- Uses `wlr-randr` or `niri msg` to list and control monitors.
- Works on Wayland compositors that support output management (Niri, Sway, Hyprland).
