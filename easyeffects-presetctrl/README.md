# EasyEffects PresetCTRL

This plugin allows you to control the active easy effects preset from a bar
widget.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nuddel69/easyeffects-presetctrl` |
| Entries | Bar widget: `preset_picker`; panel: `picker`|

## Requirements

Install `easyeffects` on `PATH`.

## Usage

Ensure easy effects launched at least once during the current boot. Configure
your effects in the GUI and save them as presets. The widget interfaces with the
CLI and will present you with all available outputs.

The panel can also be accessed using the IPC command:

```sh
noctalia msg panel-toggle nuddel69/easyeffects-presetctrl:picker
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `music-cog` | Icon to be displayed in widget. |
| `label` | `string` | `Audio Preset` | Widget label |
| `show-glyph` | `bool` | `true` | Whether or not to show glyph in the widget |
| `show-label` | `bool` | `true` | Whether or not to show label in the widget |

## TODO

- Enable/Disable
- Input presets
  SystemD service to start easyeffects in the background
