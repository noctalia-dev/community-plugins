# ROG Omni Battery

Show separate mouse and keyboard battery levels for devices paired to one ASUS ROG Omni Receiver (USB `0b05:1ace`).

## Plugin

| Field | Value |
| --- | --- |
| ID | `suhoiyis/rog-omni-battery` |
| Entries | Bar widget: `bar`; service: `poll` |

## Requirements

- [Noctalia plugin API 43](https://docs.noctalia.dev/noctalia/plugins/development/plugin-api/), available in Noctalia 5.4.1 or later.
- `python3` (3.8 or newer) on PATH. The bundled helper uses only the standard library.
- Linux with hidraw and one ASUS ROG Omni Receiver (`0b05:1ace`).
- Read/write access to the receiver's vendor HID interface. See [Receiver permissions](#receiver-permissions) if the widget reports permission denied.

## Usage

1. Open **Settings → Plugins**, find **ROG Omni Battery**, and enable it.
2. Open **Settings → Bar → Bar Widgets**, choose **Add Widget**, and select **ROG Omni Battery**.

Hover either icon or percentage for the device name and charge status. A charging device uses the theme's secondary color. **Last reading** in the tooltip means the displayed percentage is cached. Left-click or right-click to refresh both readings. You can change either binding under the widget's **Actions** settings.

### Receiver permissions

If the widget reports **Permission denied** on a systemd-based desktop, open the [udev rule on GitHub](https://github.com/noctalia-dev/community-plugins/blob/main/rog-omni-battery/70-rog-omni-status.rules) and choose **Download raw file**. The same file, `70-rog-omni-status.rules`, is included in the plugin directory and source archive.

Run these one-time setup commands from the directory containing the rule:

```sh
sudo install -m 0644 70-rog-omni-status.rules /etc/udev/rules.d/70-rog-omni-status.rules
sudo udevadm control --reload-rules
```

Reconnect the receiver, wake both devices, then click the widget to refresh. The rule gives the active local desktop session access to the vendor interface (`02`) of USB device `0b05:1ace`. The plugin runs as the desktop user without `sudo`. To undo the setup, remove the installed rule, reload the rules, and reconnect the receiver.

## IPC

Refresh the widget on demand:

```sh
noctalia msg plugin suhoiyis/rog-omni-battery:poll all refresh
```

## Notes

- Tested on Noctalia 5.4.1 with two devices paired to the same Omni Receiver: a ROG Keris Wireless Aimpoint mouse and a ROG Azoth keyboard. The helper recognizes additional models. Test reports for those models are welcome.
- The service invokes `python3 -I <plugin directory>/rog-omni-status.py` once a minute and on manual refresh. A single service polls for all monitors.
- The helper reads local sysfs metadata and opens only the receiver's vendor HID interface. It sends three types of HID queries to request pairing information and mouse/keyboard battery status. It does not modify pairing, firmware or device settings.
- The latest valid percentage for the same paired device is kept in memory for up to 15 minutes when a device stops replying. The tooltip labels a cached value as a last reading. Receiver errors and changes clear cached values.
- The plugin itself makes no network requests and writes no files. Protocol reference: [HaloBattery's ROG Omni documentation](https://github.com/HeyOkay/HaloBattery/blob/main/docs/protocols.md#asus-rog-omni-receiver-mice-and-keyboards).
