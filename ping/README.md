# Ping

Shows the round-trip time to a host in the bar, colored by latency, and turns
red when it stops answering — a permanent read on whether the connection is
good, bad, or gone.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mete/ping` |
| Entries | Bar widget: `latency` |

## Requirements

The system `ping` binary (`iputils`). No other dependency.

## Usage

Add the `latency` widget to the bar. It pings the configured host on an
interval and shows the result next to a dot:

```
12ms      below the green threshold
47ms      between the two thresholds
248ms     above the yellow threshold
offline   no reply within the timeout
```

Both thresholds and all three colors are widget settings, so the bands can be
matched to the connection they describe. Defaults are green below 20ms, yellow
below 100ms, red above — and the colors of the GG Dark palette.

The dot breathes one sine cycle per ping interval — brightest the moment a
reply lands, darkest halfway to the next check — so its brightness reads as the
age of the number beside it. Offline holds it steady. The tooltip carries the
host, the current latency and the time of the last check.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `host` | `string` | `1.1.1.1` | What to ping. An IP avoids depending on DNS. |
| `interval_seconds` | `int` | `5` | How often the host is pinged. |
| `timeout_seconds` | `int` | `2` | How long to wait for a reply before reading offline. |
| `avg_count` | `int` | `1` | Average the last n successful pings instead of showing only the latest. `1` shows the latest ping as-is. |
| `threshold_good` | `int` | `20` | Below this round-trip time the value is green. |
| `threshold_warn` | `int` | `100` | Below this it is yellow, above it red. |
| `animate` | `bool` | `true` | Pulse the dot once per answered ping. |
| `color_good` / `color_warn` / `color_bad` | `color` | GG Dark green / yellow / red | The three band colors (advanced). |
| `dot_size` | `int` | `8` | Diameter of the dot in pixels (advanced). |

## Notes

The widget runs `ping` itself rather than going through a `[[service]]`: there
is one host and one reader, so the state channel would only add a hop. A second
instance on another bar pings on its own, which is what the low rate affords.

Latency is read from `ping`'s `rtt min/avg/max/mdev` summary line, which carries
three decimals, falling back to the per-packet `time=` value. Both are parsed
from English-independent numeric patterns, so the display does not depend on the
system locale.
