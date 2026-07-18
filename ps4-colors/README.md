# PS4 Colors

Set the LED lightbar colour on a connected PlayStation 4 DualShock 4 controller
from a Noctalia bar button and a color panel. Click the bar icon to open the
panel, pick a color (native picker, hex field, or preset), and hit Apply — every
connected DS4 (USB and Bluetooth) updates at once.

## Plugin

| Field | Value |
| --- | --- |
| ID | `Hy4ri/ps4-colors` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

Install [`ps4-colors`](https://github.com/Hy4ri/ps4-colors) on `PATH` (build with
`make` and `sudo make install`). The plugin depends on the `ps4-colors` binary to
write the DualShock 4 HID output report.

On headless systems without `uaccess`, add a udev rule for the Sony DS4
(`054c:05c4`, `054c:09cc`, `054c:0ba0`) and join the `plugdev` group, as
documented in the ps4-colors README.

## Usage

Click the **PS4 Colors** bar button to open the panel:

```sh
noctalia msg panel-toggle Hy4ri/ps4-colors:panel
```

In the panel: choose a color with the native picker, type a hex value
(`RRGGBB` / `#RRGGBB` / `0xRRGGBB`), or tap a preset, then press **Apply**.
The last applied color is remembered across restarts.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | `glyph` | `controller` | Icon shown on the bar button. |

## IPC

```sh
noctalia msg plugin Hy4ri/ps4-colors:service all apply <hex>
```

## Notes

- Shells out to `ps4-colors <hex>`, which writes `/dev/hidrawN` directly (no
  libraries). Requires read/write access to the DS4 hidraw node.
- The last chosen color is persisted to the plugin data directory
  (`last.json`) and restored on next open.
- No network access. Only the locally detected DualShock 4 controllers are
  touched.
