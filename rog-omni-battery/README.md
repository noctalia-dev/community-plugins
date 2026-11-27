# ROG Omni Battery

Show separate mouse and keyboard battery levels for devices paired to one ASUS ROG Omni Receiver (USB `0b05:1ace`).

## Plugin

| Field | Value |
| --- | --- |
| ID | `suhoiyis/rog-omni-battery` |
| Entries | Bar widget: `bar`; service: `poll` |

## Requirements

- `python3` (3.8 or newer) on PATH. The bundled helper uses only the standard library.
- Linux with hidraw and one ASUS ROG Omni Receiver (`0b05:1ace`).
- Read/write access to the receiver's vendor HID interface. On a systemd-based desktop, install the bundled udev rule once if the widget reports permission denied.

## Usage

Enable the plugin and add the ROG Omni Battery widget from **Settings → Bar**. Hover the widget for device names and charge status. Right-click to refresh.

For the optional udev setup, obtain `70-rog-omni-status.rules` from this plugin directory and run the following commands from the directory containing the rule. Reconnect the receiver and wake both devices after reloading the rules.

```sh
sudo install -m 0644 70-rog-omni-status.rules /etc/udev/rules.d/70-rog-omni-status.rules
sudo udevadm control --reload-rules
```

The rule gives the active local desktop session access to the vendor interface (`02`) of USB device `0b05:1ace`. The plugin runs as the desktop user. To undo this setup, remove the installed rule, reload the rules and reconnect the receiver.

## IPC

Refresh the widget on demand:

```sh
noctalia msg plugin suhoiyis/rog-omni-battery:bar all refresh
```

## Notes

- Tested on Noctalia 5.4.1 with a ROG Keris Wireless Aimpoint mouse and a ROG Azoth keyboard paired to the same Omni Receiver. The helper recognizes additional model IDs, but those models have not been tested in this plugin.
- The service invokes `python3 -I <plugin directory>/rog-omni-status.py` once a minute and on manual refresh. A single service polls for all monitors.
- The helper reads local sysfs metadata and opens only the receiver's vendor HID interface. It sends three types of HID queries to request pairing information and mouse/keyboard battery status. It does not modify pairing, firmware or device settings.
- The latest valid percentage for the same paired device is kept in memory for up to 15 minutes when a device stops replying. The tooltip labels a cached value as a last reading. Receiver errors and changes clear cached values.
- The plugin itself makes no network requests and writes no files. Protocol reference: [HaloBattery's ROG Omni documentation](https://github.com/HeyOkay/HaloBattery/blob/main/docs/protocols.md#asus-rog-omni-receiver-mice-and-keyboards).
