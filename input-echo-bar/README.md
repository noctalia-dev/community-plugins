# Input Echo Bar

Input Echo Bar briefly displays the latest keyboard or mouse combination directly in the Noctalia bar, then disappears after a configurable delay. It is a compact bar indicator, not a floating HUD or input-history viewer.

## Plugin

| Field | Value |
| --- | --- |
| ID | `baizhu/input-echo-bar` |
| Entries | Bar widget: `bar` |

## Requirements

- Install `showmethekey-cli` and `python3` on `PATH`.
- Grant the current user read access to the relevant `/dev/input/event*` devices, such as through the distribution's input-device group or Show Me The Key setup. This access is required because the input stream is global rather than compositor-scoped.

## Usage

Add the `baizhu/input-echo-bar:bar` widget to the Noctalia bar. The widget stays hidden until an event arrives, briefly shows the latest key, modifier combination, mouse button, or wheel direction, and hides again after the configured timeout. Left and right variants of Ctrl, Shift, Alt, and Super remain distinct. Right-click the widget while it is visible to open its plugin settings.

The plugin intentionally provides no panel, floating HUD, event history, or persistent idle icon.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `timeout_ms` | `int` | `2000` | Time in milliseconds before the bar widget hides after the latest event; accepts `250`–`10000`. |
| `show_mouse_events` | `bool` | `true` | Include mouse buttons and vertical or horizontal wheel directions. Keyboard events are always shown. |

## Privacy and process notes

- The widget starts `showmethekey-cli | python3 input_echo.py` through Noctalia's `runStream`. This globally reads keyboard and, when enabled, mouse input events, so sensitive keystrokes can appear in the bar.
- The packaged Python helper formats combinations, reads wheel-capable `/dev/input/event*` nodes read-only when mouse events are enabled, and emits a clear event after inactivity.
- The plugin does not use the network and does not write files. It does not keep an input history.
- No standalone daemon or PID file is created. Noctalia owns the stream process group and cleans up the CLI and helper when the widget exits or reloads.

## Attribution

This is the Noctalia V5 implementation of the author's previous V4 CustomButton setup. It is not a port of a legacy `show-keys` plugin. The external [Show Me The Key](https://github.com/AlynxZhou/showmethekey) project is used only as a runtime dependency and is not relicensed by this plugin.

## License

Input Echo Bar is licensed under the MIT License. See `LICENSE`.
