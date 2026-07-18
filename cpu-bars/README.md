# CPU Bars

Shows the load on every logical CPU core at a glance, as a row of thin vertical bars
that fill from the bottom. Each bar is one core, so you can see an unbalanced load or a
single pegged thread that an averaged CPU percentage would hide.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ioandev/cpu-bars` |
| Entries | Bar widget: `cpu-bars` |

## Requirements

Noctalia with plugin API 5 or newer, for `noctalia.systemStats()`. Reads per-core usage
from `/proc/stat`, so it is Linux-only.

## Usage

Add the **CPU Bars** widget to a bar section in Settings → Bar. One bar is drawn per
logical core, in `/proc/stat` order — `cpu0` is leftmost. Bar height is that core's share
of busy time over the last second, and a core at or above the warning threshold turns red.

Hover the widget for a tooltip listing total CPU usage and a per-core breakdown.

The widget updates once a second, aligned to the top of the second. On a vertical bar it
rotates automatically: cores stack downward and each bar fills from the left.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `bar_width` | `int` | `3` | Thickness of each core's bar, in pixels. |
| `bar_gap` | `int` | `2` | Space between bars, in pixels. |
| `bar_height` | `int` | `16` | Length of each bar in pixels — height on a horizontal bar, width on a vertical one. |
| `warn_threshold` | `int` | `90` | A core at or above this percentage is drawn in the warning colour. |
| `normal_color` | `color` | `primary` | Colour of a core below the threshold. Accepts a theme role or a hex value. |
| `warn_color` | `color` | `error` | Colour of a core at or above the threshold. |
| `track_color` | `color` | `on_surface` | Colour of the unfilled part of each bar, drawn at 15% opacity. |
| `show_glyph` | `bool` | `true` | Show a CPU icon to the left of the bars. |

Colours accept either a theme role (`primary`, `error`, `tertiary`, …) or a hex literal
such as `#57ff57`. Theme roles follow your colour scheme, including light/dark switches.

## Notes

On a machine with many cores the widget is as wide as `cores × (bar_width + bar_gap)` —
about 120px for 24 cores at the defaults. Reduce `bar_width` and `bar_gap` to fit a
narrower bar.

Bar height is strictly proportional to usage, with no minimum: an idle core shows an empty
track. Since each pixel is `100 / bar_height` percent, usage below half a pixel — about 3%
at the default 16px — rounds away to nothing.

Per-core sampling is opt-in host-side: it runs only while a plugin is asking for it, and
costs one extra `/proc/stat` read per second. The plugin makes no network calls, spawns no
processes, and writes no files.
