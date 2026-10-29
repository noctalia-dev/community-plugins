# Keychron M3 Battery

Shows the battery level of a Keychron M3 mini (4K) in the bar. The plugin asks
the mouse directly through its Keychron 4K Link receiver, so it needs neither a
kernel driver nor UPower, and it warns you with a notification before the
battery runs out.

## Plugin

| Field | Value |
| --- | --- |
| ID | `blanchedeadwood/keychron-m3-battery` |
| Entries | Bar widget: `battery` |

## Requirements

- `python3` on `PATH`. It runs the bundled `keychron-query.py`, which talks to
  the receiver.
- A Keychron M3 mini (4K) on the Keychron 4K Link receiver (USB id
  `3434:d038`). Other Keychron 4K/8K mice that use the same protocol may work
  but are untested.
- Read/write access to the receiver's hidraw device for the logged-in user:

  ```sh
  echo 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3434", MODE="0660", TAG+="uaccess"' \
    | sudo tee /etc/udev/rules.d/70-keychron-hidraw.rules
  sudo udevadm control --reload
  # then re-plug the receiver
  ```

  Without this rule the widget shows a red warning glyph whose tooltip points
  at the missing rule.

## Usage

Add the **Keychron M3 Battery** widget (`blanchedeadwood/keychron-m3-battery:battery`)
to a bar. It shows the mouse glyph and the battery percentage; hover it for
the charging state and the receiver's name and firmware. Left click re-reads
the battery immediately.

- The entry turns red at or below the low threshold, and a notification is
  sent once. It is re-armed only after the mouse has been charged.
- The mouse sleeps after a few minutes and then stops answering. The widget
  keeps showing the last reading, dimmed, with "last seen 5 min ago" in the
  tooltip, until `keep_last` minutes have passed. The reading also survives a
  shell restart.
- While charging or low, the mouse is asked four times as often (at least
  every 10 seconds), so "full" and "low" show up quickly.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `poll_interval` | `int` | `60` | Seconds between queries (10–900). Divided by four while charging or low. |
| `low_threshold` | `int` | `20` | Percentage (5–50) at or below which the entry turns red and the low notification fires. |
| `keep_last` | `int` | `60` | Minutes (0–1440) to keep showing the last reading while the mouse sleeps. `0` turns this off. |
| `hide_when_unavailable` | `bool` | `true` | Hide the widget once no current or remembered reading is left (mouse off for long, receiver unplugged). |
| `notify_low` | `bool` | `true` | Send a notification once when the battery reaches the low threshold. |
| `notify_full` | `bool` | `false` | Send a notification once when the mouse is fully charged. |
| `battery_glyph` | `bool` | `false` | Show a battery glyph with the fill level instead of the mouse glyph. |
| `icon_only` | `bool` | `false` | Show only the battery glyph, without the percentage. The tooltip keeps the details. |

## IPC

Re-read the battery right away:

```sh
noctalia msg plugin blanchedeadwood/keychron-m3-battery:battery all refresh
```

## Notes

- **Processes:** every poll runs `python3 -I keychron-query.py` from the plugin
  directory (5 s timeout). Nothing else is spawned.
- **Device access:** the helper finds the receiver's vendor HID interface
  (usage page `0xFF0A`) under `/sys/class/hidraw`, writes one 64-byte "get
  power" report to it and reads the answer. It never changes mouse settings.
- **Files written:** `mouse.state` in the plugin data directory, holding the
  last level, charging flag and timestamp.
- **Network:** none.

### Protocol

Taken from the Keychron Launcher ("4k" / "8k_nordic" mouse protocol). On the
receiver's vendor interface (64-byte reports, no report IDs) the helper writes:

```
41 00 81 01 00 ... 00 <cs>      cs = (161 - sum(bytes 0..62)) & 0xff
```

Byte 0 is `0x01` ("get power") with bit 6 set to forward it to the wireless
mouse. The reply is `41 00 8c 01 xx <state> <percent> ...`. The helper prints
`<percent> <state>`, then `receiver=` and `receiver_fw=` lines from the
receiver's USB descriptor. Its exit codes are 2 (no receiver), 3 (no
permission) and 4 (mouse off or asleep).
