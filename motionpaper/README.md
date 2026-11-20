# Motionpaper

Hardware-accelerated dynamic video and image wallpaper manager for Wayland,
powered by GStreamer and the lightweight `gslapper` layer-shell daemon.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lawnninja/motionpaper` |
| Entries | Bar widget: `wallpaper`; panel: `picker`; service: `service` |

## Requirements

Motionpaper requires the following dependencies installed and available on `PATH`:

- `gslapper`: Lightweight Wayland layer-shell video renderer with hardware-accelerated GStreamer playback.
- `gst-launch-1.0`: Extracts initial still frames from videos to guarantee zero-gap transitions without black flashes.
- `find`: Indexes media directories on startup.
- `socat`: Communicates with gSlapper control sockets over UNIX domain sockets.
- `pkill`: Manages background processes during shutdown and auto-stop.

## Features

- **Hardware Acceleration**: High-performance video decoding via VA-API, NVDEC, or VDPAU through GStreamer.
- **Zero Black Flashes**: Pre-extracts and caches full-resolution still frames from video files, seamlessly holding the surface until decoding begins.
- **Independent Multi-Monitor Support**: Assign unique videos or static images to individual monitors, or synchronize across all outputs.
- **Smart Power Efficiency**: Optional auto-pause or auto-stop when windows or fullscreen surfaces obscure the desktop.
- **Timer Slideshow & Shuffle**: Automatic timed rotation across folder contents with shuffle support, preserving intervals across reboots.
- **Persistent State & Recovery**: Saved last-known wallpaper and slideshow intervals survive restarts and unexpected process termination.
- **Unified Controls**: One-click toggle stop / restore in both the UI panel and IPC interface.

## Comparison with Other Video Wallpaper Solutions

| Feature / Dimension | **Motionpaper** (This Plugin) | **mpvpaper** | **swww** | **hyprpaper** | **linux-wallpaperengine** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Supported Media** | **MP4 / WebM / MKV Video + Still Images** | Video only | Static Images & Animated GIFs | Static Images only | Scene, Web & Video Wallpapers |
| **Backend Engine** | **`gSlapper`** (C / GStreamer layer-shell) | `mpv` library / player wrapper | `swww` Wayland daemon | Native Hyprland daemon | Steam Wallpaper Engine runtime |
| **Hardware Decoding** | **VA-API / NVDEC / VDPAU** via GStreamer | VA-API via mpv | N/A (software GIF decoding) | N/A | OpenGL / Vulkan GPU shaders |
| **Black Frame Prevention** | **Zero black-flash**: Pre-extracts still frame before video start | Black flash on wallpaper load/switch | N/A (instant image flip) | N/A | Long initial compilation delay |
| **Multi-Monitor Setup** | **Independent per-output**: Mix video on one display and image on another | Per-output video | Per-output image | Per-output image | Per-output scene |
| **Power & Battery Efficiency** | **Smart auto-pause / auto-stop**: Suspends rendering when windows cover the monitor | None (runs continuously unless externally scripted) | Low idle draw (static images only) | Very low (static) | High GPU/battery draw |
| **Integrated Slideshow** | **Built-in timer rotation with shuffle** (preserves interval across restarts) | Requires external bash loop | Built-in timed rotation | External script required | Built-in playlist |
| **State Persistence & Recovery** | **Automatic state persistence**: Restores wallpapers & slideshows after restart/crash with unified toggle | None (stateless process) | In-memory cache only | Config file only | Stored in application profile |
| **Native Noctalia Integration** | **Rich UI Panel**: Visual thumbnail grid, search, directory browser, status badges, unified toggle | Basic / External | CLI only | CLI only | Separate GUI / Tray |
| **Scriptability & IPC** | **Rich IPC API** (`toggle-stop`, `toggle`, `pause`, `resume`, `next`, `slideshow`) | Named pipe / UNIX socket | UNIX socket CLI | Socket IPC | Command line arguments |

## Usage

Add the **Motionpaper** widget (`lawnninja/motionpaper:wallpaper`) to your bar in Noctalia Settings.

### Bar Widget Gestures

By default, the bar widget provides the following quick gestures:

- **Left Click**: Toggles the wallpaper picker panel (`lawnninja/motionpaper:picker`).
- **Right Click**: Toggles video playback pause / resume across active video wallpapers (`toggle-pause`).
- **Middle Click**: Toggles stop / restore across all wallpaper outputs (`toggle-stop`).

All gestures can be remapped in Noctalia's bar widget settings under gesture actions.

### Panel Controls

Select **All outputs** or a specific monitor (e.g. `DP-1`, `eDP-1`), then select an image or video to apply it. The control bar at the top lets you toggle video playback, toggle stop/restore, configure slideshow intervals, or toggle shuffle.

Toggle the picker from a terminal or keybinding:

```sh
noctalia msg panel-toggle lawnninja/motionpaper:picker
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `video_directory` | `folder` | `~/Videos/Wallpapers` | Root directory scanned for video wallpapers. Noctalia's native wallpaper directory supplies images. |
| `scale` | `select` | `fill` | Scaling mode: `fill`, `stretch`, `original`, or `panscan`. |
| `hidden_behavior` | `select` | `none` | Power behavior when wallpaper is covered: `none`, `auto-pause`, or `auto-stop`. |
| `loop` | `bool` | `true` | Restarts video playback at the end. |
| `fps_cap` | `select` | `30` | Frame rate cap: `30`, `60`, or `100` FPS. |
| `fade` | `bool` | `false` | Enables smooth crossfade transition between videos. |
| `fade_duration` | `double` | `0.5` | Duration in seconds when fading is enabled (0.1 - 5.0s). |
| `gst_options` | `string` | `""` | Advanced custom options passed directly to GStreamer. |
| `glyph` | `glyph` | `wallpaper-selector` | Icon glyph shown on the bar widget. |

