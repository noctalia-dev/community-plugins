# ASUS UM5606 Fan State

ASUS UM5606 Fan State shows and changes the firmware fan profile on the
ZenBook S 16 UM5606 and compatible laptops from the bar or Control Center.

## Plugin

| Field | Value |
| --- | --- |
| ID | `thatonecalculator/um5606_fan_state` |
| Entries | Bar widget: `fan_state`; shortcut: `toggle`; service: `service` |

## Requirements

Install the `fan_state` command from
[asus-5606-fan-state](https://github.com/ThatOneCalculator/asus-5606-fan-state)
and verify that `fan_state get --int` works for your hardware.

## Usage

Add the `fan_state` widget to a bar, or add the `toggle` shortcut under
Settings → Control Center shortcuts. Click either entry to cycle through
Standard, Quiet, High-Performance, and Full fan profiles.

The headless `service` polls the current profile and owns all calls to the
hardware helper. Both user-facing entries become disabled or show
**Unavailable** when the helper cannot report a valid state.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_label` | `bool` | `false` | Shows the current profile name beside the bar glyph. |
| `poll_interval` | `int` | `2000` | Hardware polling interval in milliseconds, from 250 to 60000. |

## Notes

This plugin changes a hardware fan-control setting by running `fan_state set`.
Only use it on hardware supported by the helper project.
