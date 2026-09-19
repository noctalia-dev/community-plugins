# BT Buds

Bar widget, floating panel and background service for **Redmi Buds 6 Lite**
over Bluetooth: live battery (left/right/case), ANC / transparency / off modes,
Bluetooth codec switch (SBC / SBC-XQ / AAC) and a real software EQ — all from
the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jswift/bt-buds` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

## Requirements

Install `python3`, `ffmpeg` (provides `ffplay` for sound effects), `pactl`
(PipeWire) and `bluetoothctl` on `PATH`.

Hardware: a paired Redmi Buds 6 Lite (RFCOMM channel 29). The buds MAC is
currently hardcoded in `buds-daemon.py` (`MAC = "78:99:87:AD:44:BA"`) — change
it there for another headset. Also start the bundled daemon once:

```sh
cp buds-daemon.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now buds-daemon.service
```

## Usage

- **Left click** the widget — open/close the panel, or any time via:

```sh
noctalia msg panel-toggle jswift/bt-buds:panel
```

- **Right click** the widget — cycle name / battery / mode pages.
  **Middle click** — cycle ANC → transparency → off without opening the panel.
- **Panel** — noise-control buttons (ANC/transparency/off), battery columns,
  codec select, EQ select (Normal / More bass / Vocals / Highs),
  connect/disconnect buttons and the RU/EN language switch.
- The widget tooltip shows codec, mode and battery.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `language` | `select` | `auto` | Panel/widget language: follow shell (`auto`), English (`en`) or Russian (`ru`). |

## IPC

```sh
noctalia msg plugin jswift/bt-buds:service all <event> [payload]
```

| Event | Payload | Effect |
| --- | --- | --- |
| `refresh` / `hold` | — | re-read connection, codec, mode, battery, EQ |
| `toggle` | — | bluetooth connect/disconnect the buds |
| `set_mode` / `cycle_mode` | `anc`/`transparency`/`off` | listening mode via the RFCOMM daemon |
| `set_codec` / `cycle_codec` | `sbc`/`sbc_xq`/`aac` | A2DP profile via `pactl`; the EQ chain is rebuilt afterwards |
| `set_eq` / `cycle_eq` | `normal`/`more_bass`/`boost_vocals`/`more_highs` | restart the ffmpeg DSP chain with the preset |

## Notes

- **How EQ works**: apps are moved to the `eq_in` null sink, an `ffmpeg`
  process applies bass/treble/peaking filters and plays into the buds sink.
  Switching presets restarts ffmpeg (~3 s of silence); PipeWire latency adds a
  small A/V offset, fine for music.
- **Files written** under `~/.local/state/bt-buds/`: `mode.json`, `lang`,
  `eq.json`, `eq-ffmpeg.pid`, `ctl.sock` (daemon socket).
- **Processes spawned**: `python3` helpers, `pactl`, `bluetoothctl`,
  `ffmpeg`, `ffplay` (UI sounds). No network access.
- If the buds disconnect and reconnect, press any EQ/mode control once — the
  audio chain re-pins itself to the new sink.

## License

MIT