## IPC

Control Motionpaper from shell scripts, user hooks, or compositor keybindings:

```sh
# Toggle stop / restore for all outputs (stops if running, restores if stopped)
noctalia msg plugin lawnninja/motionpaper:service all toggle-stop

# Toggle stop / restore for a specific output
noctalia msg plugin lawnninja/motionpaper:service all toggle-stop DP-1

# Short alias for toggle-stop
noctalia msg plugin lawnninja/motionpaper:service all toggle DP-1

# Pause or resume video playback across all or a specific output
noctalia msg plugin lawnninja/motionpaper:service all toggle-pause
noctalia msg plugin lawnninja/motionpaper:service all toggle-pause DP-1

# Direct pause / resume commands (also supported)
noctalia msg plugin lawnninja/motionpaper:service all pause
noctalia msg plugin lawnninja/motionpaper:service all resume DP-1

# Switch to the next wallpaper in the current directory
noctalia msg plugin lawnninja/motionpaper:service all next

# Configure a slideshow interval (e.g. 300 seconds)
noctalia msg plugin lawnninja/motionpaper:service all slideshow 300

# Configure a shuffled slideshow interval (e.g. 300 seconds)
noctalia msg plugin lawnninja/motionpaper:service all slideshow-shuffle 300

# Run in-process self-checks
noctalia msg plugin lawnninja/motionpaper:service all self-test
```

## Notes

- Motionpaper starts one `gslapper` instance and a dedicated control socket under `$XDG_RUNTIME_DIR/noctalia-motionpaper/` for each output rendering a video.
- Stored configurations, cached thumbnail JPEGs, and library indices are kept safely in Noctalia's plugin data directory. Motionpaper performs no network calls.
- Static images leverage Noctalia's built-in wallpaper renderer. When a video is assigned, Motionpaper takes control of the output surface and re-enables the native surface upon stopping.

## Credits & Acknowledgements

Motionpaper is built upon and inspired by the original **gSlapper** wallpaper plugin created by **[Nomadcxx](https://github.com/Nomadcxx)** ([gSlapper](https://github.com/Nomadcxx/gSlapper) / [noctalia-gslapper](https://github.com/Nomadcxx/noctalia-gslapper)).

We extend special thanks and full credit to **Nomadcxx** for creating the lightweight C/GStreamer Wayland layer-shell daemon and the initial integration architecture that made this project possible.
