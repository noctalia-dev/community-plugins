# Nothing Ear

Battery, noise control, EQ presets and custom EQ, bass boost, spatial audio, Bluetooth codec, Personalised ANC,
Personal Sound Profile, low-latency mode and auto mono audio for Nothing and CMF earbuds and CMF Headphone Pro, controlled directly over Bluetooth. No Nothing X app
and no background daemon.

Tested on a **Nothing Ear (2)** only. The other models below use the same protocol according to
community reverse-engineering projects
([protocol notes](https://github.com/Zyrecx/noctalia-plugins/blob/main/nothing-ear/PROTOCOL.md)).
The plugin detects your model and hides controls it lacks. If something is off on your device,
please open an issue.

| Model | ANC | Bass boost |
| --- | --- | --- |
| Nothing Ear (1), Ear (2), Ear (3), Ear (3a) | yes | no |
| Nothing Ear (2024), Ear (a) | yes | yes |
| Nothing Ear (stick), Ear (open) | no | no |
| CMF Headphone Pro | yes | no (physical bass slider) |
| CMF Buds Pro, Buds 2a | yes | no |
| CMF Buds, Buds Pro 2, Buds 2, Buds 2 Plus | yes | yes |

CMF Buds 2, 2 Plus and 2a get their own EQ presets. CMF Buds and Buds Pro 2 use presets this
plugin can't map reliably yet, so EQ is hidden there; every other model gets the Ear (2) presets.

CMF Headphone Pro (B175) shows a single headphone battery and gets its own EQ presets (Pop, Rock,
Electronic, Vocals, Classical, Custom) and **Spatial Audio** (Concert, Cinema, Off). Automatic mono does not apply to
headphones; manual mono remains available. The author doesn't own this model: detection, noise
control, low latency and mono were confirmed by an owner, the rest is tested with simulated
replies. See [the B175 research notes](https://github.com/Zyrecx/noctalia-plugins/blob/main/nothing-ear/PROTOCOL.md#cmf-headphone-pro-b175).

**Custom EQ**: selecting the Custom preset shows Bass, Mid and Treble sliders (−6 to +6 dB) right
under the presets, on every model except the Ear (1), CMF Buds and CMF Buds Pro 2. Changes apply
as you drag.

**Bluetooth Codec** appears on models that can switch: AAC/LHDC on the Ear (2), AAC/LHDC/LDAC on
the Ear (2024), AAC/LDAC on the Ear (a), Ear (3), Ear (3a), CMF Buds Pro 2, Buds 2 Plus and
Headphone Pro. Switching restarts the earbuds, so the panel asks first; audio stops for about
10 seconds. This only sets what the earbuds offer: LHDC or LDAC is used only if your system's
audio setup (PipeWire) supports it, and you may have to pick it there too.

## Plugin

| Field | Value |
| --- | --- |
| ID | `zyrex/nothing-ear` |
| Entries | Bar widget: `nothing-ear`; panel: `panel`; desktop widget: `desktop`; service: `service`; shortcut: `refresh` |

## Requirements

- `python3` on `PATH` (standard library only).
- `bluetoothctl` (BlueZ) on `PATH`, to list paired devices.
- `pactl` on `PATH` (PipeWire or PulseAudio), for mono audio only.
- The earbuds must already be paired. The plugin doesn't pair devices.

## Usage

Enable `zyrex/nothing-ear` in **Settings → Plugins**, then add the `nothing-ear` bar widget from
**Settings → Bar → Widgets**.

- If exactly one Nothing/CMF device is paired, it's picked automatically. Otherwise open the panel
  and choose one; if it isn't connected, the plugin asks Bluetooth to connect it. The Bluetooth
  button in the panel header lists your devices to switch to, without forgetting the current
  one. When the picked device isn't connected, the panel has a **Connect** button.
- The panel has two tabs: **Main** (battery, noise control, EQ presets and custom EQ) and **More**
  (spatial audio, low latency, mono, codec).
- Left-click the bar widget for the panel; right-click cycles noise control
  (off → transparency → noise cancellation).
- The bar icon shows the case or the buds that are out, with a badge for the noise mode. Hover it
  for battery levels. It takes the bar's **Widget Icon Color** (or **Widget Color**), set on the
  bar or on this widget, like the built-in icons do.
- The `desktop` widget is a compact battery and noise-mode card, under **Settings → Desktop
  Widgets**.
- The `refresh` shortcut (**Settings → Shortcuts**) forces a fresh read.
- Personalised ANC and Personal Sound Profile only appear when the earbuds support them. The sound
  profile needs a hearing test saved in Nothing X first; the panel only turns it on and off.

```sh
noctalia msg panel-toggle zyrex/nothing-ear:panel
```

### Mono audio

**Mono Audio** in the panel mixes both channels into each bud. With **Auto mono when only one bud
is out** on, mono turns on when one bud is in its closed case and off when it comes back out. The
earbuds don't report whether a bud is in your ear, so a bud in an open case still counts as out.
Toggling by hand pauses auto mono until the buds change state. The mono output shows up as
your earbuds' name plus "(Mono)" in the audio menu; picking another output turns mono off. It only applies
while the earbuds are your default output.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `device_mac` | `string` | `""` | Leave empty to auto-detect or pick from the panel. Set it to pin one device. |
| `show_in_bar` | `bool` | `true` | Show the battery number next to the bar icon, updated in the background. When off, only the icon shows. |
| `show_percentage` | `bool` | `true` | Add a `%` sign after the battery number. |
| `mono_on_single_bud` | `bool` | `false` | Switch to mono while one bud is in its closed case. See **Mono audio** above. |
| `hide_when_disconnected` | `bool` | `false` | Hide the bar icon until the earbuds or headphones connect. With none picked yet, newly paired ones are looked for every 20 seconds. The panel stays reachable with the `panel-toggle` command above. |

## IPC

```sh
# Noise control: anc, transparency or off. anc takes an optional strength:
# high, mid, low or adaptive. Without one it keeps the current strength, or uses adaptive.
noctalia msg plugin zyrex/nothing-ear:service all set-anc anc:high
noctalia msg plugin zyrex/nothing-ear:service all cycle-anc

# EQ preset: 0 Balanced, 1 Voice, 2 More Treble, 3 More Bass, 5 Custom.
# CMF Buds 2 / 2 Plus / 2a: 0 Dirac (2a: 7, 2 Plus: none), 1 Rock, 2 Electronic, 3 Pop, 4 Vocals,
# 5 Classical, 6 Custom. CMF Headphone Pro: the same without Dirac.
noctalia msg plugin zyrex/nothing-ear:service all set-eq 0

# Custom EQ curve as bass,mid,treble in dB, each -6 to 6. Doesn't select the Custom preset.
noctalia msg plugin zyrex/nothing-ear:service all set-custom-eq 3,0,-2

# Bass boost level 1-5, or 0 for off.
noctalia msg plugin zyrex/nothing-ear:service all set-bass 3

# Spatial audio on the CMF Headphone Pro: concert, cinema or off.
# Codec: aac, lhdc or ldac, whichever your model has (see above).
# set-codec restarts the earbuds straight away, without the panel's confirmation.
noctalia msg plugin zyrex/nothing-ear:service all set-spatial concert
noctalia msg plugin zyrex/nothing-ear:service all set-codec ldac

# On/off toggles: 1/true/on or 0/false/off.
noctalia msg plugin zyrex/nothing-ear:service all set-latency 1
noctalia msg plugin zyrex/nothing-ear:service all set-personal-anc 1
noctalia msg plugin zyrex/nothing-ear:service all set-sound-profile 1
noctalia msg plugin zyrex/nothing-ear:service all set-mono 1

# Device handling.
noctalia msg plugin zyrex/nothing-ear:service all refresh
noctalia msg plugin zyrex/nothing-ear:service all scan-devices
noctalia msg plugin zyrex/nothing-ear:service all select-device AA:BB:CC:DD:EE:FF
noctalia msg plugin zyrex/nothing-ear:service all connect
noctalia msg plugin zyrex/nothing-ear:service all forget-device

# Copy a diagnostics report to the clipboard (same as Copy details in the panel).
noctalia msg plugin zyrex/nothing-ear:service all copy-details
```

Current state is published as `nothing_ear_status` in shared plugin state
(`noctalia.state.get` / `noctalia.state.watch`).

## Troubleshooting

When the earbuds can't be reached, the panel says why and what to try. **Copy details** (also at
the bottom of the **More** tab while connected) puts a report on the clipboard for a bug report:
plugin and Python versions, what BlueZ knows about the earbuds, the last error, a fresh
connection attempt step by step, and the last five setting changes with the raw Bluetooth frames
each sent and received. If a change doesn't take (the device acknowledges it but still reports
the old value), the panel says so under the controls. The second half of the MAC
address is masked. The same report from a terminal:

```sh
python3 ~/.local/state/noctalia/plugins/materialized/community/nothing-ear/scripts/nothing_ear_ctl.py diag
```

## Notes

- Processes: the service runs `scripts/nothing_ear_ctl.py` once per poll or command over a raw
  RFCOMM socket, `bluetoothctl devices Paired` to list devices, `bluetoothctl info`/`show` to
  check the earbuds are connected and explain failures (all read-only), `bluetoothctl connect`
  when a disconnected device is picked or **Connect** is pressed, `gdbus monitor` on BlueZ to
  follow connects and disconnects as they happen (polling covers it without `gdbus`), and
  `scripts/mono_switch.py`, which calls `pactl` to load or unload a `module-remap-sink` named
  `nothing_ear_mono` and move streams onto it.
- Files: the RFCOMM channel, last-known state, the last five setting changes
  (`nothing_ear_last_write.json`), a lock file and the mono state
  (`nothing_ear_mono_state.json`) live in `$XDG_RUNTIME_DIR`. The chosen device is saved in
  `pluginDataDir()/device.json`, and the bar icon, recolored to the bar's icon color, in
  `pluginDataDir()/bar-icons/` (older colors are deleted). No network access.
- Spatial audio and codec changes first send the same reads (and the current time) the
  companion app sends when it connects, then the change.
- Polling only runs while the bar number, panel or desktop widget is showing, or auto mono is on
  (slower), and pauses while a setting change is being sent. Otherwise the service only asks
  `bluetoothctl info` every 4 seconds (no Bluetooth traffic). Either way the bar icon and
  **Hide when disconnected** follow BlueZ's connect and disconnect events straight away. Mono is always turned off when the plugin loads.
- The noise-mode icons were drawn for this plugin; no Nothing artwork is included.
- EQ preset indexes were mapped on an Ear (2); the CMF tables come from the projects below.
- One device at a time.
- Protocol facts were cross-checked against [ear-web](https://github.com/radiance-project/ear-web)
  and [earctl](https://github.com/DaanHessen/earctl) (both AGPL-3.0) and
  [BudsLink](https://github.com/maniacx/BudsLink) (GPL-3.0). No code from any of them is
  included; this plugin is MIT-licensed.
