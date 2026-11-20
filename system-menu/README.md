# System Menu

![Made with AI](https://img.shields.io/badge/Made%20with-AI-76ddcf)

Launch a package manager, system monitor and terminal. View system information
in a native About panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ajsem1337/system-menu` |
| Entries | Bar widget: `button`; panels: `menu`, `about` |

## Requirements

- Noctalia plugin API 43+.
- `python3` (3.11+) and `fastfetch` for About; standard Linux tools including `lsblk`.
- Your chosen applications, installed separately.
- `gtk-launch` for Desktop entry mode.

## Usage

Add `ajsem1337/system-menu:button` in bar settings. Configure your applications
under **Settings → Plugins → System Menu**.

```sh
noctalia msg panel-toggle ajsem1337/system-menu:menu
noctalia msg panel-toggle ajsem1337/system-menu:about
```

About shows hardware/software information and the widget version, with refresh
and copy controls. The bar, menu and About use your distribution's logo.

## Settings

| Key | Default | Purpose |
| --- | --- | --- |
| `terminal` | `kitty` | Terminal executable |
| `show_terminal_arguments` | `false` | Show advanced terminal options |
| `terminal_args` | `[]` | Extra terminal arguments |
| `terminal_exec_args` | `["-e"]` | Arguments before a TUI command |
| `terminal_command_format` | `argv` | Separate arguments; `quoted` for terminals expecting one command string |
| `packages_mode` | `desktop` | Package manager launch mode |
| `packages_command` | Empty | Executable or desktop ID |
| `packages_args` | `[]` | Package manager arguments |
| `monitor_mode` | `desktop` | Task Manager launch mode |
| `monitor_command` | Empty | Executable or desktop ID |
| `monitor_args` | `[]` | Task Manager arguments |

Modes: **Direct** (`direct`) for GUI commands, **In configured terminal** (`terminal`)
for TUIs, **Desktop entry** (`desktop`) for installed `.desktop` IDs.

| Example | Mode | Executable / ID |
| --- | --- | --- |
| Pacseek / Pacsea / package-menu | Terminal | `pacseek` / `pacsea` / `package-menu` |
| GNOME Software | Desktop entry | `org.gnome.Software.desktop` |
| Mission Center | Direct | `missioncenter` |
| btop / htop | Terminal | `btop` / `htop` |

Arguments are separate list items, without shell quotes or variable expansion.
`~/` works in executable paths. Desktop mode uses the entry's own launch settings;
custom arguments are inactive. Entries with `Terminal=true` use the desktop's
terminal selection.

For TUI mode, set run-program arguments to `-e` for Kitty/foot/Alacritty, `--` for
GNOME Terminal, or `start`, `--` for WezTerm. Hidden terminal options still apply.

## Notes

See [operations and privacy](OPERATIONS.md) for process and data access.

MIT. Inspired by [GNOME Logo Menu](https://github.com/Aryan20/Logomenu).
