# Honor Earbuds

[🇬🇧 English](README.md) | [🇷🇺 Русский](README.ru.md)

Active Noise Cancellation (ANC) control and real-time battery monitoring for HONOR CHOICE series TWS earbuds in Noctalia Shell v5.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nezerkill/honor-earbuds` |
| Entries | Bar widget: `honor-earbuds`; panel: `panel`; service: `service` |

## Requirements

Requires `python3` and `bluez` (`bluetoothctl`) on `PATH`. The earbuds must be paired via Bluetooth.

## Usage

- **Bar Widget (`honor-earbuds`):** Left-click toggles the control panel; right-click cycles through ANC modes (`ANC` -> `Awareness` -> `Off`).
- **Control Panel (`panel`):** Shows separate battery indicators for Left, Right, and Case, along with quick-switch buttons for ANC modes. Run the following command to toggle the panel:

```sh
noctalia msg panel-toggle nezerkill/honor-earbuds:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notify_on_connect` | `bool` | `true` | Show a popup notification with battery levels upon connection. |
| `hide_when_disconnected` | `bool` | `false` | Hide the bar widget when the earbuds are not connected. |
| `device_mac` | `string` | `""` | Override Bluetooth MAC address (automatically detected by default). |

## IPC

```sh
# Cycle noise cancellation mode (Off -> ANC -> Awareness -> Off)
noctalia msg plugin nezerkill/honor-earbuds:service all cycle-noise

# Set a specific noise cancellation mode (anc, transparency, off)
noctalia msg plugin nezerkill/honor-earbuds:service all set-noise anc

# Trigger battery status notification
noctalia msg plugin nezerkill/honor-earbuds:service all notify-battery
```

## Supported Models

Communicates via **Bestechnic (BES) RFCOMM SPP** protocol (channels 18 / 12):

| Model | Status | Features |
|---|---|---|
| **HONOR CHOICE Earbuds X5** | 🟢 Tested | ANC (Noise Cancellation / Awareness / Off), Battery (L/R/Case) |
| **HONOR CHOICE Earbuds X5 Pro** | 🟢 Compatible | ANC, Battery, Hardware EQ |
| **HONOR CHOICE Earbuds X3 / X3 Lite** | 🟢 Compatible | ANC, Battery |
| **HONOR CHOICE Earbuds X / X2** | 🟢 Compatible | Battery, Controls |
| **Moecen TWS (OEM Honor Choice)** | 🟢 Compatible | Bestechnic protocol |

## Notes

- Uses `bluetoothctl` to quickly check connection state (~7 ms) before querying RFCOMM sockets, preventing hangs when disconnected.
- Standalone CLI utility `honor-anc` (`scripts/honor-earbuds.py`) can also be run independently from terminal.

## License

MIT License.
