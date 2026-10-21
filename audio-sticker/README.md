# Audio Reactive Sticker

A desktop sticker that fades in while audio is playing and fades back out when
the playback stops, using a small PipeWire helper that watches output streams
instead of guessing from the default sink.

## Plugin

| Field | Value |
| --- | --- |
| ID | `miixz/audio-sticker` |
| Entries | Desktop widget: `sticker`; service: `monitor` |

## Requirements

The playback helper is built from source the first time the plugin runs, so a C
toolchain and the PipeWire development files must be installed:

- `cc` and `make` (any C toolchain)
- `pkg-config`
- `libpipewire-0.3` development headers (Arch: `pipewire`, Debian/Ubuntu:
  `libpipewire-0.3-dev`, Fedora: `pipewire-devel`, Void: `pipewire-devel`)
- `ffmpeg`, for animated GIF stickers (it also provides `ffprobe`)
- PipeWire running, with WirePlumber or any session manager that exposes the
  output streams as `Stream/Output/Audio` nodes
- Noctalia 5.0.0-beta.9 or newer (plugin API 24)

## Usage

Add the widget from **Settings → Desktop widgets** (or **Desktop** in the
Noctalia settings window) and pick **Audio Reactive Sticker** as its type, then
choose an image in the widget settings.

- While any application is actually playing audio, the sticker fades to
  **Active opacity**.
- When every output stream has stopped, it waits **Idle hysteresis** and fades
  to **Idle opacity**. With the default `0` the sticker disappears completely,
  which is what makes it a sticker rather than a permanent overlay.
- Paused players do not count: the helper looks at the PipeWire node state, so a
  stream that stays open but is not running keeps the sticker hidden.
- Add the widget more than once to decorate several outputs or positions. All
  instances share one monitor process.
- A GIF sticker animates only while it is visible. Frames are extracted once and
  cached, so the first use of a large GIF takes a moment.

## Settings

Desktop widget settings, per widget instance:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `image_path` | `file` | `""` | Sticker image: PNG, JPEG, WebP, SVG or animated GIF. |
| `active_opacity` | `double` | `1.0` | Opacity while audio plays, 0 to 1. |
| `idle_opacity` | `double` | `0.0` | Opacity while silent, 0 to 1. `0` hides the sticker. |
| `fade_ms` | `int` | `300` | Fade duration in milliseconds. `0` switches instantly. |

Plugin settings, shared by every sticker:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `hysteresis_ms` | `int` | `500` | Delay in milliseconds before fading out after the last stream stops. Changes apply the next time the helper starts (plugin reload). |

The opacity settings apply to the whole image, text and transparency included;
they are not a wallpaper mask.

## Notes

- On first run, and after an update that does not carry a binary, the service
  runs `make -C native` inside the plugin directory and builds
  `bin/noctalia-audio-monitor` from `native/audio-monitor.c`. That compiled file
  is the only write inside the plugin directory. If the build fails, the
  sticker shows an alert glyph with the reason and the compiler output goes to
  the Noctalia log.
- One long-lived helper process per session, started by the `monitor` service
  and restarted by a small shell loop if it exits. It writes and locks
  `$XDG_RUNTIME_DIR/noctalia-audio-monitor.pid`, so a second copy exits
  immediately, and it exits when the loop that started it goes away, so a
  reload never leaves an orphan behind. To debug node transitions, stop the
  plugin and run `bin/noctalia-audio-monitor --debug` yourself.
- The helper connects to the PipeWire registry as a normal client and reads node
  states only. It never opens a capture stream, so no audio is recorded,
  buffered or stored, and the plugin makes no network requests.
- Animated GIFs are decoded with `ffmpeg` and `ffprobe` into PNG frames under
  `pluginDataDir()/gif-cache/<image>/`, next to a `metadata.json` with frame
  durations. The cache is rebuilt when the source file's size or modification
  time changes, and it stays there until the plugin data directory is removed.
- Only `ffmpeg`/`ffprobe` (GIF stickers), `make` (first run) and the helper
  itself are ever spawned. Nothing else is executed.
