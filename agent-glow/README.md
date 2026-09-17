# Agent Glow

Make the desktop show when your coding agents are busy: a dim spark in the bar
that lights up with the number of working sessions, a breathing glow on the
wallpaper, and a panel listing which agents are working and where.

## Plugin

| Field | Value |
| --- | --- |
| ID | `fel/agent-glow` |
| Entries | Service: `watcher`; bar widget: `indicator`; desktop widget: `glow`; panel: `status` |

## Requirements

Install `python3` on `PATH`. The service spawns it once per poll to sample
process CPU and read agent session data; when it is missing the service stays
silent and the widgets simply report idle.

Agent activity is detected from `/proc` plus whatever session data is present
on the machine, so no compositor-specific tooling is required. The
`opencode` and `claude` session collectors light up only if those agents'
local data exists (`~/.local/share/opencode/opencode.db` and
`~/.claude/projects/`).

## Usage

Add the **Agent Glow** bar widget from the bar's Add-widget picker:

- **Idle** — a dim grey spark, with the number of live agent sessions if any
  are running (turn that off with *Show in bar when idle*).
- **Working** — a lit accent spark showing how many sessions are active.
- **Hover** — lists the hot sessions with their project and age.
- **Left click** — opens the session panel.

Add the **Agent Glow** desktop widget to place the glow on the wallpaper; it
pulses while agents work and rests as a dim ring when they are idle.

Toggle the panel from anywhere:

```sh
noctalia msg panel-toggle fel/agent-glow:status
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Agent processes | `string` | `opencode,claude,codex,gemini,aider,goose` | Comma-separated process-name fragments to watch. Match is OR, case-insensitive. |
| Poll interval | `int` | `2` | Seconds between samples (1–30). Lower reacts faster and costs a little more CPU. |
| Session freshness | `int` | `120` | Seconds a session stays "working" after its transcript or database entry was last touched (15–900). |
| Heartbeat memory | `int` | `45` | Seconds a family stays lit after an external activity heartbeat (5–300). |
| CPU fallback threshold | `int` | `15` | Only for agent types without session data: percent of one core its process tree must burn to count as working (1–200). `100` = one full core. |
| Pulse speed | `select` | `Normal` | How fast the desktop glow breathes: `Slow`, `Normal`, or `Fast`. |
| Notify on change | `bool` | off | Send a notification when agents start or stop working. |

Each bar widget instance also has:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Show in bar when idle | `bool` | on | Keep the dim spark visible when nothing is running. When off, the tile only appears while agents work. |

## Notes

- No network access. Everything is read locally.
- Processes spawned: one `python3` per poll for the service, and the agent
  processes the plugin only observes. The wallpaper frames are pre-rendered
  PNGs shipped in `frames/`; `frames.sh` is the ImageMagick script that made
  them at packaging time and is not run by the plugin.
- Files read: `/proc` (CPU and command lines), `~/.claude/projects/`
  transcripts, `~/.local/share/opencode/opencode.db` (read-only), and
  `$XDG_RUNTIME_DIR/agent-glow.<family>.hb` heartbeat files.
- Files written: `$XDG_RUNTIME_DIR/agent-glow-activity.json` (mode `0600`), a
  cache of the previous `/proc` sample — per-pid CPU ticks, parent pid, and the
  matched agent family, **never command lines** — plus session names. It is
  written only when `XDG_RUNTIME_DIR` is set; without it the probe persists
  nothing rather than drop a cache into a shared directory.
- Session titles and working directories are kept in the plugin's in-memory
  shared state and the cache above so the bar tooltip and panel can show them.
  Nothing leaves the machine.
- `claude` detection joins live `claude --resume <uuid>` processes to their
  transcript; the session name is the first user message of that transcript.
- An agent family can also report activity by touching
  `$XDG_RUNTIME_DIR/agent-glow.<family>.hb` (for example from an agent hook);
  it stays lit for *Heartbeat memory* seconds after the last touch.
