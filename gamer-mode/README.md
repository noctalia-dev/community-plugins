# Gamer Mode

Live CPU, RAM, and GPU readings in the bar, plus a one-click mode that suspends
background resource hogs and restores what was running before.

> Requires Noctalia v5 and plugin API 19. Noctalia v4 uses a different QML
> plugin format and will not list or load this source.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nomadcxx/gamer-mode` |
| Entries | Bar widget: `gamermode`; panel: `main`; service: `service` |

## Requirements

- `pgrep` and `pkill` from procps probe and signal process targets
- `systemctl` controls service and timer targets
- `docker` controls container targets
- `powerprofilesctl` from power-profiles-daemon switches the power profile

Each tool matters only if you target that kind. Without `powerprofilesctl` the
panel hides its power row and the toggle still works.

## Usage

| Gesture | Action |
| --- | --- |
| Left-click | Opens the panel. Set **Left-click action** to `toggle` to toggle instead. |
| Right-click | Toggles gamer mode, whatever **Left-click action** says. |

The glyph takes the accent colour while gamer mode runs.

The tooltip carries the live readings:

```
CPU 25% 59°C | RAM 10.9G | GPU 18% 61°C | VRAM 2.5G
```

The panel shows a bar per reading, the power profile selector, the suspend
profile selector, what the plugin has suspended, and the maintenance actions.

Pick `light` or `heavy` in the panel and press Enable, and that profile applies
for the session. A plugin reads its own settings and cannot write them, so the
choice rides along with the enable rather than changing the **Gamer mode
profile** setting. While gamer mode runs the selector gives way to a label,
because the session already fixed the profile. To change it, disable first.

Drive it from a shell or a keybind:

```sh
noctalia msg plugin nomadcxx/gamer-mode:service all toggle
noctalia msg plugin nomadcxx/gamer-mode:service all enable
noctalia msg plugin nomadcxx/gamer-mode:service all disable
```

Toggle the panel:

```sh
noctalia msg panel-toggle nomadcxx/gamer-mode:main
```

### Maintenance

Three one-shot cleanups sit at the foot of the panel. None of them is part of
gamer mode, and turning gamer mode off does not undo any of them.

| Action | What it does | Needs a password |
| --- | --- | --- |
| Clear shader caches | Deletes the Mesa, NVIDIA `GLCache`, RADV, and Steam shader caches | No |
| Drop page cache | `sync`, then `vm.drop_caches=3` | Yes |
| Reclaim swap | `swapoff -a && swapon -a`, pulling swapped pages back into RAM | Yes |

Clearing shader caches takes two clicks. The first measures and the button
reports the size, the second deletes. Games recompile shaders on their next
launch, so that launch is slower. This is the one to reach for when a driver
update leaves stale shaders behind.

The plugin expands every cache path from a fixed list and drops any that
resolves outside your home directory, so the `rm` only ever sees the paths
above, and only those that exist.

Dropping the page cache frees the RAM the kernel uses to cache files. The kernel
refills it, and the pages it discards are ones it would otherwise have reused, so
this buys less than the number in `free` suggests.

Reclaiming swap only runs when what is swapped out fits in free RAM with a tenth
of total held back. Otherwise it reports that there is no room and does nothing,
because succeeding into an out-of-memory kill would defeat the point.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| Bar icon | `device-gamepad-2` | Glyph shown in the bar. Names a glyph from the shell's registry. |
| Left-click action | `open_panel` | Opens the panel or toggles gamer mode. Right-click toggles either way. |
| Poll interval | `3` | Seconds between metric updates: 2, 3, or 5. |
| Gamer mode profile | `light` | Selects which target profile a toggle applies. |
| Auto performance profile | On | Switches to the `performance` power profile while gamer mode runs, then hands back the previous one. |
| Show temperatures | On | Includes CPU and GPU temperatures in the tooltip and panel. |
| Suspend targets (JSON) | Empty | Replaces the built-in target list. See below. |

The setting names the profile a bar click applies. The panel selector overrides
it for the enable it is sent with, and the bar's right-click toggle does not see
that selection, so it uses the setting.

## Target list

`targets` takes a JSON array. Each entry needs a `match`, a `kind`, and the
`profiles` it belongs to. `action` is optional.

```json
[
  {"match": "awww-daemon",     "kind": "process",        "action": "freeze", "profiles": ["light", "heavy"]},
  {"match": "qbittorrent",     "kind": "process",        "action": "freeze", "profiles": ["light", "heavy"]},
  {"match": "ollama.service",  "kind": "system-service", "action": "stop",   "profiles": ["light", "heavy"]},
  {"match": "fstrim.timer",    "kind": "system-timer",   "action": "stop",   "profiles": ["light", "heavy"]},
  {"match": "brave",           "kind": "process",        "action": "freeze", "profiles": ["heavy"]},
  {"match": "jellyfin.service","kind": "system-service", "action": "stop",   "profiles": ["heavy"]}
]
```

An empty setting uses the built-in list: 173 entries, 94 of them in `light`.
Breadth costs almost nothing, because a target that is not running probes as
`down`, so the plugin never touches it and never restores it. An entry for
software you do not have costs one `pgrep`.

The plugin falls back to the built-in list when the setting holds invalid JSON or
when every entry in it fails validation, and logs the reason. It drops single bad
entries and honours the rest, so one typo costs you one target.

`match` compares through `pgrep -x`, so it needs the whole name. Substrings and
patterns do not match. The plugin quotes every value for the shell and refuses a
`match` holding a newline, carriage return, or NUL at parse time.

### Actions

`action` defaults to `stop`.

| | `stop` | `freeze` |
| --- | --- | --- |
| Mechanism | `pkill` / `systemctl stop` / `docker stop` | `SIGSTOP` / `docker pause` |
| Probes | read-only, never elevated | read-only, never elevated |
| Frees RAM | Yes | No, pages stay resident |
| Frees VRAM | Yes | No |
| Halts CPU use | Yes | Yes |
| Halts disk I/O | Yes | Yes |
| Keeps state | No, the target shuts down | Yes, the target resumes where it stopped |
| Restarts | Units, timers, and containers | Always |

Pick `freeze` for anything you return to: a browser, an editor, a wallpaper
daemon. Pick `stop` when you need the memory back. A local model runtime such as
`ollama` holds VRAM until the service stops, and freezing keeps every VRAM page
allocated, so those targets use `stop`.

Network connections drop while a target sits frozen. That suits a torrent client
and hurts a chat app.

### Kinds

| `kind` | Probe | `stop` | Start | `freeze` | Thaw |
| --- | --- | --- | --- | --- | --- |
| `process` | `pgrep -x` | `pkill -x` | none, see below | `pkill -STOP -x` | `pkill -CONT -x` |
| `user-service` | `systemctl --user is-active` | `systemctl --user stop` | `systemctl --user start` | `systemctl --user kill --kill-whom=all -s SIGSTOP` | same with `SIGCONT` |
| `system-service` | `systemctl is-active` | `pkexec systemctl stop` | `pkexec systemctl start` | `pkexec systemctl kill --kill-whom=all -s SIGSTOP` | same with `SIGCONT` |
| `user-timer` | `systemctl --user is-active` | `systemctl --user stop` | `systemctl --user start` | invalid | invalid |
| `system-timer` | `systemctl is-active` | `pkexec systemctl stop` | `pkexec systemctl start` | invalid | invalid |
| `container` | `docker inspect -f '{{.State.Running}}'` | `docker stop` | `docker start` | `docker pause` | `docker unpause` |

### Timers

Stopping `foo.service` leaves `foo.timer` free to fire it again five minutes into
your session, so scheduled work needs its own target. A stock Arch install
enables `fstrim.timer`, `smartd.timer`, `paccache.timer`, and the package-cache
timers, and each one stalls disk I/O mid-game.

The timer kinds require the `.timer` suffix on `match`. `systemctl is-active
fstrim` resolves to `fstrim.service`, so the plugin rejects a timer entry without
the suffix at parse time.

### Processes do not restart

`kind: "process"` has no start command. A bare process name carries no argv, no
environment, and no working directory, so the plugin cannot relaunch one. That
makes `process` with `action: "stop"` a one-way trip. The plugin allows it and
logs a warning, and every built-in process entry uses `freeze`. To get something
back, target the unit or container that supervises it.

### Protected targets

The plugin refuses some targets whatever the setting says, because stopping them
ends your session, kills your audio or network, or kills the game gamer mode
serves. It drops such an entry at parse time with a logged reason, and every
command builder refuses it again at action time, so a session file written by an
older version cannot act on one either.

```
session/display  niri hyprland sway river wayfire labwc gnome-shell kwin_wayland
                 plasmashell Xorg Xwayland greetd sddm gdm
