# Color Picker

A screen color picker for Noctalia v5, built on top of [hyprpicker](https://github.com/hyprwm/hyprpicker).

## Plugin

| Field   | Value |
| ------- | ----- |
| ID      | `oldirtty/color_picker` |
| Entries | Service: `service`; bar widget: `widget`; panel: `panel` |

## Requirements

Install `hyprpicker`

- [hyprpicker](https://github.com/hyprwm/hyprpicker)

## Installation

The headless `service` triggers `hyprpicker` with arguments set in the plugin's settings.

Widget controls:

| Action      | Behavior |
| ----------- | -------- |
| Left click  | Open plugin's panel. |
| Right click | Sample a color directly, without opening the panel. |

Panel controls:

| Action      | Behavior |
| ----------- | -------- |
| Click bigger swatch | Open color picker dialog. |

## Usage

- **Left-click** the bar widget to open the panel.
- **Right-click** the bar widget to sample a color directly, without opening the panel.
- Inside the panel, click any recent color swatch to select it, or edit the HEX/RGB/HSL fields directly or click the bigger swatch to open color picker dialog.
- Colors picked during a panel session are added to history when the panel closes.

## Settings

| setting                      | type     | default     | description |
| ---------------------------- | -------- | ----------- | ----------- |
| `hyprpicker-format`          | `select` | `"hex"`     | Default color format to copy to clipboard (`hex` or `rgb`). |
| `hyprpicker-lowercase`       | `bool`   | `false`     | Outputs the hexcode in lowercase. |
| `swatch-radius`              | `int`    | `8`         | Corner radius of the history swatches and current-color preview. |
| `hyprpicker-no-zoom`         | `bool`   | `false`     | Turns off the magnifying zoom lens while picking. |
| `hyprpicker-scale`           | `int`    | `10`        | Zoom lens magnification, from `1` to `10`. |
| `hyprpicker-radius`          | `int`    | `100`       | Zoom lens circle radius in pixels, from `1` to `1000`. |
| `hyprpicker-disable-preview` | `bool`   | `false`     | Turns off the live color preview while picking. |
| `hyprpicker-cursor`          | `bool`   | `false`     | Includes the cursor in the frozen screen preview. |
| `glyph`                      | `glyph`  | `"palette"` | Glyph |

## IPC

Runs `hyprpicker` with the arguments given in plugin's settings.

```bash
noctalia msg panel-toggle oldirtty/color_picker:panel

# Sample a color without opening the panel
noctalia msg plugin oldirtty/color_picker:service all pick
```

## Notes

- There is a known behavior where invoking `hyprpicker` through the plugin's background service imposes a timeout. The picker will close prematurely if a color is not selected within a certain timeframe, rather than staying open indefinitely waiting for a click.
- There is a slight delay in the current color swatch updating at open when opening the panel. This is a known state synchronization and UI mounting timing issue within the declarative UI cycle, and I haven't found a proper solution for it yet.
