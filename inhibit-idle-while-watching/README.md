# Inhibit Idle While Watching

Keeps your session awake while you are sitting in front of the camera. When
Noctalia's idle chain is about to act (dim, screen-off, lock), this plugin
captures one webcam frame, looks for a face, and on a face restarts the idle
countdown with one synthetic input tap — a gate, not a daemon: nothing is
held, no timer is kept. Walking away (or looking away) lets the normal idle
chain proceed, silently and exactly as configured.

## Plugin

| Field | Value |
| --- | --- |
| ID | `zhangdm/inhibit-idle-while-watching` |
| Entries | Service: `face-watch` |

## Requirements

- `noctalia`, `python3`, `ffmpeg`, `v4l2-ctl`, `wtype` on `PATH` (all in
  `dependencies`).
- Python module for the helper: `cv2` (OpenCV, e.g. `python-opencv`). The `dnn`
  detector additionally needs `assets/face-dnn.onnx` (not bundled — see
  *Detectors* under Notes).
- A V4L2 webcam. The idle handshake below is compositor-agnostic (Noctalia owns
  idle); the reset path is verified on umbriel (and Niri before it).

## Usage

The plugin cannot observe idle by itself (the plugin API has no idle hook), so
it is triggered by a Noctalia idle behaviour that messages it. Add a **command**
idle behaviour that fires a few seconds *before* the first action you want
postponed — example for postponing `dim` at 50 s:

```toml
# ~/.local/state/noctalia/settings.toml (or ~/.config/noctalia/config.toml)
[idle.behavior.presence-check]
action = "command"
command = "noctalia msg plugin zhangdm/inhibit-idle-while-watching:face-watch all idle-begin"
timeout = 45.0
```

The lead matters: the reset tap must land before the next behaviour's timer
expires, and a check costs about a second end-to-end (measured ~0.3 s capture +
~15 ms Haar on a 640px frame; `robust` mode adds one more capture). A
`timeout` equal to the behaviour you are
postponing loses that race every time — that action has already fired by the
time the face is detected.

Then `noctalia msg config-reload`. On each trigger the plugin captures one
frame per selected camera (see *Camera modes*; `robust` = both sensors); with
a face present it sends one synthetic Shift tap (`wtype`), which
reads as user activity: the shell re-arms every idle behaviour and restarts
the countdown, so the check fires again on the next `timeout` while you keep
watching. Without a face nothing happens and your dim/screen-off/lock chain
runs untouched.

Manual control:

