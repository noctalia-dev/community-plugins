# Shelly

Shelly is a plugin that uses the [Shelly Arch Package Manager](https://github.com/Seafoam-Labs/Shelly-ALPM) to display package update information in a bar widget.

## Plugin

| Field   | Value                                   |
| ------- | --------------------------------------- |
| ID      | `joshuaslate/shelly`                    |
| Entries | Service: `poller`; bar widget: `shelly` |

## Requirements

Install the Shelly Arch Package Manager from the [AUR](https://aur.archlinux.org/packages/shelly).

Test that it works by running `shelly check-updates` in a terminal. If it returns a list of packages, then it is working correctly.

## Settings

| Setting                | Type     | Default      | Description                                                                                        |
| ---------------------- | -------- | ------------ | -------------------------------------------------------------------------------------------------- |
| `interval`             | `int`    | `300`        | The interval (in seconds) between update checks                                                    |
| `notify`               | `bool`   | `false`      | Whether or not you want to receive notifications when there are new package updates available      |
| `color`                | `color`  | `on_surface` | The text color for the bar widget                                                                  |
| `glyph_color`          | `color`  | `on_surface` | The color of the glyph on the bar widget                                                           |
| `glyph`                | `glyph`  | `package`    | Bar widget icon.                                                                                   |
| `click_action`         | `select` | `open_gui`   | The action to perform when the bar widget is clicked. Options: `open_gui`, `open_updater`, `none`. |
| `hide_when_up_to_date` | `bool`   | `false`      | Whether or not to hide the bar widget when there are no package updates available                  |
