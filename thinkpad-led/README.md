# ThinkPad Logo LED

A simple Noctalia bar widget to toggle the ThinkPad lid logo LED on and off.

## Plugin

| Property | Value |
| --- | --- |
| **ID** | `zeti1223/thinkpad-led` |
| **Widget** | `led` |
| **Version** | `1.1.0` |
| **Author** | zeti1223 |
| **License** | MIT |

## Usage

Add the `led` widget to your Noctalia bar layout. Clicking the widget toggles the ThinkPad logo LED state.

* **Left Click**: Toggle LED (ON / OFF).

## Requirements

* `sh`

## Notes

* **Hardware & Permissions**: This plugin writes directly to `/sys/class/leds/tpacpi::lid_logo_dot/brightness`. Ensure your user account has write permissions to this path (for example, via a `udev` rule), otherwise command execution will fail.
