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
- `pgrep` on `PATH`.
- `bash` on `PATH`.

The bundled launcher script (`omp-launch`) dynamically uses a graphical dmenu (`vicinae`, `fuzzel`, `rofi`, `wofi`, `bemenu`, or `dmenu`) when available. If no dmenu is present, it falls back to your terminal emulator (`$TERMINAL`, `xdg-terminal-exec`, `alacritty`, `kitty`, `ghostty`, `foot`, `wezterm`, `gnome-terminal`, `konsole`, or `xterm`).

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

- **Left-click** — opens the interactive project picker (dmenu or terminal fallback).
- **Middle-click** — resumes the most recent project session directly (`omp --continue`).
- **Right-click** — launches a new session in `$HOME` (`omp --allow-home`).

The capsule glows with an active session indicator dot whenever an `omp` session is running.

## Notes

- **Session discovery**: reads project recency timestamps from `~/.omp/agent/sessions/`.
- **Active detection**: scans local processes with `pgrep` every 10 seconds.
- **Privacy**: no external network requests; all checks and launcher operations run entirely on the local machine.
