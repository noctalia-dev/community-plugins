# Sony Headphones

Battery monitor and noise control (ANC / Ambient Sound) for Sony Bluetooth
headphones in Noctalia v5+, speaking Sony's reverse-engineered **MDR V2**
binary protocol over Bluetooth RFCOMM — the same protocol the official Sound
Connect app uses. No phone, no account, no cloud.

## Plugin

| Field | Value |
| --- | --- |
| ID | `estvoid/sony_headphones` |
| Entries | Bar widget: `sony_headphones`; panel: `panel`; service: `service` |
| Launcher Prefix | — |

## Requirements

- `python3` on `PATH` (standard library only)
- `bluetoothctl` on `PATH` (BlueZ) to find and query the connected headphones
- `sdptool` on `PATH` (BlueZ) to resolve the RFCOMM channel; falls back to channel 9 when unavailable
- Paired and connected Sony headphones

## Usage

Add the `sony_headphones` bar widget via **Settings → Bar → Widgets**.

- **Left-click** the bar icon to toggle the control panel.
- **Right-click** the bar icon to cycle noise modes
  (`Noise Cancelling` → `Ambient Sound` → `Off`).

The panel shows the device photo (a header button cycles the available
artwork variants), a live battery gauge, and the three noise-mode buttons.

Toggle the panel from IPC / keybind:

```sh
noctalia msg panel-toggle estvoid/sony_headphones:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `device_mac` | `string` | `""` | Bluetooth MAC of the headphones. Blank = auto-detect the connected device. |
| `hide_when_disconnected` | `bool` | `true` | Hide the bar widget while the headphones are disconnected. |

## IPC

```sh
noctalia msg plugin estvoid/sony_headphones:service all cycle-noise
noctalia msg plugin estvoid/sony_headphones:service all set-noise anc
noctalia msg plugin estvoid/sony_headphones:service all set-noise transparency
noctalia msg plugin estvoid/sony_headphones:service all set-noise off
noctalia msg plugin estvoid/sony_headphones:service all set-ambient 12
noctalia msg plugin estvoid/sony_headphones:service all refresh
```

The backend works standalone too:

```sh
python3 scripts/sony_ctl.py status [--mac XX:XX:XX:XX:XX:XX]
python3 scripts/sony_ctl.py set-anc anc|transparency|off
python3 scripts/sony_ctl.py set-ambient 0..20
python3 scripts/sony_ctl.py cycle-anc
python3 scripts/sony_ctl.py cached
```

## Notes

- Talks to the Sony `Serial HPC` RFCOMM service (`956c7b26-…`, usually
  channel 9), resolved with `sdptool`.
- Spawns `python3 scripts/sony_ctl.py`, which runs `bluetoothctl`/`sdptool`,
  and writes a small cache to `$XDG_RUNTIME_DIR/sony_headphones_state.json`.
  No network access.
- Over-ear models report a single battery level; BlueZ `Battery Percentage`
  is the fallback when RFCOMM is busy.
- The device does not echo the ambient level back, so the panel shows the
  last-set level (persisted in the cache).
- `device_mac` and IPC payloads are shell-quoted before use.

### Model support

Battery works for every model universally through BlueZ; the deep
noise-control bytes differ per generation.

| Model | Battery | Noise modes | Notes |
| --- | --- | --- | --- |
| WH-1000XM5 | ✅ V2 + BlueZ fallback | ✅ verified (`0x17` subtype) | reference device |
| WH-1000XM6 | ✅ | ⚠️ untested (`0x19` fallback) | please report |
| WH-1000XX (1000X The Collexion) | ✅ BlueZ | ⚠️ untested | artwork included |
| WH-1000XM4 / XM3 | ✅ BlueZ | ⚠️ likely need V1 protocol | tracked for v0.2 |
| WF-1000XM5 / WF-1000XM4 | ✅ BlueZ | ⚠️ untested V2 subtypes | please report |
| LinkBuds / WH-CH720N / ULT | ✅ BlueZ | ⚠️ untested | please report |

The bundled artwork is a pair of generic headphone symbols from
[Tabler Icons](https://tabler.io/icons) (MIT; see
[`assets/README.md`](assets/README.md) and the bundled license text). They map
over-ear and true-wireless models to black/white variants; lookup is
case-insensitive and accepts alternate Bluetooth names. The symbols are
temporary placeholders for the author's own sketches.
