# Hyprmodoro

A pomodoro timer for your Noctalia bar, driven by
[hyprmodoro](https://github.com/luccaugusto/hyprmodoro) — the Hyprland plugin that paints a countdown
onto your window titles. This adds the parts it has no UI for: a countdown in the bar, transport
controls and a work-rest switch in a panel, a Control Center tile, presets and custom durations, and
a settings screen for every hyprmodoro option.

## Plugin

| Field | Value |
| --- | --- |
| ID | `aceix/hyprmodoro` |
| Entries | Bar widget: `bar`; panel: `panel`; shortcut: `shortcut`; services: `control`, `writer` |

## Requirements

- `hyprctl` on `PATH`.
- The **hyprmodoro** Hyprland plugin, installed from
  [Aceix/hyprmodoro](https://github.com/Aceix/hyprmodoro):

  ```sh
  hyprpm add https://github.com/Aceix/hyprmodoro
  hyprpm enable hyprmodoro && hyprpm reload
  ```

  That build adds the `hyprctl` commands this plugin needs to start and pause the timer. Upstream
  hyprmodoro works too, but only if your Hyprland uses the older `hyprland.conf` format — on a Lua
  config its controls cannot be reached from outside, and the plugin will say so and stay in a
  display-only mode.

## Usage

**Bar widget** — add it in Settings → Bar. It shows an hourglass while idle and the remaining time
during a session, coloured by phase and dimmed when paused.

- Left click opens the panel.
- Right click starts, or pauses and resumes.
- Scroll to change the work duration a minute at a time, while the timer is stopped.

**Panel** — the remaining time, the phase and round, a progress bar, and:

- **Start / Pause / Resume**, **Reset**, **Stop**.
- **Work | Rest** to switch phase. Only available during a session.
- **Presets** — click a `work/rest` pair. Edit the list in the settings.
- **Custom** — type a work and rest length in minutes, press **Set**.
- **Link into hyprland.lua** and **Save now** for the settings file (see below).

```sh
noctalia msg panel-toggle aceix/hyprmodoro:panel
```

**Control Center tile** — add it in Settings → Control Center. Left click starts or pauses, right
click stops, and the label shows the countdown.

## Setup

After installing, press **Link into hyprland.lua** in the panel once.

Your settings are written to `~/.config/hypr/hyprmodoro.lua`, and Hyprland only reads that file if
your config requires it. That button adds the one line needed, after backing your config up, and
does nothing if the line is already there.

## Settings

Settings → Plugins → Hyprmodoro. The first group is about this plugin; everything below it is
hyprmodoro's own options, written to the settings file.

| Setting | Default | What it does |
| --- | --- | --- |
| Settings file | `~/.config/hypr/hyprmodoro.lua` | Where your options are written. Use a `.conf` path if your Hyprland still uses `hyprland.conf`. |
| Manage the settings file | on | Turn off to stop the plugin writing it, and configure hyprmodoro by hand. |
| Defer writes while a session runs | on | Saving reloads Hyprland, which restarts a running timer. Leave this on and changes wait for the session to end; **Save now** applies immediately. |
| Presets | `25/5, 50/10, 90/20, 15/3` | Work/rest pairs in minutes. The first six appear in the panel. |
| Poll intervals | 1s / 5s | How often the timer is read while running, and while idle. |
| Bar icon, show duration when idle | | How the widget looks when nothing is running. |
| Enable hyprmodoro | on | hyprmodoro's master switch. Off hides its timer from your windows. |
| Work / rest duration | 25 / 5 | Minutes. The defaults a session starts with. A preset overrides them until Hyprland next reloads. |
| Auto-transition | on | Roll straight into the next session instead of waiting. |
| Border colour source | Derived from accent | Picks a high-contrast border colour from your hyprtoolkit accent, refreshed whenever Hyprland reloads. Switch to **Custom** to choose one yourself. |
| Title, border, text, buttons, hover, window | | How hyprmodoro draws on your windows: position, colours, font, prefixes, the hover area, and which windows it appears on. |
| Sounds | `pw-play` | A player command and two sound files. Sounds only play when all three are set. |
| Notifications | on | Messages at the end of each phase, through your system notifications or Hyprland's own. |
| Run on work / rest end | empty | Commands to run when a phase ends, separated by semicolons. |

## Keybinds

Every control is reachable without the widget, so you can bind it:

```sh
noctalia msg plugin aceix/hyprmodoro:control all start
noctalia msg plugin aceix/hyprmodoro:control all pause
noctalia msg plugin aceix/hyprmodoro:control all stop
noctalia msg plugin aceix/hyprmodoro:control all reset
noctalia msg plugin aceix/hyprmodoro:control all skip
noctalia msg plugin aceix/hyprmodoro:control all to_work
noctalia msg plugin aceix/hyprmodoro:control all to_rest
noctalia msg plugin aceix/hyprmodoro:control all set_work 50
noctalia msg plugin aceix/hyprmodoro:control all preset 50/10
```

In `hyprland.lua`:

```lua
hl.bind("SUPER, P", hl.dsp.exec_cmd("noctalia msg plugin aceix/hyprmodoro:control all pause"))
```

## Notes

**What it touches.** The plugin runs `hyprctl` and nothing else — to read the timer, to control it,
and to apply settings. It writes your settings file, and, only when you press **Link into
hyprland.lua**, one line in your Hyprland config plus a dated backup of it alongside. No network
access.

**Presets don't persist.** They apply straight away but last until Hyprland next reloads its config,
which resets the durations to the ones in your settings. Change *Work duration* and *Rest duration*
for a new default.

**Changing settings reloads Hyprland.** That is how the settings file takes effect, and it restarts a
running timer — which is why writes wait for the session to end unless you press **Save now**.

**Hyprland only.** hyprmodoro is a Hyprland plugin. Tested on Hyprland v0.56.x.

## Troubleshooting

**"hyprmodoro not loaded"** — the Hyprland plugin isn't running:
`hyprpm enable hyprmodoro && hyprpm reload`, then press **Check again** in the panel.

**"Controls unavailable"** — the timer displays but the buttons are inactive. Install hyprmodoro from
[Aceix/hyprmodoro](https://github.com/Aceix/hyprmodoro); `hyprctl hyprmodoro:version` should print
`1`.

**Hyprland complains about the settings file** — check it directly:

```sh
luac -p ~/.config/hypr/hyprmodoro.lua
hyprctl getoption plugin:hyprmodoro:work_duration     # expect "set: true"
```
