# Pixel Shift

Protects OLED screens from burn-in caused by the bar. Pixel Shift measures your own
bar, simulates how its pixels wear over time and moves the bar's groups by a few
pixels in the pattern that leaves the faintest ghost. The Burn-in Lab shows where the
risk is, how much the strategy removes, and what shifting cannot fix.

![Burn-in Lab](https://raw.githubusercontent.com/mgeldi/noctalia-pixel-shift/main/docs/screenshots/lab-ghost.png)

## Plugin

| Field | Value |
| --- | --- |
| ID | `mgeldi/pixel-shift` |
| Entries | Bar widget: `spacer`; panel: `lab`; service: `engine`; shortcut: `toggle` |

## Requirements

Install `grim` on `PATH`. It captures the bar strip, so the plugin works on
compositors with wlr-screencopy (Hyprland, niri, sway, labwc, mangowc).

When `loginctl` (systemd) is available, Pixel Shift uses it to skip samples while the
session is locked.

## Usage

1. **Add the spacers.** Add the **Pixel Shift** spacer widget to your bar four times:
   as the first item of the left section, the last item of the right section, and the
   first and last item of the center section. In TOML:

   ```toml
   [widget.ps_start]
   type = "mgeldi/pixel-shift:spacer"

   [widget.ps_center_l]
   type = "mgeldi/pixel-shift:spacer"

   [widget.ps_center_r]
   type = "mgeldi/pixel-shift:spacer"

   [widget.ps_end]
   type = "mgeldi/pixel-shift:spacer"
   ```

   and `start = ["ps_start", ...]`, `center = ["ps_center_l", ..., "ps_center_r"]`,
   `end = [..., "ps_end"]`.

   The spacers are invisible. Pixel Shift changes their width over the day, which
   moves the widgets next to them.

2. **Wait a moment.** On first start Pixel Shift measures the bar (it twitches for
   about a second), then finds the best strategy in the background and starts
   shifting.

3. **Open the Burn-in Lab:**

   ```sh
   noctalia msg panel-toggle mgeldi/pixel-shift:lab
   ```

   - **Ghost** shows what the bar would leave on a flat grey screen after long use.
     Hotspots glow in your theme colour, as bright as their risk.
   - **Risk** and **Bar** show the risk map and the bar itself; **No shift** and
     **Strategy** compare the two.
   - The list names each hotspot's cause and what to change, for example a solid fill
     wider than the shift range. It also names spacers that sit where they cannot
     move anything.
   - **Strategy** shows the risk for every amount of movement. In **Auto** mode Pixel
     Shift picks the point where more movement stops paying off; move the
     **Calm ↔ Max protection** slider and press **Apply** to choose another point.
     **Manual** sets each spacer's range yourself. **Revert** goes back to the
     previous strategy.

4. **Pause when you need a still bar.** Add the **Pixel Shift** tile in
   Settings → Control Center. A click pauses or resumes shifting; a right click opens
   the lab.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `panel_profile` | `select` | `generic` | OLED technology of your screen: `generic` (blue wears fastest), `woled` (LG, white subpixel), `qdoled` (Samsung, all channels from blue emitters). Changes how much each colour channel wears. |
| `sample_minutes` | `int` | `10` | How often the bar is captured to learn what it shows over the day (2–60). |
| `step_minutes` | `int` | `4` | Time between 1 px moves (1–30). Spacers use slightly different multiples so they never move in step. |
| `max_shift` | `int` | `16` | Upper limit in px for any spacer's range (2–32). |

**Allow vertical shift** is a toggle in the lab, off by default (see Notes).

## IPC

```sh
noctalia msg plugin mgeldi/pixel-shift:engine all <event> [payload]
```

| Event | Effect |
| --- | --- |
| `pause`, `resume`, `toggle` | Stop or restart shifting (all spacers go to width 0 while paused). |
| `rescan` | Measure the bar of the output shown in the lab again. |
| `optimize [output]` | Search a new strategy for that output (default: the lab's output). |
| `lambda <0..1>` | Protection level, 0 = calm, 1 = maximum; previews the strategy. |
| `apply`, `revert` | Make the previewed strategy active, or go back to the previous one. |
| `allow-vertical on\|off` | Turn vertical shift on or off. |
| `sample` | Capture an exposure sample now. |
| `view bar\|ghost\|risk`, `mode none\|strategy`, `output <name>`, `hotspot <n>` | Drive the lab. |
| `lab` | Toggle the Burn-in Lab. |
| `debug` | Write the engine state to the Noctalia log. |

## Notes

**How it works.** For each output, Pixel Shift widens every spacer by a few pixels in
turn and captures the bar with `grim`. The differences show which columns move with
which spacer and how far. The capture is split into the static background and the
content that moves. A wear model (per-channel brightness to the power of 1.6, weighted
by panel type) turns the bar into a wear map. Visible burn-in risk is the difference
between a pixel's wear and its neighbourhood, at a fine scale (strokes, icon edges) and
a coarse one (blocks, pill cores). An optimiser searches the spacer ranges that
minimise that risk for every movement budget. The strategy is played from the wall
clock: each spacer walks 1 px at a time and spends equal time on every offset.
Samples captured over the day replace the single snapshot once there are enough of
them, so changing content like window titles is weighted by how long it is actually
shown. Samples that do not show the measured bar, such as a lock screen or a
fullscreen window, are skipped, and a measurement in which no spacer moves anything
never replaces one that worked. The risk numbers are relative (100 = a 1 px white line that never moves); the
plugin makes no lifetime predictions.

**What shifting cannot fix.** A solid fill wider than the shift range keeps a
constantly lit core, and horizontal shifting never blurs horizontal edges. The lab
names both. An anchored center widget (`anchor = true`) pins the whole center section,
so the center spacers cannot move it; set the anchor to `false` to let the center
group shift.

**Spacing.** A spacer takes one widget spacing even at width 0; remove a neighbouring
gap if you want your old positions back.

**Vertical shift (opt-in).** When allowed, Pixel Shift writes its own file
`zz-pixel-shift.toml` in the Noctalia config directory with `margin_edge + 2v` and
`thickness − 2v`. The content moves by `v` px while the reserved space, and every
window, keeps its size. Each step reloads the config, which makes the bar blink
briefly; steps happen every 30 minutes. Turning the option off, pausing, or disabling
the plugin removes the file. If a GUI setting overrides the bar's margin or thickness,
the plugin notices and turns vertical shift off again. Pixel Shift reads your own
margin and thickness whenever the file is absent, so a change you make to them takes
effect the next time the offset returns to 0; turning vertical shift off and on again
picks it up within seconds.

**Files written.** In the plugin data directory (usually
`~/.local/state/noctalia/plugins/data/mgeldi/pixel-shift/`):

- `state.json`: strategies, preferences and what was measured per output.
- `layout-<output>.json`: the measured groups and how far each spacer moves them.
- `scan-<output>.bin`: the full-resolution capture of the bar strip from the last
  measurement, so whatever the bar showed then (window and media titles too), and the
  static background derived from it. Each measurement replaces it.
- `exposure-<output>.bin`: per-pixel running sums of the accepted samples. It keeps no
  individual frames, but while it holds a single sample it equals that capture.
  Written every 6 samples.
- `render/*.bmp`: the lab's images, including the **Bar** view, which shows the latest
  capture. The last two per image are kept, and all are removed when the plugin starts.

Captures are written briefly to `$XDG_RUNTIME_DIR/pixel-shift-*.ppm` and deleted after
reading. With vertical shift on: `zz-pixel-shift.toml` in the Noctalia config
directory (written as `zz-pixel-shift.toml.tmp` and renamed into place).

**Processes.** `grim` (during a measurement and every `sample_minutes`), `loginctl
show-session` (before each measurement and sample, when available), `noctalia msg
config-reload` (after the vertical override is removed, and once more if Noctalia did
not pick up a new override by itself), `noctalia msg settings-open bar` (the lab's
onboarding button).
On Noctalia versions without `noctalia.getColor`, opening the lab runs `noctalia msg
color-scheme-get` and `noctalia theme <wallpaper>` to find the theme colour.

**Privacy.** Only the bar strip and 8 px below it are captured. The capture from the
last measurement stays in the data directory (see above) and can show window or media
titles; removing the plugin's data directory deletes it. Nothing leaves your machine;
the plugin makes no network requests.

**Performance.** Measuring, optimising and rendering run in small slices between
frames, so the shell stays responsive. A search takes a few seconds of CPU per output,
spread over a minute or less.
