# Oh My Pi Launcher

An interactive, native bar launcher button and dropdown session manager for [Oh My Pi (`omp`)](https://github.com/can1357/oh-my-pi) with real-time background session detection, multi-state telemetry pulse, recent workspace tracking, and one-click session resume.

## Plugin

| Field | Value |
| --- | --- |
| ID | `emiliovenegas/omp-launcher` |
| Entries | Bar widget: `omp-launcher`; Panel: `panel` |

## Requirements

- `omp` (Oh My Pi CLI) on `PATH`.
- `python3` on `PATH`.
- `pgrep` on `PATH`.
- `bash` on `PATH`.

The bundled launcher script (`omp-launch`) dynamically uses a graphical dmenu (`vicinae`, `fuzzel`, `rofi`, `wofi`, `bemenu`, or `dmenu`) when available. If no dmenu is present, it falls back to your installed terminal emulator (`$TERMINAL`, `xdg-terminal-exec`, `alacritty`, `kitty`, `ghostty`, `foot`, `wezterm`, `gnome-terminal`, `konsole`, or `xterm`).

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

- **Left-click** — opens the interactive **Oh My Pi dropdown panel** with live active sessions, recent workspaces, and quick actions.
- **Middle-click** — resumes the most recent project session directly in a terminal (`omp --continue`).
- **Right-click** — launches a fresh session in `$HOME` (`omp --allow-home`).

The capsule dot lights up in **Sky Blue** (`#38BDF8`) while OMP is thinking / executing tools, switches to **White** (`#FFFFFF`) when waiting for user input, and turns off when idle.

### Panel IPC

You can toggle the interactive dropdown panel directly via keybind or script:

```sh
noctalia msg panel-toggle emiliovenegas/omp-launcher:panel
```

## Notes

- **Session discovery**: reads project recency timestamps from `~/.omp/agent/sessions/`.
- **Active detection**: scans running local processes with `pgrep` and daemon client tables.
- **Privacy**: no external network requests; all checks and launcher operations run entirely on the local machine.
