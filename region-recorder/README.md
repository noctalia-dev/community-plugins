# Region Recorder

A minimal, high-performance Noctalia plugin for region screen recording with interactive `slurp` selection.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h-jangra/region-recorder` |
| Entries | Bar widget: `widget`; shortcut: `toggle`; service: `service` |

## Requirements

- `slurp`
- At least one recorder engine: `gpu-screen-recorder`, `wl-screenrec`, or `wf-recorder`
- `ffmpeg`

## Usage

### Bar Widget & Shortcut

- **Bar Widget (`widget`)**: Add `h-jangra/region-recorder:widget` to your bar items in Noctalia settings to select a region and start recording.
  - **Left Click**: Toggle region selection / recording.
  - **Right Click**: Start full-screen recording directly or stop active recording.
- **Control Center Shortcut (`toggle`)**: Add `h-jangra/region-recorder:toggle` to your control center quick tiles for one-tap region recording.
  - **Left Click**: Toggle region recording mode.
  - **Right Click**: Start full-screen recording or stop active recording.

### IPC Commands

Control the region recorder service directly via IPC:

```sh
# Toggle region recording
noctalia msg plugin h-jangra/region-recorder:service all toggle

# Start region selection recording explicitly
noctalia msg plugin h-jangra/region-recorder:service all select-region

# Start fullscreen recording explicitly
noctalia msg plugin h-jangra/region-recorder:service all record-fullscreen

# Stop active recording
noctalia msg plugin h-jangra/region-recorder:service all stop
```

## Settings

Configure Region Recorder in **Noctalia Settings → Plugins → Region Recorder**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `video_source` | `select` | `region` | Default source mode for recording (`region`, `focused`, `portal`). |
| `directory` | `folder` | `~/Videos/Recordings` | Directory where recorded video files are saved. |
| `filename_pattern` | `string` | `recording_%Y%m%d_%H%M%S` | Strftime format string for output file names. |
| `frame_rate` | `int` | `60` | Target framerate (FPS) for recording (`1` – `240`). |
| `framerate_mode` | `select` | `cfr` | Framerate mode (`cfr`, `vfr`, `content`). `cfr` (Constant Frame Rate) is editor-friendly and required by editors like Kdenlive. |
| `video_codec` | `select` | `h264` | Video encoding codec (`h264`, `hevc`, `av1`). |
| `audio_source` | `select` | `none` | Audio stream to record (`none`, `default_output`, `default_input`, `both`). |
| `show_cursor` | `bool` | `true` | Include mouse cursor in the screen recording. |
| `copy_to_clipboard` | `bool` | `false` | Copy `file://` path URI to clipboard when recording completes. |
| `hide_inactive` | `bool` | `false` | Hide the bar widget when not actively selecting or recording. |

## Notes

- **Process Management**: Recording processes receive `SIGINT` on stop to ensure MP4 video files are properly finalized and playable.
- **Window Snapping**: When `slurp` is invoked on Hyprland or Sway, window boundaries are queried via `hyprctl` / `swaymsg` to enable snapping to individual windows.

## License

MIT © [Himanshu Jangra](https://github.com/h-jangra)