the shell        noctalia quickshell
audio            pipewire pipewire-pulse wireplumber pulseaudio
core IPC         systemd systemd-logind dbus-broker dbus-daemon elogind
network          NetworkManager wpa_supplicant iwd systemd-networkd
game stack       steam steamwebhelper gamescope wine wineserver proton lutris
                 heroic bottles gamemoded
```

Matching ignores case and any `.service`, `.timer`, or `.socket` suffix, so
`Steam`, `steam`, and `steam.service` all fail. The list takes no override. A
wrong entry here costs you a dead session or a killed game, and an override field
is the one people copy from a forum post without reading. To act on one of these,
use Feral GameMode's `start=` and `end=` script hooks in `gamemode.ini`.

### System units ask for a password once

Stopping or starting a system unit needs authorisation. The plugin runs all the
units of one operation through a single `pkexec /usr/bin/systemctl` call, which
asks once and then does the whole batch as root.

Two simpler approaches were measured first and each cost a password prompt per
unit, seven units meaning seven dialogs:

- One `systemctl` per unit. polkit's `auth_admin_keep` retains an authorisation
  against the subject that gave it, and the subject systemd reports is the
  calling process, so seven processes are seven subjects with nothing to reuse.
- One `systemctl` naming all seven units. systemctl issues its `StopUnit` calls
  in parallel, so every polkit check is outstanding before any of them has an
  answer, and again nothing can reuse an authorisation that does not exist yet.

`org.freedesktop.policykit.exec` is `auth_admin` with no retention, so each
`pkexec` prompts. The built-in targets only ever stop system units and never
freeze them, so an enable costs one prompt and a disable costs one. A custom
target list that mixes stops and freezes pays one prompt per operation.

Without `pkexec` the plugin falls back to calling `systemctl` directly, which
still works through systemd's own polkit check at the cost of the prompt-per-unit
behaviour. It logs the downgrade at startup.

You need an authentication agent running for any prompt to appear. Most desktops
start one; standalone compositors often do not. Check with:

```sh
pgrep -af 'polkit.*agent'
```

If nothing is listed, install one such as `mate-polkit`, `polkit-gnome` or
`hyprpolkitagent` and start it with your session. Without an agent the calls fail
and each one is logged.

To skip the prompt entirely, grant the units you target. Scope the rule to those
units: a blanket rule lets anything running as you stop or start any system unit.
In `/etc/polkit-1/rules.d/49-gamermode.rules`:

```javascript
polkit.addRule(function (action, subject) {
    var units = ["sonarr.service", "radarr.service", "fstrim.timer"];
    if (action.id == "org.freedesktop.systemd1.manage-units"
        && subject.isInGroup("wheel")
        && units.indexOf(action.lookup("unit")) >= 0) {
        return polkit.Result.YES;
    }
});
```

## Targets left out of the built-in list

Each of these suits someone and makes a poor default. Paste what you want into
`targets`.

**Voice chat.** Freezing these cuts voice during the activity the plugin serves.

```json
{"match": "discord", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "vesktop", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "slack", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "element-desktop", "kind": "process", "action": "freeze", "profiles": ["heavy"]}
```

**Music.** Plenty of people game with music playing.

```json
{"match": "spotify", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "spotifyd.service", "kind": "user-service", "action": "stop", "profiles": ["heavy"]},
{"match": "mpd.service", "kind": "user-service", "action": "stop", "profiles": ["heavy"]}
```

**Recording and streaming.** Plenty of people stream the game they play.

```json
{"match": "obs", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "gpu-screen-recorder", "kind": "process", "action": "freeze", "profiles": ["heavy"]}
```

**Language runtimes.** `java`, `dotnet`, and `node` burn CPU, and they run games
too. Minecraft and every PrismLauncher or MultiMC instance runs as `java`. Unity
and .NET titles run as `dotnet`. Freezing those freezes the game. Add them only
if nothing you play uses them.

**Container and VM daemons.** Stopping `docker.service` takes down every
container, and starting it again leaves their previous states behind. Stopping
`libvirtd` kills running guests. Target single containers with
`kind: "container"`, which pauses and unpauses through the cgroup freezer.

**Shared databases.** Other services tend to depend on `postgresql`, `mysqld`,
and `redis`. The built-in `heavy` profile does cover `elasticsearch` and
`opensearch`, whose JVM heaps often top the RAM table on a development box.

**VRAM without stopping the daemon.** `ollama` unloads models while staying up.
No target kind covers this, so use a Feral GameMode hook:

```ini
[custom]
start=/usr/bin/ollama stop --all
```

## Restore semantics

Enabling writes a session snapshot to the plugin data directory
(`session.json`). For every target in the active profile it records whether the
target was `running` or `active` or already down, which `action` applied, the
power profile in effect, and the kernel boot ID.

The snapshot lands on disk before anything is suspended. It is the only record
of what was running beforehand, so a target suspended without one is
unrecoverable: disable would read the session, find none, and return. If the
write fails, enabling stops there with the machine untouched and tells you why.

Disable runs two passes, because the two actions need different logic.

The plugin probes each **`stop` target** again and starts it back when it is
still down. So it leaves alone anything you stopped before enabling gamer mode,
and anything you restarted by hand while gamer mode ran. It logs and skips a
missing unit or container, and never fails hard partway.

The plugin thaws every **`freeze` target** without probing. A frozen process
still appears in `pgrep`, so no probe distinguishes "still frozen" from
"running", and `SIGCONT` to a process that is not stopped exits 0 and changes
nothing. Thawing blind beats probing here: it cannot misread a state, cannot
stomp a manual restart, and cannot leave something frozen after a probe fails to
run.

The snapshot sits on disk, so gamer mode survives a shell restart. Reload
Quickshell mid-session and the panel still reports it as on with the same suspend
list, and disable still restores.

Enabling twice does nothing. A second enable would re-probe and record the
targets it had suspended as "was down", losing what it needs to restore them.

### After a reboot

A session file outlives a reboot, so the plugin compares the boot ID at startup.
A different ID means the session went stale: nothing that was frozen still
exists, and units that were stopped may have come back on their own.

A stale session gets a full restore pass before the plugin clears it. A stopped
unit that is not `enabled` is still down after a reboot, and putting it
back is what you were told would happen. Frozen targets died with the reboot, so
their thaw does nothing. This can fire a few `systemctl start` calls
soon after login, and the plugin logs each one.

Within the same boot the plugin always keeps the session, even when everything
looks like it is running, because that is the case where something may still sit
frozen and need thawing. A session written before version 0.2.0 carries no boot
ID, and the plugin treats it as current so it does not abandon targets that may
still be suspended.

## Notes

- The plugin stores its session snapshot in Noctalia's plugin data directory. It
  makes no network requests.
- `renice` is absent by design. It looks like the safe middle ground and is not.
  With `RLIMIT_NICE=0`, the default, an unprivileged process lowers priority and
  never raises it back, so a renice would degrade every process it touched for
  the life of that process. `freeze` gives you the reversible option instead.
  Feral GameMode needs membership in a `gamemode` group to renice at all for the
  same reason.
- No I/O weighting for user units. cgroup v2 delegates `cpu`, `memory`, and
  `pids` to the user manager, and not `io`.
- The bar widget carries the readings in its tooltip. Plugin API 19 does hand a
  widget `onHover(entered)`, so a richer hover surface is possible and is not
  built.
- The panel shows no per-core CPU breakdown and no top-process list.
- Nothing places the widget on your bar for you. The manifest has no field for a
  default bar section, and a plugin can read its settings but not write them, so
  bar layout stays yours. Add it under **Settings → Bar**.
- VRAM appears where the shell reports it, which means NVML on NVIDIA.
- The plugin toggles no compositor effects. Animations, blur, and shadows belong
  to your compositor's own config.
- Feral GameMode exposes a `ClientCount` property that emits changes and a
  `GameRegistered` signal on `com.feralinteractive.GameMode`, and `org.scx.Loader`
  switches sched_ext schedulers. Arming gamer mode from either one would work and
  is not built.

## License

MIT
