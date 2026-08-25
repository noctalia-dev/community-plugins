# Oh My Pi Launcher

An interactive, native bar launcher button for [Oh My Pi (`omp`)](https://github.com/can1357/oh-my-pi) with real-time background session detection, recent project tracking, and one-click session resume.

## Plugin

| Field | Value |
| --- | --- |
| ID | `emiliovenegas/omp-launcher` |
| Entries | Bar widget: `omp-launcher` |

## Requirements

- `python3` on `PATH`.
- `omp` (Oh My Pi CLI) installed on `PATH`.
- `alacritty` (or a configured terminal) to launch interactive sessions.

## Usage

Place the widget on your bar in `~/.config/noctalia/config.toml` or `~/.local/state/noctalia/settings.toml`:

```toml
[bar.default]
center = [ "workspaces", "clock", "omp" ]

[widget.omp]
capsule = true
type = "emiliovenegas/omp-launcher:omp-launcher"
```

### Click Gestures

- **Left-Click**: Opens the interactive project picker via `vicinae dmenu` or terminal launcher.
- **Middle-Click**: Directly resumes the most recent project session (`omp --continue`).
- **Right-Click**: Launches a new OMP session in `$HOME` (`omp --allow-home`).

## Notes

- **Session Discovery**: Reads recent project timestamps from `~/.omp/agent/sessions/` to surface your active workspaces.
- **Active Detection**: Scans running local processes to display the active session glow dot.
- **Privacy**: No external network requests; all process and session checks run entirely on the local machine.