```sh
noctalia msg plugin zhangdm/inhibit-idle-while-watching:face-watch all status  # log current state
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `bool` | `true` | Master switch; off means the camera is never touched. |
| `camera_path` | `string` | `""` | Explicit video device such as `/dev/video2`; when set it **overrides `camera_mode`** (one camera, no probing). Empty = pick by mode. |
| `camera_mode` | `select` | `"robust"` | `rgb`, `ir`, `smart` or `robust` — which sensor(s) one check uses. See below. |
| `ir_threshold_lux` | `int` | `10` | `smart` only: below this ambient lux the IR camera is used (slider, 0…200). |
| `detector` | `select` | `"haar"` | `haar` (cheap) or `dnn` (accurate, needs the ONNX model). |
| `sensitivity` | `int` | `5` | 1 lenient … 10 strict. |
| `capture_width` | `int` | `640` | Frame width per check (height 4:3); detection downscales to 320 px. |
| `cooldown_s` | `int` | `10` | Minimum seconds between gate runs (camera wake-up cap). |
| `debug_log` | `bool` | `false` | Helper activity log in the plugin data dir (verdicts, never images). |

### Camera modes

A webcam may carry two sensors — visible-light (RGB) and infrared (IR). The
IR/RGB split is discovered per device node (`v4l2-ctl` `Card type`; the
top-level device listing groups both sensors under one header). Measured
2026-10-24 on a combo ASUS unit in a dark room: the IR node detected the face
with both detectors (Haar 3/3, DNN 3/3) while the RGB frames were black.

| Mode | Behaviour |
| --- | --- |
| `rgb` | Visible-light sensor only (the classic behaviour). |
| `ir` | Infrared sensor only — the dark-room watching mode. |
| `smart` | Reads the ambient light sensor before the check: below `ir_threshold_lux` → `ir`, at/above → `rgb`. Unreadable sensor → falls back to `robust`; if the chosen sensor is missing on this machine the other one is used (the check never silently stops). |
| `robust` (default) | Checks **both** sensors; a face on **either** keeps the session awake (OR). Degrades to whatever sensors the machine has. |

In `robust`, presence = `face(rgb) OR face(ir)`; if neither saw a face but one
camera failed, the verdict is `error` (never a lying `no_face`) and no tap is
sent. Verdicts name the sensors involved: `face (1) [ir]`, `no_face [rgb,ir]`,
`error [ir]`, `locked [rgb]`. `smart` decides per check, so it follows you
from a lit desk into a dark room without reconfiguration.

## IPC

```sh
noctalia msg plugin zhangdm/inhibit-idle-while-watching:face-watch all <event> [payload]
```

| Event | Effect |
| --- | --- |
| `idle-begin` | Run the presence gate (this is what the idle behaviour above sends). |
| `status` | Append the helper's status file to the log for debugging. |

## Security

This plugin sees a webcam image — the most sensitive data on the desk. Threat
model and guarantees:

- **Image lifetime:** one frame per camera per check, captured by `ffmpeg`
  straight into a stdout pipe, decoded in RAM (`cv2.imdecode`), and dropped
  when the check ends. There is **no code path that writes a frame to disk**
  (checked including debug and error paths). The camera activity LED lights
  during every RGB capture — that is hardware, and it is your visible signal
  (whether the IR sensor drives an LED is unverified on this host).
- **What is persisted:** `face-watch-status.json` (state, a verdict string such
  as `face (1) [ir]`, per-camera verdicts, mode, check count, timestamps) and
  — only with `debug_log = true` —
  `face-watch.log` (camera path and one-line verdicts). Neither contains image
  data. Both live in the plugin data directory, are written with mode `0600`
  (`O_NOFOLLOW`), and tighten any pre-existing looser file.
- **No capture while locked — fail closed:** the privacy gate captures only on
  an *explicit* "unlocked" from `noctalia msg status`. A lock screen, a missing
  or malformed status answer, or a schema drift all refuse capture ("skipped").
  The lock is checked at spawn (service side, also fail-closed), at check
  start, and again immediately before each frame is taken — every camera of a
  multi-camera check re-gates independently. What is guaranteed:
  capture is never *started* while the session is locked or its state unknown.
  A capture already in flight when the session locks cannot be cancelled
  mid-frame — that single frame still follows the image-lifetime rule above
  (RAM only, dropped with the check).
- **The tap never reaches a lockscreen:** synthetic input on a lockscreen
  would wake it, so the lock state is re-checked one last time immediately
  before the `wtype` tap — after capture and detection, which can span up to
  ~15 s during which the session can lock. Locked or unknown at that moment
  refuses the tap (the gate then reports `locked`/`skipped`) and the
  configured idle chain proceeds untouched.
- **Ambient light reading (smart mode):** exactly one sysfs scalar
  (`in_illuminance_raw` × `in_illuminance_scale`) is read before any capture to
  choose the sensor; nothing else about the environment is sampled, and the
  value is only kept in the status file when smart mode used it.
- **No shell, fixed binaries:** `ffmpeg`, `v4l2-ctl`, `wtype` and `noctalia`
  are invoked with argument lists (never through a shell). Settings such as
  `camera_path` are passed as discrete arguments; there is no string
  interpolation into a command line. Defaults come from `v4l2-ctl`
  autodetection (`/dev/videoN` only).
- **Two failure postures, deliberately different:** the *privacy gate* fails
  closed (above); the *chain* fails open — any check error, a missing detector
  asset, or a lock means no tap, and the configured idle chain proceeds
  untouched. A broken camera can never keep the session awake.
- **Poke scope:** on a confirmed face the plugin sends exactly one synthetic
  Shift tap (`wtype -M shift -m shift`) — a bare modifier, so nothing is typed
  into applications. Synthetic input is still real input: it can affect drag
  states or game keybinds (low but nonzero). The tap is what re-arms the idle
  chain (see *Notes*); the alternative pokes were measured and cannot.
- **Detector weights:** `assets/face-dnn.onnx` is fetched, not bundled, and is
  **pinned by sha256** — only the exact reviewed `version-RFB-320.onnx`
  (upstream MIT repository in *Notes*) loads; anything else is refused before
  reaching OpenCV's ONNX parser.

Known limits: a local attacker with your user's privileges can read the same
camera; the plugin cannot defend against that.

## Notes

- **What "presence" means:** a face *toward the camera*. Measured 2026-10-22 at
  reclined desk distance: facing the screen is detected 12/12 (Haar, YuNet and
  the DNN model agree); looking down at a phone is missed by all three (the
  camera sees mostly the top of the head). By design a look-away means no tap —
  this plugin inhibits idle while you are *watching*, not merely occupying the
  chair.
- **Why a synthetic tap (measured 2026-10-22, umbriel):** only real input takes
  the shell's `resumed` path that re-arms a *fired* idle behaviour. A caffeine
  inhibit/release pair restarts the timers but leaves the fired behaviour spent
  (no re-fire within 90 s); inhibitor holds need a daemon. The tap re-arms
  everything and the check fires again at the next `timeout`.
- **Timing:** the check fires at `timeout` **plus Noctalia's global
  `pre_action_fade_seconds`**, and any input during that fade cancels the whole
  idle chain. With the default 30 s fade the camera only wakes at 75 s of
  perfect stillness; set `pre_action_fade_seconds = 0` for a check at exactly
  `timeout`.
- **Detectors:** `haar` (default, no assets needed) or `dnn`
  (`assets/face-dnn.onnx`, Ultra-Light-Fast-Generic-Face-Detector-1MB
  `version-RFB-320.onnx`, MIT — drop the file in to enable; detections are
  counted after non-maximum suppression).
- **Privacy:** see *Security* above (image lifetime, persistence, lock guard).
- **Power:** one short capture+detect per selected camera (~0.5 s each; the
  `robust` default runs two) plus one
  `wtype` call per confirmed face; never a continuous stream, no polling loop,
  no process outlives the check. Tune `capture_width` to taste.
- **What is spawned and written:** the service spawns `python3 face-watch
  gate …` (which runs `ffmpeg`, `v4l2-ctl`, `wtype`, `noctalia msg status`);
  the helper writes `face-watch-status.json` and, with `debug_log`,
  `face-watch.log` in the plugin data directory. No network access.
- **Failure mode is fail-open:** any capture/detect error means no tap and the
  idle chain proceeds — a broken camera never keeps the session awake.
