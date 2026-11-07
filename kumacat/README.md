# KumaCat

An animated runner bar widget and hardware telemetry HUD for Noctalia. It curls up and sleeps when your system is idle, jogs as background tasks pick up, and breaks into a full sprint under heavy compilation or gaming loads.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mhdomer/kumacat` |
| Entries | Bar widget: `kumacat`; panel: `panel` |

## Usage

Add the "KumaCat" widget to any bar from Settings -> Bar -> Add Widget. Click the widget to toggle an attached telemetry HUD panel showing CPU, memory, and GPU gauges along with a live mirrored runner. Click anywhere outside the panel to dismiss it.

The panel can also be toggled directly over IPC:

```sh
noctalia msg panel-toggle mhdomer/kumacat:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `cat_size` | `int` | `24` | Sprite size in the bar, in pixels (12 to 48). |
| `drive_metric` | `select` | `cpu` | Hardware telemetry stream that drives runner speed (`cpu`, `memory`, or `gpu`). |
| `show_metric_percent` | `bool` | `false` | Display the metric percentage text next to the runner. |
| `sleep_threshold` | `int` | `5` | Load percentage below which the runner sleeps at zero FPS to eliminate CPU wakeups. |
| `turbo_threshold` | `int` | `75` | Load percentage at which the runner breaks into a sprint. |
| `poll_interval` | `int` | `2` | How often to read hardware telemetry, in seconds (1 to 10). |
| `cat_color_mode` | `select` | `theme` | `theme` colors the cat with the palette's secondary role; `custom` uses the color below. |
| `cat_color` | `color` | `#E8A24C` | Used when `cat_color_mode` is custom. |

## Notes

Every `poll_interval` seconds the widget samples system statistics via Noctalia's native host monitor (`noctalia.systemStats()`, plugin API 12). When system load drops below the configured sleep threshold, the runner transitions to idle sleep mode, halting animation frame ticks to conserve CPU cycles and battery life.

The attached HUD panel mirrors runner state through Noctalia's in-process shared state store (`noctalia.state`), meaning the panel introduces zero independent sampling overhead. The runner glyphs are loaded from an optimized custom vector icon font (`fonts/kumacat.otf`), traced from the MIT-licensed CatWalk plasmoid by Driglu4it, allowing instant palette recoloring with zero texture memory bloat.
