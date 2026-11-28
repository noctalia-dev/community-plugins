# LAMZU Mouse Battery

Shows the battery level and charging state of a LAMZU-protocol wireless mouse in the bar. These mice
(LAMZU, Attack Shark R5 Ultra, and other mice on LAMZU's USB vendor ids) have no Linux kernel battery driver,
so the level never shows up in UPower; this plugin asks the mouse directly.

## Plugin

| Field | Value |
| --- | --- |
| ID | `windowsoffender/lamzu-mouse-battery` |
| Entries | Bar widget: `bar` |

## Requirements

- `python3` on `PATH` (standard library only). It runs the bundled `lamzu-battery.py` helper.
- A LAMZU-protocol mouse: any device on USB vendor id `373e` or `37b0`, through its 2.4G receiver or its cable.
  Confirmed on the Attack Shark R5 Ultra (`373e:0047`).
- Read/write access to the mouse's `/dev/hidraw*` node. Most distros don't grant that by default, so install the
  bundled udev rule, which grants access to the user logged in at the seat:

```sh
sudo cp 70-lamzu-battery.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
```

## Usage

Add the widget in Settings, or put it in a bar list in `config.toml`:

```toml
[widget.mouse_battery]
type = "windowsoffender/lamzu-mouse-battery:bar"

[bar.default]
end = ["mouse_battery", "tray"]
```

The widget shows a mouse glyph and the battery percentage. The glyph turns into a bolt while charging and takes the
low battery color at or below the threshold. Hover for the device name, charging state and when the level was last
read. Left-click to query again right away.

When the mouse is asleep or out of range, the receiver can't reach it; the widget keeps the last level it saw this
session and the tooltip says the mouse is asleep. If no LAMZU-protocol device is plugged in it shows a crossed-out
mouse, or hides itself if you enable that setting.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_seconds` | `int` | `60` | Seconds between battery queries (10-600). |
| `low_threshold` | `int` | `20` | Percentage at or below which the low battery color is used. |
| `show_percent` | `bool` | `true` | Show the percentage next to the glyph. Off leaves just the glyph; the tooltip still has the number. |
| `hide_when_missing` | `bool` | `false` | Hide the widget when no LAMZU-protocol device is plugged in. |
| `normal_color` | `color` | `secondary` | Glyph color at a normal battery level. |
| `charging_color` | `color` | `primary` | Glyph color while charging. |
| `low_color` | `color` | `error` | Glyph color at or below `low_threshold`, and for errors. |

## Notes

- Every poll spawns `python3 -B -I lamzu-battery.py`, which exits after one query. No daemon, no network access, and
  nothing is written to disk.
- The helper finds the mouse's vendor interface from its HID report descriptor (an unnumbered 64-byte feature
  report), then sends one feature report: `00 00 02 02 00 83`, zero-padded to 64 bytes. The reply carries the
  charging flag at byte 6 and the percentage at byte 7 (counting from the first data byte). This query only reads
  the battery and changes no mouse settings. A sleeping mouse takes a few hundred milliseconds to answer, so the
  helper waits up to 1.5 seconds.
- Run the helper by hand to debug: `python3 lamzu-battery.py` prints the JSON the widget reads, including a
  `no_permission` status when the udev rule is missing.
- Protocol credit: [Wireless-Device-Battery-Monitor](https://github.com/raeAllen17/Wireless-Device-Battery-Monitor)
  (`src/drivers/lamzu.cpp`).
