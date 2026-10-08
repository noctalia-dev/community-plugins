# ALS Brightness

Ambient-light adaptive panel brightness for Linux, implemented as a
[Noctalia](https://noctalia.dev) plugin service. The panel follows the light in
the room — and the moment you touch the brightness keys, it gets out of the way,
because a manual adjustment is treated as intent rather than as an error to be
corrected. An opt-in second feature drives the keyboard backlight the same way:
off in the light, on at its dark level in the dark.

Built for an ASUS Zenbook S 16 UM5606WA (AMD SFH ambient light sensor, Radeon
890M panel, niri + Noctalia), but nothing is specific to that chassis except the
defaults.

## Plugin

| Field | Value |
| --- | --- |
| ID | `zhangdm/als-brightness` |
| Entries | Service: `als` |
| Plugin API level | 24 |

The plugin is a single headless service (`als`, entry file `service.luau`): it
has no bar widget, panel or launcher prefix. Everything is driven by its
settings and a small number of IPC events.

## Requirements

- **Noctalia** (the plugin's declared dependency, `noctalia`) at plugin API 24
  or newer — Noctalia v5.0.0-beta.9+. The plugin shells out to `noctalia msg`
  (with an argv table, no shell interpolation) for `status`, `brightness-set`,
  `keyboard-backlight-set` and `config-reload`; the `keyboard-backlight-set` IPC
  the keyboard feature drives arrived in v5.0.0-beta.4. The idle handshake
  events described under [Usage](#usage) flow the other way — your idle policy
  sends them to the plugin.
- **Required for the panel feature:** an ambient light sensor
  (`/sys/bus/iio/devices/iio:deviceN` with `in_illuminance_raw` or
  `in_illuminance_input`) and a backlight device under `/sys/class/backlight`.
  If either is missing — or your `backlight`/`connector` setting names hardware
  this machine does not have — the plugin stays idle, shows one error
  notification, and writes nothing to the panel.
- **Optional:** any keyboard-backlight LED under `/sys/class/leds`
  (any `*kbd_backlight*` name — `asus::`, `tpacpi::`, `dell::` …) for the
  keyboard feature, and the colour-temp sensor, DPMS node, lid switch and `HOME`
  for colour temperature and guards. Each optional piece drops out with a log
  line if absent (an unavailable guard passes rather than blocks adaptation);
  everything else keeps working.
- **The idle handshake is required, not optional:** your idle policy must emit
  the handshake events (see [Usage](#usage)). Without it the adapter cannot tell
  the idle dim apart from you lowering the brightness, and will either fight the
  dim or record it as your preference.
- Discovery runs **once at start**. After plugging in hardware or changing the
  `connector`/`backlight` settings, toggle the plugin off and on to re-probe.

## Usage

Install and enable it as a plugin source, then enable the plugin itself:

```sh
git clone https://github.com/ZhangDM-520/noctalia-ambient-brightness
noctalia msg plugins source add als-brightness path ~/noctalia-ambient-brightness
noctalia msg plugins enable zhangdm/als-brightness
```

From then on the panel follows the light in the room: the service polls the
sensor and drives the panel brightness inside the band you configured. The
moment you change brightness by hand, the adapter treats that as your
preference and backs off instead of fighting you.

Two things must be configured outside the plugin.

### The idle handshake is required

Your idle policy must send `idle-engaged` when the idle dim starts and
`idle-released` after brightness is restored — the `dim` behaviour in nri-idle's
`~/.config/nri-idle/idle.toml`, each event delivered with
`noctalia msg plugin zhangdm/als-brightness:als all idle-engaged` (respectively
`idle-released`). Order matters: engage before dimming, release after restoring.

This is not optional. Without the handshake the adapter cannot tell the idle dim
apart from you lowering the brightness by hand, and will either fight the dim or
record it as your preference. Nothing is learned while the session is idle.

### Silence the OSDs

An adapter that changes brightness (or keyboard backlight) continuously pops an
OSD on every adaptation. Add two lines to `~/.local/state/noctalia/settings.toml`
— see [Making it seamless: silencing the OSDs](#making-it-seamless-silencing-the-osds)
under Notes for the full story, including why the plugin cannot do it for you.

Settings are configured in Noctalia's Settings UI, or via
`~/.local/state/noctalia/settings.toml` under
`[plugin_settings."zhangdm/als-brightness"]`.

The panel feature works out of the box. The keyboard backlight stays yours until
you turn on `keyboard_backlight`; from then on it follows the room as described
in [The keyboard backlight](#the-keyboard-backlight).

## Settings

Configured in Noctalia's Settings UI, or via
`~/.local/state/noctalia/settings.toml` under
`[plugin_settings."zhangdm/als-brightness"]`. Rows appear in the order below.

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `learning_profile` | `bool` | `false` | **The head of the settings page.** On: nudge the sliders below toward the ambient you adjust brightness in. Off: the sliders are used exactly as you set them. Either way the plugin keeps recording. |
| `keyboard_backlight` | `bool` | `false` | **Opt-in master switch for the keyboard feature.** On: the keyboard backlight follows the room (off above the threshold, on at the dark level below). Off: the keyboard backlight is left alone entirely. |
| `kbd_anchor_percent` | `int` | `40` | The **panel brightness percent** (window 25–75) that defines the keyboard threshold: the threshold is the ambient level where the *live* panel curve reaches this percent, so it tracks your sliders and learning instead of a fixed lux count. |
| `kbd_buffer_percent` | `int` | `15` | Hysteresis half-width as a **fraction of the threshold** (15 ⇒ the band is threshold × 0.85 … × 1.15): how far ambient must travel past the threshold before the keyboard changes state again. |
| `kbd_dark_percent` | `int` | `0` | The level (0–100) the keyboard runs at in the dark. **Zero = automatic: the lowest non-off level the LED can hold** — the host IPC is integer-only, so on a small `max_brightness` the first lit level sits well above 1 %. |
| `thr_brightness_01` … `thr_brightness_10` | `int` | 1, 4, 10, 30, 100, 185, 400, 1000, 2200, 16384 | **One slider per curve node.** Each chooses the ambient reading (raw sensor counts) where that node takes over; what the node outputs (20.8 % … 100 %) is fixed. |
| `thr_temperature_01` … `thr_temperature_10` | `int` | 2500 … 6500 | The panel-warmth thresholds, same idea. Shown only while `colortemp` is on. |
| `show_advanced` | `bool` | `false` | **Advanced maps.** On: reveal the two raw map editors below; Off: hidden. |
| `curve_brightness` | `string_map` | 10 nodes | **Advanced** (behind `show_advanced`). Power-user override: one row per node, `reading:target`. Edit it and it wins over the sliders. |
| `curve_temperature` | `string_map` | 10 nodes | **Advanced.** Same shape. |
| `enabled` | `bool` | `true` | Master switch. While off the panel is left alone entirely. |
| `connector` | `string` | `""` (auto) | Output to drive; empty = the focused output found at start. Restart to apply. |
| `backlight` | `string` | `""` (auto) | Backlight device under `/sys/class/backlight`; validated at start. Restart to apply. |
| `min_percent` | `string` | `"15"` | Hard floor (percent), so a dark or occluded reading cannot blank the screen. |
| `max_percent` | `string` | `"100"` | Hard ceiling (percent). |
| `colortemp` | `bool` | `false` | Also warm the panel toward the ambient colour temperature. Warning: this forces night light on and rewrites `temperature_night`. |

### The curve

Each curve is **ten nodes**. A node is a pair — the ambient reading where it takes
over, and the output it produces there — and the two halves are edited in
different places: the **outputs are fixed** (20.8 %, 30.7 % … 100 % for
brightness; 5100 K … 6500 K for panel warmth) and **one slider per node chooses
its threshold**.

The full node list, one setting each:

| Setting key | Default | Fixed output |
| --- | --- | --- |
| `thr_brightness_01` | `1` | Node 1 threshold in raw sensor counts; node outputs 20.8 % brightness. |
| `thr_brightness_02` | `4` | Node 2 threshold; outputs 30.7 %. |
| `thr_brightness_03` | `10` | Node 3 threshold; outputs 39.3 %. |
| `thr_brightness_04` | `30` | Node 4 threshold; outputs 50.6 %. |
| `thr_brightness_05` | `100` | Node 5 threshold; outputs 63.4 %. |
| `thr_brightness_06` | `185` | Node 6 threshold; outputs 70 %. |
| `thr_brightness_07` | `400` | Node 7 threshold; outputs 78.3 %. |
| `thr_brightness_08` | `1000` | Node 8 threshold; outputs 88.3 %. |
| `thr_brightness_09` | `2200` | Node 9 threshold; outputs 96.8 %. |
| `thr_brightness_10` | `16384` | Node 10 threshold (the sensor ceiling); outputs 100 %. |
| `thr_temperature_01` | `2500` | Temperature node 1 threshold in ambient kelvin; panel output 5100 K. |
| `thr_temperature_02` | `2700` | Node 2 threshold; panel 5240 K. |
| `thr_temperature_03` | `3000` | Node 3 threshold; panel 5380 K. |
| `thr_temperature_04` | `3500` | Node 4 threshold; panel 5520 K. |
| `thr_temperature_05` | `4000` | Node 5 threshold; panel 5660 K. |
| `thr_temperature_06` | `4500` | Node 6 threshold; panel 5800 K. |
| `thr_temperature_07` | `5000` | Node 7 threshold; panel 5940 K. |
| `thr_temperature_08` | `5500` | Node 8 threshold; panel 6080 K. |
| `thr_temperature_09` | `6000` | Node 9 threshold; panel 6220 K. |
| `thr_temperature_10` | `6500` | Node 10 threshold; panel 6500 K. |

In the settings rows the **title is just the node id** (`Temp node 8`) and the
description states what it maps to (`sensor ambient temp mapped -> 6080K` —
row 8's fixed output, `FIXED_TEMPERATURE_Y[8]` in `curve.luau`).
The temperature curve compiles **four hidden anchors** (two below row 1, two
above row 10, replicating floor and ceiling) so PCHIP keeps its flat tangent
at both ends: ten rows in the UI, fourteen under the hood.

`thr_brightness_01` … `thr_brightness_10` are those sliders, low node first. As
ambient light rises past a slider's value, that node takes over from the one
before it. Sliding a node past its neighbour simply swaps two steps of the curve
— the pair travels together, so the shape is never in question — and two sliders
landing on the same reading are nudged one count apart (with a log line) so the
interpolation always has something to interpolate.

Because each slider is its own setting, editing one in the Settings UI commits
one value and touches nothing else.

### The maps (advanced)

`curve_brightness` and `curve_temperature` are still there, behind the
**Advanced maps** toggle (`show_advanced`, default off), as a power-user escape
hatch: one row per node, key the reading, value the target.

```toml
[plugin_settings."zhangdm/als-brightness".curve_brightness]
"00001" = "1:20.8"
"00030" = "30:50.6"
"00185" = "185:70"
"16384" = "16384:100"
```

**A map wins over the sliders exactly when it has been edited** — judged by
comparing its parsed nodes against the shipped defaults, so re-ordering rows or
retyping whitespace does not count. As long as it matches the defaults the
sliders are the curve; the moment you change a node (or add or drop one) the map
becomes the curve and learning is suspended, because two writers fighting over
one curve is how a profile goes bad. Delete the row you added to hand the curve
back to the sliders.

Two habits make map editing pleasant:

* **Keys are zero-padded** (`"00185"`, not `"185"`). The editor sorts rows by key
  as text, so the padding is what keeps the curve reading in numeric order down
  the page. A row you add with an unpadded key still works — it just sorts to the
  bottom.
* **The value can be either the target alone or the whole node.** `"70"` takes its
  reading from the key; `"185:70"` carries its own. The value always wins, so a key
  that has fallen out of step can never move a node you typed — at worst the row
  sorts somewhere unexpected, and the plugin logs a line saying so.

Values *between* nodes are joined with a **monotone cubic (PCHIP)**, which is
guaranteed not to overshoot the two nodes it sits between — so however you move a
node, the panel stays inside the band you drew. A `#` starts a comment and blank
cells are ignored, so a half-edited map cannot break anything.

Readings are raw sensor counts, not lux. The sensor's absolute calibration is
unverified (a phone torch at point-blank reads only 1665 lux), so the curve is
defined against counts you can read directly:

```sh
cat /sys/bus/iio/devices/iio:device*/in_illuminance_raw
```

The ten shipped nodes reproduce "25 percentage points per decade of ambient light"
around the one datum measured on the reference machine — 185 counts → 70% —
which is why a fresh install behaves sensibly.

### The learned profile

With `learning_profile` **on**, learning nudges the **threshold sliders**, never
the outputs. When you set brightness by hand, the change targets the node whose
fixed output is nearest the level you chose, and that node's threshold eases
(EMA, α = 0.125) toward the ambient light you were in — so the curve drifts to
match where you actually want each level, while its shape stays the one drawn
above. Two observations move anything at all; a node you have never been near
stays exactly where you slid it.

The toggle gates **application, never recording**. The plugin always records, so
switching it on shows a profile that has been developing rather than an empty one.
That is what makes it useful while working out an initial curve. Nothing is
learned while the session is idle — the 30 % idle dim is policy, not a
preference.

The profile lives in `profile.json` in the plugin's data directory. The plugin
**cannot write its own settings** — the Noctalia host does not permit it — so the
learned thresholds apply at runtime and are not written back to the sliders; a
slider you move yourself is the seed learning starts from. (While a `curve_*` map
is edited and winning, learning is suspended entirely.)

### The keyboard backlight

With `keyboard_backlight` **on**, the keyboard is two states driven by the same
ambient reading as the panel: **above the threshold the backlight is off
(0 %); below it the keyboard runs at the dark level** (`kbd_dark_percent`,
zero = automatic lowest non-off level). The threshold is **curve-anchored**: it
is the ambient level where your *live* panel brightness curve reaches
`kbd_anchor_percent`, so moving the brightness sliders — or letting learning
drift them — moves the keyboard's dark point with them. A hysteresis band
(threshold × (1 ± `kbd_buffer_percent`/100)) stops edge flicker: ambient must
travel past the band edge before the state flips again.

**Manual changes win.** The Fn keys write the LED directly; the plugin sees the
change through the sysfs readback, adopts your level, and holds auto adaptation
until ambient crosses the band edge that would have flipped the state — then it
releases and adapts on that crossing, never stomping what you just set.

**Habit learning.** Three or more manual changes within ten minutes nudge a
learned threshold scale (EMA α = 0.125, clamped to [0.5×, 2×]) toward the
ambient you made them at, so a habitually retuned keyboard moves its threshold
where you actually want it. Nothing is learned while the session is idle. The
scale (`kbd_scale` in `profile.json`) is the only learned keyboard state, and
like the panel's learned thresholds it is applied at runtime only — never
written back to settings.

## IPC

The `[[service]]` entry (`als`) consumes the idle-handshake events. Your idle
policy and key bindings send them with:

```sh
noctalia msg plugin zhangdm/als-brightness:als all <event>
```

| Event | Effect |
| --- | --- |
| `idle-engaged` | The idle dim has engaged: adaptation holds and nothing is recorded (the dim is policy, not a preference). |
| `idle-released` | The dim has restored: the session re-baselines from the restored panel value, so the restore is never mistaken for a manual change. |
| `user-adjusted` | You changed the brightness by hand (the brightness keys): opens the manual-override window and records the observation for learning. Ignored while the session is idle. |

Any other event is logged as unknown and ignored.

## Notes

### Making it seamless: silencing the OSDs

An adapter that changes brightness continuously will pop Noctalia's OSD every
time it adapts, which is not seamless — and every keyboard-backlight write pops
the keyboard-backlight OSD the same way. Add this to
`~/.local/state/noctalia/settings.toml`:

```toml
[osd.kinds]
brightness = false
keyboard_backlight = false
```

This is the only precise fix, and it is **why** it is in your config rather than
in the plugin: every OSD passes through a single gate in `OsdOverlay::show()` that
checks `osd.kinds` per kind, but a plugin cannot write config. The plugin's only
runtime lever, `noctalia msg osd-disable`, is **global** — it would also kill your
volume, Wi-Fi, Bluetooth and caffeine OSDs. The plugin never toggles the OSD
override, and it will not touch your OSD settings on your behalf; the colortemp
feature's own splice of this same file (see below) is a deliberate, documented
exception.

Two bonuses worth knowing about:

* It silences the OSD for **every** writer, not just the plugin — so the
  idle `dim` at 50 s and the `brightnessctl -r` restore on resume stop popping one
  too.
* Noctalia's `[osd]` cosmetics in `settings.toml` are known to drive the OSD
  (the reference machine renders it at `bottom_center`, not the documented default), so the
  `[osd.kinds]` table in the same file is read too.

The cost is the OSD when you press the brightness or keyboard keys yourself: the
gate is per-kind, not per-writer, so the two cannot be separated. Brightness is
the one setting where the screen is its own feedback, but it is a real trade.

**Do not try to dodge the OSD by writing sysfs instead.** It cannot work twice
over: the backlight `brightness` file is `-rw-r--r-- root root`, so a user-space
write is not possible at all, and Noctalia watches the file with inotify and fires
the same change callback — which pops the same OSD. `brightness-set` is not the
problem; the change callback is, and it fires for every writer.

### What the plugin writes and spawns

* **`profile.json`** and **`als-brightness.log`** in the plugin's data
  directory (`noctalia.pluginDataDir()`): the learned profile (panel threshold
  observations plus the keyboard `kbd_scale`) and the log ring's output.
* **The night-light splice:** with `colortemp` on, `[nightlight]
  temperature_night` in `~/.local/state/noctalia/settings.toml`, edited as text
  (comments and key order survive) and replaced atomically — written to a
  `settings.toml.als-brightness.tmp` scratch file next to it, renamed over the
  original, then `noctalia msg config-reload` is run. The file is returned
  unchanged when nothing changes.
* **Short-lived `noctalia msg` processes:** `brightness-set`,
  `keyboard-backlight-set`, `config-reload` and `status`, spawned per event or
  adaptation. Keyboard-backlight writes are UPower-backed (KbdBacklight D-Bus)
  and rootless, but they set **all** keyboard backlights the host sees.

### Keyboard-backlight limitations

* **Several keyboard backlight devices:** `keyboard-backlight-set` sets every
  keyboard backlight at one percent; devices with different `max_brightness`
  therefore land on different raw levels from the same command.
* **Large LEDs (`max_brightness` ≥ 200):** the IPC takes integer percents only,
  so raw level 1 is unreachable (percent 1 already rounds past it) and the
  lowest reachable level is used.
* **Changed hardware needs a restart:** discovery runs once at service start —
  toggle the plugin off and on to re-probe after plugging in an LED or sensor.
