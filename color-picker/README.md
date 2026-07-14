# Color Picker

A screen color picker for Noctalia v5, built on top of [hyprpicker](https://github.com/hyprwm/hyprpicker).

Right-click the bar widget to sample a color from anywhere on screen, or left-click to open the panel: edit the color as HEX, RGB, or HSL, adjust opacity, and browse your recent color history.

## Dependencies

- [hyprpicker](https://github.com/hyprwm/hyprpicker)

```bash
# Arch
sudo pacman -S hyprpicker

# From source
git clone https://github.com/hyprwm/hyprpicker
cd hyprpicker
make && sudo make install
```

## Installation

Enable **Color Picker** from Settings → Plugins in Noctalia. No extra source needed — it ships from the community catalog.

Add the bar widget from Settings → Bar → Add Widget.

## Usage

- **Left-click** the bar widget to open the panel.
- **Right-click** the bar widget to sample a color directly, without opening the panel.
- Inside the panel, click any recent color swatch to select it, or edit the HEX/RGB/HSL fields directly.
- Colors picked during a panel session are added to history when the panel closes.

### IPC

```bash
# Toggle the panel
noctalia msg panel-toggle oldirtty/color-picker:panel

# Sample a color without opening the panel
noctalia msg plugin oldirtty/color-picker:panel all pick
```

Bind either command to a compositor keybind for quick access.

## Settings

Available under Settings → Plugins → Color Picker:

| Setting | Description |
| --- | --- |
| Swatches Corner Roundness | Corner radius of the history swatches and current-color preview. |
| Glyph | Icon shown on the bar widget. |

## TODO

- Native color selector (canvas + hue slider), pending upstream plugin API support for the built-in color picker dialog.
- Configurable default colorspace for display and copy (HEX/RGB/HSL).