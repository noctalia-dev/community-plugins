# Pulsar Mouse

Bar and desktop widgets showing battery percentage and charging status (plus signal strength in the bar widget's tooltip) for a Pulsar gaming mouse (via [pulsar-mouse-linux](https://github.com/harveywuk/pulsar-mouse-linux)), plus a quick-controls panel - with a profile switcher, on a mouse with more than one onboard profile - covering DPI stage, polling rate, debounce, angle snap, ripple control, motion sync, lift-off distance, LED (effect/brightness/speed), and - on wireless mice - power saving/low-battery threshold. Since desktop widgets are shared with Noctalia's lock screen, the desktop widget shows up in both places once added. Works with just the `pulsar-mouse` CLI installed - the GUI/tray isn't required, it's just more efficient if it's running (see Data source).

Battery/signal only apply to wireless mice - on a wired one, the bar widget shows a plain neutral glyph (still clickable, to reach the panel) and the desktop widget shows a plain "Wired" placeholder instead. The controls panel's Sensor, Advanced, and Lighting tabs work for any mouse; the Power tab (wireless power saving, low-battery threshold) only appears for a wireless one.

## Plugin

| Field | Value |
| --- | --- |
| ID | `harveywuk/pulsar-mouse` |
| Entries | Bar widget: `bar`; panel: `controls`; desktop widget: `battery` |

## Requirements

- [pulsar-mouse-linux](https://github.com/harveywuk/pulsar-mouse-linux) installed, with `pulsar-mouse` on `PATH` - every entry in this plugin shells out to it directly (see Notes for the full network/filesystem/process disclosure)
- `pulsar-mouse-gui` running is optional but recommended (autostart) - see Data source

## Usage

### Updating

`noctalia msg plugins update <source>` only re-syncs files from a path/git source - it does not re-register a plugin's entries (bar widget, panel, etc). If an update adds or changes an entry, do a full disable/enable cycle afterward to pick it up:

```sh
noctalia msg plugins update pulsar-mouse   # or whatever you named the source
noctalia msg plugins disable harveywuk/pulsar-mouse
noctalia msg plugins enable harveywuk/pulsar-mouse
```

### Bar Widget

Add the `bar` bar widget to your bar. Shows a battery glyph, icon-only, with a tooltip for the full status (percentage, charging, signal strength when available) - the glyph is the only thing rendered regardless of bar orientation; the glyph turns a secondary accent color while charging, or red once battery drops to the mouse's configured Low Power Mode threshold (see Controls Panel; falls back to 15% on a driver that doesn't expose that threshold, e.g. nordic.py). On a wired mouse (no battery to show) it stays visible as a plain neutral glyph rather than hiding, since it's the only way to open the controls panel - DPI/lighting controls still work on a wired mouse, only the Power tab doesn't apply. If `pulsar-mouse-gui` isn't installed or running at all, this widget still works, it just always reads a fresh value directly from the mouse instead of the GUI's cached one (see Data source).

### Controls Panel

Click the bar widget to open the `controls` panel. A **Profile** dropdown at the top (hidden on a single-profile mouse) switches the mouse's active profile - picking one calls `--active-profile N` and refreshes every field below, since profile switches affect essentially everything shown, not just DPI/LED. Below that, tabs (Noctalia has no native tabs control - these are just segmented buttons swapping which section renders):

**Sensor**
- **DPI** - a slider stepping through the active profile's configured DPI stages (not a raw DPI range - every position lands on an actual configured value, like a notch per stage)
- **Polling Rate** - a slider the same way, stepping through the device's supported rates
- **Lift-off Distance** - a slider, in mm (only shown for a driver with a continuous LOD range, like the Feinmann 8K's 0.7-2.0mm in 0.1mm steps - a driver with a fixed discrete LOD list instead isn't currently supported by this panel)

**Advanced**
- **Debounce** - a slider, in ms
- **Angle Snap**, **Ripple Control**, **Motion Sync** - toggles

**Lighting**
- **LED Effect** - a dropdown (off/steady/breathe, or whatever the device supports)
- **Brightness** - a 0-100% slider
- **Speed** - a 0-100 slider for the LED effect's speed, shown only when the current effect actually has one (e.g. breathe, not steady)

**Power** (wireless mice only)
- **Wireless Power Saving** - a slider, 30s-15min, shown as M:SS
- **Low Power Mode** - a slider, 0-100% battery threshold

All of these write straight through the `pulsar-mouse` CLI immediately on release (sliders commit on drag-end, not live per pixel) - unlike the battery reading, none of this lives in the cached state file, so the panel always talks to the mouse directly.

You can also open the panel over IPC:

```sh
noctalia msg panel-toggle harveywuk/pulsar-mouse:controls
```

### Desktop Widget

Add the `battery` desktop widget from Noctalia's desktop-widget editor (it's then also available for the lock-screen widget editor).

### Data source

The `bar` and `battery` entries both read battery percentage/charging/low-power-threshold from the reading `pulsar-mouse-gui` already writes on its periodic poll (`~/.cache/pulsar-mouse/battery.json`) rather than polling the mouse themselves, so they don't double up on USB traffic. If that file is missing or older than 3 minutes - the GUI isn't installed, isn't running, or was just closed - each falls back to its own direct `pulsar-mouse --battery-json` call instead, so both still work standalone, just with their own USB round-trip each tick. Signal strength is bar-only (the desktop widget doesn't currently show it) and has no synchronous getter besides - it only ever arrives via an async event the GUI listens for, so it's only available through the cached file, never the CLI fallback. The low-power threshold, unlike signal, does have a synchronous getter, so it's available via both paths, for both entries.

## Settings

### Bar Widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph_size` | `int` | `16` | Glyph size, 10-32. |

### Desktop Widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `color` | `color` | `primary` | Accent color for the percentage text and progress bar. |
| `show_progress` | `bool` | `true` | Shows or hides the battery-level progress bar. |
| `show_percent` | `bool` | `true` | Turn off to rely on just the glyph and progress bar. |
| `glyph_size` | `int` | `28` | Glyph size, 16-64. |

## Notes

- **No network access.** Every entry talks only to the local `pulsar-mouse` CLI (a spawned process, never a daemon) and, for the bar/desktop widgets, reads a local cache file.
- **Spawns `pulsar-mouse`** for every read and write - DPI/polling/LED/etc. changes in the controls panel, and the battery-json fallback read in the bar/desktop widgets when the cache is stale or missing.
- **Writes nothing itself.** `~/.cache/pulsar-mouse/battery.json` is written by `pulsar-mouse-gui` (a separate program from this plugin, part of the same `pulsar-mouse-linux` project) on its own periodic poll - this plugin only ever reads that file, never writes it.
- Requires Wayland/Hyprland (or another wlroots-based compositor) like the rest of Noctalia - no compositor-specific behavior beyond that in this plugin itself.
