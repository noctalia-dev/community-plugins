# Oh My Pi Launcher

An interactive, native bar launcher button for [Oh My Pi (`omp`)](https://github.com/can1357/oh-my-pi) with real-time background session detection, recent project tracking, and one-click session resume.

## Plugin

| Field | Value |
| --- | --- |
| ID | `emiliovenegas/omp-launcher` |
| Entries | Bar widget: `omp-launcher` |

## Requirements

- `omp` (Oh My Pi CLI) on `PATH`.
- `python3` on `PATH`.

A graphical dmenu (vicinae) is used when available. If absent the widget falls back automatically through: `alacritty` → `kitty` → `ghostty` → `foot` → `xdg-terminal-exec`. At least one terminal emulator must be installed for left-click to work.

## Usage

Place the widget on your bar in `~/.config/noctalia/config.toml`:

```toml
[bar.default]
end = [ "...", "omp-launcher", "..." ]

[widget.omp-launcher]
type = "emiliovenegas/omp-launcher:omp-launcher"
capsule = true
```

### Click gestures

- **Left-click** — opens the interactive project picker (vicinae dmenu or terminal fallback).
- **Middle-click** — resumes the most recent project session directly (`omp --continue`).
- **Right-click** — launches a new session in `$HOME` (`omp --allow-home`).

The capsule glows and shows a live dot while any `omp` session is active.

## Notes

- **Session discovery**: reads recency timestamps from `~/.omp/agent/sessions/`.
- **Active detection**: scans local processes — no network calls, no external services.
- **Privacy**: every process and session check runs entirely on the local machine.
