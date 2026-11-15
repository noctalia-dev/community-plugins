# KumaCat

An animated runner bar widget and hardware telemetry HUD for Noctalia. It curls up and sleeps at 0 FPS when your system is idle, walks as background tasks pick up, and breaks into a full sprint under heavy CPU, memory, or GPU loads.

## Plugin

| Field | Value |
| --- | --- |
| ID | `mhdomer/kumacat` |
| Entries | Bar widget: `kumacat`; panel: `panel` |

## Usage

Add the "KumaCat" widget to any bar from Settings -> Bar -> Add Widget. Select the widget to toggle an attached telemetry HUD panel showing CPU, memory, and GPU gauges along with a live synchronized runner and settings shortcut. Select anywhere outside the panel to dismiss it.

The panel can also be toggled directly over IPC:

```sh
noctalia msg panel-toggle mhdomer/kumacat:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `runner_style` | `select` | `flash-cat` | Choose between sprite packs (`flash-cat`, `cat-tail`) or theme-recolored `classic-cat` vector glyphs. |
| `cat_size` | `int` | `24` | Runner height in the bar, in pixels (12 to 48). |
| `drive_metric` | `select` | `cpu` | Hardware telemetry stream that drives runner speed (`cpu`, `memory`, or `gpu`). |
| `show_metric_percent` | `bool` | `false` | Display the active metric percentage text next to the runner. |
| `sleep_threshold` | `int` | `5` | Load percentage below which the runner sleeps at zero FPS and slows timer wakeups to `poll_interval`. |
| `turbo_threshold` | `int` | `75` | Load percentage at which the runner enters sprint pace. |
| `poll_interval` | `int` | `2` | How often to sample hardware telemetry, in seconds (1 to 10). |
| `cat_color_mode` | `select` | `theme` | `theme` colors Classic Cat glyphs, bar percentage text, and HUD primary gauge with the palette's `secondary` role; `custom` uses `cat_color`. |
| `cat_color` | `color` | `#E8A24C` | Custom hex color used when `cat_color_mode` is `custom`. |

## Notes

- **Zero external commands or network calls:** KumaCat reads snapshots exposed by Noctalia's built-in system monitor (`noctalia.systemStats()`, plugin API 12). Apart from loading its bundled font and PNG sprites, no files are read or written, nothing is downloaded, and no subprocesses are spawned.
- **Zero-FPS idle sleep:** When the active metric drops below `sleep_threshold`, `kumacat.luau` switches `noctalia.setUpdateInterval` from the `80ms` animation tick to `poll_interval` (`2000ms` by default), eliminating animation timer wakeups while idle.
- **GPU power hygiene:** On Noctalia releases supporting explicit GPU monitoring (`noctalia.setGpuMonitoring`, API 46), the bar widget only requests GPU probing when `drive_metric` is set to `gpu`, and the HUD panel requests GPU probing on `onOpen()` and releases it on `onClose()`.
- **Shared state panel sync:** The attached HUD panel mirrors the bar widget through `noctalia.state` without running an independent sampling loop. Without a KumaCat widget placed on any bar, the panel displays the sleeping sprite at 0%.
- **Artwork & license credits (`MIT AND Apache-2.0`):**
  - `runners/flash-cat/*` and `runners/cat-tail/*`: designed by Takuto Nakamura (`@Kyome22`) for [RunCat RunnerGallery](https://github.com/runcat-dev/RunnerGallery), licensed under Apache-2.0.
  - `runners/sleep.png`: designed by Roy C. Davies (`@reality2-roycdavies`) for [cosmic-runkat](https://github.com/reality2-roycdavies/cosmic-runkat), licensed under MIT.
  - `fonts/kumacat.otf`: vector cat icon font traced from the [CatWalk](https://store.kde.org/p/2055225) plasmoid by Driglu4it (packaged by DotNetRob in `dotnetrob/cat`), licensed under MIT.
