# EncoBuds

Battery, listening mode, game mode, prompt volume, find-my-earbuds and
dual-device control for OPPO, OnePlus and realme Enco earbuds, directly in the
Noctalia bar and panel.

The reverse-engineered Bluetooth RFCOMM protocol lives in the EncoBuds CLI,
which ships with this plugin in `scripts/` (Python 3 standard library only).
This plugin is only a Noctalia front end: the Luau entries never open an RFCOMM
socket themselves.

## Plugin

| Field | Value |
| --- | --- |
| ID | `fish/encobuds` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `service` |

`service` owns the only CLI process. It runs the bundled
`scripts/encobuds.py` with `python3` every 30 seconds, publishes one snapshot on
`encobuds.state`, and executes commands published on `encobuds.cmd`.

`bar` shows a mode-dependent glyph, the listening mode and the lowest earbud
battery. Left click opens the panel, right click cycles the listening mode, and
scrolling cycles once per gesture when enabled.

`panel` is laid out like the HeyMelody device page: product render, L/R/case
battery, listening-mode buttons, ANC level chips, remembered
devices, game mode, prompt volume and find-my-earbuds.

Open the panel from a keybind or terminal:

```sh
noctalia msg panel-toggle fish/encobuds:panel
```

## Requirements

- `python3` 3.10 or newer, using the distribution Python (the
  python-build-standalone interpreter lacks `socket.AF_BLUETOOTH`). The plugin
  runs the bundled CLI with it, so no separate install is needed.
- `bluetoothctl` for the device list and connection state
- Earbuds that are paired and connected in the system Bluetooth settings

The CLI lives in `scripts/enco/` and keeps its own config file at
`~/.config/encobuds/config.json` (`{"mac": "AA:BB:CC:DD:EE:FF"}`). When that
file has no address, the CLI reads the paired device list from `bluetoothctl`
and discovers the RFCOMM channel over SDP.

## Usage

Add the **EncoBuds** bar widget in **Settings → Bar → Widgets**.

- **Left click** opens the panel.
- **Right click** cycles off → smart ANC → transparency.
- **Scroll** cycles the listening mode once per gesture (can be disabled in the
  widget settings).

Inside the panel:

- Pick a listening mode with the three large buttons.
- Pick a specific ANC level with the chips below the mode buttons.
- Connect or disconnect a remembered device in **Device management**.
- Toggle **Game mode**, change **Prompt volume**, or ring the earbuds with
  **Find my earbuds**. Ringing stops automatically after 15 seconds.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_product_image` | bool | `true` | Show the Enco Air5 Pro render in the panel. |

The bar widget has its own settings, set per widget instance:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_mode` | bool | `true` | Show the listening-mode short name. |
| `show_battery` | bool | `true` | Show the lowest earbud battery. |
| `hide_when_offline` | bool | `false` | Hide the whole widget while the earbuds are disconnected. |
| `scroll_cycle` | bool | `true` | Cycle the listening mode on scroll. |

## IPC

Send commands to the service:

```sh
noctalia msg plugin fish/encobuds:service all refresh
noctalia msg plugin fish/encobuds:service all cycle
noctalia msg plugin fish/encobuds:service all mode deep
noctalia msg plugin fish/encobuds:service all game on
noctalia msg plugin fish/encobuds:service all find on
noctalia msg plugin fish/encobuds:service all volume 6
noctalia msg plugin fish/encobuds:service all connect Fone
noctalia msg plugin fish/encobuds:service all disconnect Fone
```

`mode` accepts `off`, `anc`, `deep`, `mid`, `light`, `smart` and `trans`.
`game` and `find` accept `on` or `off`. `volume` uses the earbuds' 2–10
levels, shown as 20%–100% in the panel.

## Status polling

The service polls `scripts/encobuds.py --json status` every 30 seconds, and
once per second while the earbuds are ringing.

## State

`encobuds.state` is a JSON snapshot:

```json
{
  "phase": "online",
  "mode": 7,
  "battery": {
    "left": { "level": 100, "charging": false },
    "right": { "level": 100, "charging": false }
  },
  "game": false,
  "volume": 8,
  "devices": [
    { "name": "MateBook", "mac": "…", "connected": true, "current": true }
  ],
  "product": "06C410",
  "firmware": "…",
  "busy": null,
  "error": null,
  "ringing": false,
  "updatedAt": 1764300000000
}
```

`phase` is `loading`, `online`, `offline` (not connected or no address) or
`error` (the CLI failed or timed out).

## Install

Enable **EncoBuds** in **Settings → Plugins**, then add the widget to a bar:

```toml
[widget.encobuds]
type = "fish/encobuds:bar"
```

Changes to `.luau` files hot-reload; manifest changes need a config reload.

## Notes

- The service spawns one `python3 scripts/encobuds.py` process per status poll
  (every 30 s) and one long-lived process while the earbuds ring.
- `find on` holds the RFCOMM link open and writes a `find.stop` file into the
  plugin data directory so the service can end it early.
- The CLI reads `~/.config/encobuds/config.json` and, when the MAC is not
  configured, lists paired Bluetooth devices through `bluetoothctl`.
- No network access: everything goes over local Bluetooth sockets.

## Assets

`assets/enco-air5-pro.png` is the product render from the
[OPPO Enco Air5 Pro product page](https://www.oppo.com/en/accessories/enco-air5-pro/).
It is used only to identify the device in the panel.
