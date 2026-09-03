# Shelly

Shelly is a plugin that uses the [Shelly Arch Package Manager](https://github.com/Seafoam-Labs/Shelly-ALPM) to display package update information in a bar widget.

## Plugin

| Field   | Value                                          |
| ------- | ---------------------------------------------- |
| ID      | `joshuaslate/shelly`                           |
| Entries | Service: `update_poller`; bar widget: `shelly` |

## Requirements

Install the Shelly Arch Package Manager (>= v3.0.0) from the [AUR](https://aur.archlinux.org/packages/shelly). The `shelly`
command must be available on `PATH`.

Verify the correct version is installed by running `shelly --version` in a terminal. It should return a version number >= 3.0.0.

Test that it works by running `shelly list updates all` in a terminal. If it returns a list of packages, then it is working correctly.

## Usage

Add the `shelly` widget from Noctalia's widget picker. It periodically checks
for available Arch package updates and shows their count and names in the bar
tooltip. Click behavior is configurable: open Shelly's graphical interface,
run `shelly upgrade all` in a terminal, or do nothing.

The `update_poller` service owns the periodic checks and can notify you when
new updates become available.

## Settings

| Setting                | Type     | Default           | Description                                                                                              |
| ---------------------- | -------- | ----------------- | -------------------------------------------------------------------------------------------------------- |
| `interval`             | `int`    | `300`             | The interval (in seconds) between update checks                                                          |
| `notify`               | `bool`   | `false`           | Whether or not you want to receive notifications when there are new package updates available            |
| `color`                | `color`  | `on_surface`      | The text color for the bar widget                                                                        |
| `bar_label`            | `select` | `count_and_label` | The label to display in the bar widget when there are updates. Options: `count_only`, `count_and_label`. |
| `bar_font_size`        | `int`    | `14`              | The size of the font displayed in the bar widget                                                         |
| `glyph_color`          | `color`  | `on_surface`      | The color of the glyph on the bar widget                                                                 |
| `glyph`                | `glyph`  | `package`         | Bar widget icon                                                                                          |
| `glyph_size`           | `int`    | `14`              | The size of the glyph in the bar widget                                                                  |
| `click_action`         | `select` | `open_gui`        | The action to perform when the bar widget is clicked. Options: `open_gui`, `open_updater`, `none`.       |
| `hide_when_up_to_date` | `bool`   | `false`           | Whether or not to hide the bar widget when there are no package updates available                        |
