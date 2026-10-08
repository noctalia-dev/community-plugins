# Keyboard State

Displays the current state of the Caps Lock, Num Lock, and Scroll Lock keys in the Noctalia bar.
The plugin monitors keyboard LED events and keeps the displayed states synchronized with the keyboard. Individual lock keys can be shown or hidden, inactive indicators can be hidden, and the glyph, color, and spacing can be customized.

## Plugin

| Field   | Value                                            |
| ------- | ------------------------------------------------ |
| ID      | `ismay/keyboard-state`                           |
| Entries | Bar widget: `keyboard-state`; service: `service` |

## Usage

Add the `keyboard-state` widget to your Noctalia bar.
Configure the input device path to monitor in the plugin settings.
Use `evtest` in the terminal to find the correct device path.
Use stable paths from `/dev/input/by-id/` or `/dev/input/by-path/` when possible, because `/dev/input/eventN` names can change after device or kernel updates.
Then customize which lock keys are displayed and how they appear in the widget settings.

## Requirements

Requires permission to read the configured input device.
On many systems, this means adding your user to the `input` group and logging out and in again.
The configured input device must be an existing device under one of these paths:

- `/dev/input/event*`
- `/dev/input/by-id/*`
- `/dev/input/by-path/*`

Requires both `evsieve` and `evtest` to be available on `PATH`.

- `evsieve` monitors keyboard LED state changes.
- `evtest` queries the initial state of each lock key.

Although `evtest` can also monitor LED state changes, doing so can modify the keyboard's LED state.
`evsieve` is therefore used for continuous monitoring.

## Settings

| Setting             | Type     | Default                     | Description                                                       |
| ------------------- | -------- | --------------------------- | ----------------------------------------------------------------- |
| `input_device`      | `file`   | `""`                        | Path to the input device to monitor for keyboard lock key events. |
| `hide_inactive`     | `bool`   | `false`                     | Hide lock key indicators when they are inactive.                  |
| `active_color`      | `color`  | `"primary"`                 | Color used when a lock key is active.                             |
| `inactive_color`    | `color`  | `"on_surface"`              | Color used when a lock key is inactive.                           |
| `icon_spacing`      | `int`    | `4`                         | Spacing between lock key icons in pixels.                         |
| `show_caps_lock`    | `bool`   | `true`                      | Show the Caps Lock indicator.                                     |
| `caps_lock_glyph`   | `glyph`  | `"square-letter-a-filled"`  | Glyph displayed for Caps Lock.                                    |
| `show_num_lock`     | `bool`   | `true`                      | Show the Num Lock indicator.                                      |
| `num_lock_glyph`    | `glyph`  | `"square-number-1-filled"`  | Glyph displayed for Num Lock.                                     |
| `show_scroll_lock`  | `bool`   | `true`                      | Show the Scroll Lock indicator.                                   |
| `scroll_lock_glyph` | `glyph`  | `"square-arrow-down-filled"`| Glyph displayed for Scroll Lock.                                  |

## Notes

- The widget is hidden when the service encounters an error.
- The widget is also hidden when all lock key indicators are disabled or hidden due to their current state.
- Errors are logged to the Noctalia log.
