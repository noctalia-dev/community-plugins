# Typing Stats

A small capsule for the Noctalia bar: a progress bar that fills as you type, and after it the
number of completed blocks. Every 100 typed characters advances the number by one. It keeps an
**all-time total** and a **separate count for every day**, can switch the capsule between today
and the total, and opens an **interactive calendar heatmap**: each day is colored by that day's
input, and hovering a day shows its count.

```
  ┌────────────────────────────────────┐
  │ ☀  ████████████░░░░░░░░  42        │   today's count
  └────────────────────────────────────┘
     mode  progress to next 100  blocks

  ┌────────────────────────────────────┐
  │ ∞  ██████░░░░░░░░░░░░░░░  318       │   all-time count
  └────────────────────────────────────┘
```

## Plugin

| Field | Value |
| --- | --- |
| ID | `goldesquemoon/typing-stats` |
| Entries | Service: `counter`; bar widget: `capsule`; panel: `calendar`; shortcuts: `reset`, `heatmap`, `setup` |

The bar widget lives in the bar's normal widget capsule. It stores a total and a per-day history
in the plugin data dir, so both survive restarts and updates. The heatmap panel is a month
calendar in the style of the control-center calendar.

## Screenshots

| Calendar panel | Settings |
| --- | --- |
| ![Calendar heatmap panel with per-day counts](https://raw.githubusercontent.com/Goldppx/noctalia-typing-stats/main/docs/screenshots/heatmap-panel.png) | ![Plugin settings: counting, block size, thresholds, notifications, window filter](https://raw.githubusercontent.com/Goldppx/noctalia-typing-stats/main/docs/screenshots/settings.png) |

## Requirements

| Requirement | Why |
| --- | --- |
| `python3` | Runs the small evdev reader that counts printable keys. |
| `udevadm` | Applies the one udev rule that grants read access to keyboard event nodes. |
| One-time root setup | Click the **Grant input access** tile once (polkit), or `sudo ./setup.sh`. |
| A polkit agent (optional) | Makes that click open the authentication dialog; without one, run `setup.sh` in a terminal. |
| `niri (focused-window filter)` | Tracks the focused window for the optional whitelist/blacklist filter. |

Wayland has no protocol for observing global key presses, so the plugin reads the kernel input
devices, which needs read permission on `/dev/input/event*`. `setup.sh` installs one udev rule
that tags keyboard event nodes `uaccess`; systemd-logind then gives the active local session user
an ACL (no group membership, no re-login).

## Install

**From the plugin store (recommended)**

1. Settings -> Plugins -> Store, search **Typing Stats**, install and enable it.
2. Add the capsule: Settings -> Bar -> Add widget -> *Typing Stats*.
3. Grant input access once: Settings -> Control center -> Shortcuts -> *Grant input access*,
   then click that tile. Your desktop's authentication dialog (polkit) opens and `setup.sh`
   installs the udev rule. The capsule starts counting within a few seconds - no reload, no
   re-login. The tile then reads **Input access granted** and greys out.

If no polkit agent is running, the notification that follows prints the exact
`sudo <path>/setup.sh` command, and `python3 scripts/typelisten.py --test-devices` tells you
whether the rule works.

**From a checkout**

```sh
sudo ./setup.sh        # udev rule (once; or click the tile)
./install.sh           # register the source (only in a source root) + enable the plugin
```

Then add the capsule once:

- **Settings → Bar → Add widget → Typing Stats**, or
- in `~/.local/state/noctalia/settings.toml`:

  ```toml
  [bar.default]
  start = [ ..., "typing" ]

  [widget.typing]
  type = "goldesquemoon/typing-stats:capsule"
  capsule = true
  ```

Add the optional control-center tiles under Settings → Control Center → Shortcuts:

- **Grant input access** (`setup`) - installs the udev rule without a terminal; greys out once
  the listener reports `READY`
- **Reset typing stats** (`reset`)
- **Typing heatmap** (`heatmap`, opens the calendar panel)

## Usage

Just type. The capsule shows:

- a **mode glyph** — ☀ for today, ∞ for all time
- the **progress bar** — characters since the last completed block
- the **number** — completed blocks (`floor(characters / block_size)`)

**Left click** the capsule to switch between today and all time. The mode is persisted.
**Right click** opens the heatmap calendar attached below the bar, under this capsule; the
middle click opens the plugin settings. The tooltip shows today's characters, the all-time
total and the progress within the current block.

### Heatmap calendar

Right-click the bar capsule to open the panel attached to the bar and anchored under the
capsule. The **Typing heatmap** tile opens the same panel attached at the bar's default position
(it has no capsule anchor). It mirrors the control-center calendar:

- 7 columns, Monday-first; current month with `<` / `>` month navigation
- each day filled with the theme primary at one of four fixed levels (see `thresholds` below), not relative to the month's maximum
- the current day outlined; previous/next-month days faded
- **hover any day** to see `YYYY-MM-DD · N characters`
- the footer shows the month total and today's count

```sh
noctalia msg panel-toggle goldesquemoon/typing-stats:calendar
```

The color levels are **fixed thresholds**, one layer at a time (defaults):

| Level | Daily characters |
| --- | --- |
| 0 | 0–499 |
| 1 | 500–999 |
| 2 | 1000–1999 |
| 3 | 2000–4999 |
| 4 | 5000+ |

Change them with the **Heatmap thresholds** setting, for example `300,800,1500,3000`. With
**Notify on a new level** enabled, reaching
a new level (500, 1000, 2000 or 5000 by default) sends a notification with the count and level.

### Reset

The **Reset typing stats** tile or IPC clears **both** the all-time total and the whole daily
history:

```sh
noctalia msg plugin goldesquemoon/typing-stats:counter all reset
```

Simulate input for testing (does not touch the daily history incorrectly; it counts as today):

```sh
noctalia msg plugin goldesquemoon/typing-stats:counter all add 100
noctalia msg plugin goldesquemoon/typing-stats:counter all mode today
noctalia msg plugin goldesquemoon/typing-stats:counter all mode total
```

## What counts

- Letters, digits, punctuation, space and keypad keys.
- Autorepeat does **not** count: holding a key adds one, never a stream of free characters.
  This is deliberate, to keep the statistics honest.
- Shortcuts do **not** count: a key pressed while Ctrl, Alt or Super is held is ignored.
- Navigation/function keys, Backspace, Enter, Tab and modifiers do not count.

Because the source is the keyboard device, this is a **printable-key count**. When an IME is
composing (for example pinyin for Chinese), the composition keys are counted as they are
typed; the committed CJK character is not counted a second time. No text, key names or
modifier state are stored — only totals.

## Window filter

The optional filter counts only some windows, or skips some windows, based on the **focused
window's niri `app_id`**. It works with niri's JSON event stream, with a 5-second
`focused-window` poll as a fallback.

- **Off** — count every printable key (default).
- **Whitelist** — count only windows whose app ID is listed. An empty whitelist counts nothing.
- **Blacklist** — count every window except the listed ones. An empty blacklist counts everything.

App IDs are matched case-insensitively. Find the app ID of the current window with:

```sh
niri msg --json focused-window | grep -o '"app_id":"[^"]*"'
# or list every window:
niri msg --json windows | grep -o '"app_id":"[^"]*"' | sort -u
```

Then enter the IDs in **Settings → Plugins → Typing Stats → Filter app IDs**, for example
`Alacritty`, `wechat`, `firefox`. The filter applies to the all-time total, the daily counts and
the heatmap; level notifications only fire for counted keys.

> The filter needs niri. On another compositor there is no focused-window signal, so a whitelist
> counts nothing and a blacklist counts everything; use **Off** there.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `bool` | `true` | Count printable keys while the plugin is loaded. Turning it off keeps the stored totals and leaves the capsule in place. |
| `block_size` | `int` | `100` | Characters per block: the number after the bar advances by one every `block_size` characters. |
| `thresholds` | `string` | `500,1000,2000,5000` | Four comma-separated daily character counts for levels 1–4; below the first value is level 0. |
| `level_notify` | `bool` | `true` | Send a notification when today's typing reaches a new heatmap level. |
| `filter_mode` | `select` | `off` | `off`, `whitelist` (count only listed apps) or `blacklist` (skip listed apps). |
| `filter_apps` | `string_list` | empty | niri app IDs, case-insensitive. Empty whitelist counts nothing; empty blacklist counts everything. |

The data file (`stats.json` in the plugin data dir) contains:

```json
{
  "version": 2,
  "chars": 12345,
  "today": "2026-11-03",
  "days": { "2026-11-02": 640, "2026-11-03": 690 },
  "display_mode": "today"
}
```

It is written at most once every 5 seconds (and on reset), so a crash loses at most a few
seconds of counting. A v1 file that only had `chars` is migrated by assigning the old total to
today.

## How it works

```
typelisten.py ── "C" ──► service.luau ── state "stats" ──► widget.luau
  (evdev)                  (total + days)                  (progress + number)
                                │
                                └── state "display_mode" ──► widget.luau
```

- The listener opens the keyboard event nodes, tracks Ctrl/Alt/Super, and prints one `C` line
  per printable key press. It prints `PING` every 15 s; the service restarts it if it goes
  silent.
- The service adds each `C` to the all-time total and to `days[today]`, detects the local date
  change (resetting today's bucket at midnight even without typing), and publishes the summary
  on the plugin state store. The widget renders from that summary.
- `display_mode` lives on the shared state: the widget's click writes it, the service persists
  it and republishes the summary.
- The optional window filter reads the focused window from `niri msg --json event-stream`
  (`WindowsChanged`, `WindowOpenedOrChanged`, `WindowClosed`, `WindowFocusChanged`) and falls
  back to a `focused-window` poll every 5 seconds. Each `C` line is counted only if the current
  app passes the whitelist/blacklist check.
- The heatmap panel is a declarative month calendar: it reads the persisted history plus the
  live `stats` summary, lays out a Monday-first 6×7 grid, colors every day by the fixed
  `thresholds` levels, and puts the date + count in each cell's hover tooltip. Month navigation
  is local to the panel.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| The capsule stays at 0 while typing | `python3 typing-stats/scripts/typelisten.py --test-devices` — every node must say `READABLE`; otherwise run `sudo typing-stats/setup.sh`. |
| The capsule is missing | Add it once under Settings → Bar → Add widget → Typing Stats. |
| The number does not change until 100 | It is the completed-block count; the progress bar is the per-key feedback. |
| Count jumps by more than expected | The IME composition keys are counted as typed keys; shortcuts are excluded. |
| No ACL after setup | Log in through a display manager (logind seat), or `sudo usermod -aG input $USER` and log back in. |

## Privacy

- The listener only tells the service that *a printable key* was pressed. It never reports key
  names, codes, modifiers or text, and the service only stores counts per day.
- Everything stays on the machine: the counts, the data file and the panel. Nothing is sent
  anywhere.
- Access is an ACL for the active local session user. Disabling the plugin in Noctalia unloads
  the listener; `./uninstall.sh` removes the udev rule.
- Turning the **Count typing** setting off stops counting immediately, but the reader process
  keeps running until the plugin is unloaded (the runtime gives a service no way to stop a
  stream), so unload or disable the plugin if you want the device handles closed.

## License

MIT, see [LICENSE](LICENSE).
