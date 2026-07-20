# Hypr Screen Mirror

This plugin allows you to easily toggle screen mirroring in Hyprland.

## Plugin

| Field   | Value                                                    |
| ------- | -------------------------------------------------------- |
| ID      | `profidev/hypr-screen-mirror`                            |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

- `hyprctl` available on `PATH` (used to control Hyprland and query monitor information)
- `socat` available on `PATH` (used to watch Hyprland socket for monitor events)

## Usage

1. Add the widget to your bar
2. Open the panel and select your source and target monitors for mirroring
3. Click on "Mirror" to start mirroring, or "Stop" to stop mirroring

```sh
noctalia msg panel-toggle profidev/hypr-screen-mirror:panel
```

## Settings

| Setting | Type    | Default        | Description                     |
| ------- | ------- | -------------- | ------------------------------- |
| `glyph` | `glyph` | `screen-share` | The glyph to display in the bar |

## Notes

- Only supports Hyprland 0.55.0 or newer, as it relies on the `hyprctl eval` command to execute lua code for mirroring.
