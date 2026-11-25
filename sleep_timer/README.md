# Sleep Timer

Shut the computer down after a set time, for falling asleep to music or a video. Set the
time with the mouse wheel on a small bar dial, drag a knob around a big dial in a panel,
or type hours and minutes. The bar widget, the panel and the Control Center tile always
show the same timer.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nid25/sleep_timer` |
| Entries | Bar widget: `sleep_timer`; panel: `panel`; shortcut: `tile` |

## Requirements

- `systemd-run` and `systemctl` from systemd, with a systemd user manager running. The
  timer is a transient user timer that runs `systemctl poweroff`, so the system must let
  your user power off without a password, which is the default on most desktop setups
  with logind and polkit while no other user is logged in.
- `python3` (3.9 or newer, standard library only) on Noctalia's `PATH`. It runs
  `companion.py`, which lets the panel's dial knob be dragged. Without it the panel still
  works through the hour and minute fields.

### NixOS

Noctalia does not install a plugin's dependencies, and on NixOS its `PATH` may not
contain them, especially when it runs as a systemd user service.

- **`python3` not found** (the knob cannot be dragged, `noctalia.log` shows a failed
  `python3` start): add it to Noctalia's `PATH` with Home Manager:

  ```nix
  programs.noctalia.extraPackages = [ pkgs.python3 ];
  ```

- **`systemd-run` or `systemctl` not found** (starting the timer shows an error): they
  come from the system's systemd in `/run/current-system/sw/bin`, which must be on
  Noctalia's `PATH`. Do not add `pkgs.systemd` to `extraPackages`: its tools may not
  match the running systemd.
- **Plugin missing after a rebuild:** if `programs.noctalia.settings.plugins.source` is
  set, it replaces the default sources. Add the source of this plugin to that list and
  `nid25/sleep_timer` to `plugins.enabled`.
- **Edits to a local copy do not show up:** give a `path` source an absolute string such
  as `"/home/me/src/noctalia-sleep-timer"`, not a Nix path like `./noctalia-sleep-timer`,
  which is copied into the store and frozen.
- **Plugin does not load:** it needs plugin API 52, Noctalia 5.5.0 or newer. If nixpkgs
  ships an older version, use the `github:noctalia-dev/noctalia` flake.

To check that your user may power off without a password, without changing anything:

```sh
busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff
```

It should print `s "yes"`. Errors from the plugin are in `~/.cache/noctalia/noctalia.log`.

## Usage

### Bar widget

Add the **Sleep Timer** widget to a bar in **Settings → Bar**. It shows the chosen time in
minutes inside a small dial.

- **Scroll** to change the time in 15-minute steps.
- **Left click** to start the timer.
- **Right click** to cancel a running timer.
- **Middle click** to open the panel.

While the timer runs, the dial counts down the remaining minutes in the accent color.

### Panel

Open it with a middle click on the bar widget, with the Control Center tile, or with:

```sh
noctalia msg panel-toggle nid25/sleep_timer:panel
```

- **Drag the knob** around the ring to change the time minute by minute. The knob grows
  while you hold it. Going past 12 o'clock adds or removes an hour.
- **Press anywhere on the ring** to move the knob there and keep dragging.
- **Scroll over the dial** to change the time in 15-minute steps.
- **Type hours and minutes** in the fields inside the dial, then press Enter or **Start**.
  Start always uses what the fields show: if they hold anything but digits or add up to
  zero, nothing starts and the hint under the dial turns red.
- **Cancel shutdown** stops a running timer.

The top row shows the current time and the time the computer will shut down.

### Control Center tile

Add **Sleep Timer** in **Settings → Control Center → Shortcuts**. Click it to open the
panel; right click starts the timer with the chosen time or cancels a running one. The
tile is highlighted and shows the remaining time while the timer runs.

### How the dials fill

Each lap of the ring is one hour. The first hour fills in the neutral color over dimmed
marks; the second hour fills in the theme's accent color over the first; the third in
the neutral color again, and so on. 2 h 30 min is two full laps plus half of a third.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `font_family` | `string` | `""` | Font for the numbers drawn on the bar and panel dials. Empty uses the shell font (`shell.font_family`), then `sans-serif`. |
| `dial_size` | `int` | `27` | Size of the bar dial in pixels, 12 to 64. The default fits the default bar; set it to your bar's capsule size if the dial looks too big or too small. |

## Notes

- **Commands:** starting runs
  `systemd-run --user --unit=noctalia-sleep-timer --collect --on-active=<N>s --timer-property=AccuracySec=1s systemctl poweroff`,
  cancelling runs `systemctl --user stop noctalia-sleep-timer.timer`, and while a timer
  runs the plugin checks every 30 seconds with
  `systemctl --user is-active noctalia-sleep-timer.timer` that it still exists.
- **Other schedules:** the plugin only starts and stops its own `noctalia-sleep-timer`
  unit. It never reads, replaces or cancels a shutdown or reboot scheduled with
  `shutdown` or by any other program, and such a schedule is not shown in the plugin.
- **Files:** the chosen minutes, the running timer's end time (`deadline`, with the boot
  it belongs to) and the generated dial images (SVG) are written to the plugin's data
  directory. Each entry keeps only its last two dial images and removes
  older ones, and all are removed when the widget or panel loads. The companion also
  creates `dial.sock` and `dial.sock.lock` there.
- **Process:** opening the panel starts `python3 companion.py <data dir>/dial.sock`. It
  serves a single transparent pixel through Noctalia's pixel stream protocol, because a
  pixel stream is the only panel control that reports pointer press, drag and release.
  It exits about five seconds after the panel closes. It does not use the network.
- **Network:** none.
- **Limits:** the timer runs from 1 minute to 23 h 59 min.
