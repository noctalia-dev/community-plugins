# dropkitty

A Quake-style drop-down terminal for Noctalia, built on kitty's `quick-access-terminal` kitten. One key drops it down and hides it again with your shell session intact. A bar widget toggles it (scroll to resize, middle-click to flip position), shows whether it's open and lights up when a command finishes while it's hidden; a long-running one also sends a notification. `/dk <command>` in the launcher drops the terminal down and runs the command in a new tab.

The terminal is a layer-shell panel that kitty draws itself, so it works the same on niri, Hyprland, sway, Mango and Umbriel. It doesn't depend on compositor scratchpads, which niri doesn't have.

## Plugin

| Field | Value |
| --- | --- |
| ID | `lowcache/dropkitty` |
| Entries | Bar widget: `toggle`; service: `service`; launcher provider: `run` (`/dk`) |

- **Helper** (`bin/dropkitty`): shows, hides, moves and resizes the terminal. Your compositor keybinds call it directly, so the terminal keeps working while Noctalia is reloading or not running.
- **Bar widget** (`toggle`): click to toggle, middle-click to flip position, scroll up to grow or down to shrink by 5 percentage points per step, right-click for settings. Landscape resizes height; portrait resizes width. The colour shows the state: muted when stopped, normal when hidden, primary when open. After a command finishes while hidden it turns tertiary (exit 0) or error (non-zero) until you show the terminal again.
- **Service** (`service`): copies your settings to the helper and works out how much room your Noctalia bars take, so a full-size terminal never runs under a bar. It also sends the finished-command notifications.
- **Launcher** (`run`): `/dk` toggles the terminal; `/dk <command>` shows it and runs the command in a new tab.

## Requirements

- `kitty` 0.42 or newer, which provides `kitten quick-access-terminal`
- niri, Hyprland, sway, Mango or Umbriel. The helper asks `niri`, `hyprctl`, `swaymsg`, `mmsg` or `umbriel` for the focused output's size.
- `jq`, `flock`, `setsid` and `timeout` on `PATH`
- kitty shell integration, for the finished-command badge. It's on by default for bash, zsh and fish.

## Usage

Install dropkitty from the plugin catalog and add the **dropkitty** widget to a bar. Click the widget to start the terminal or toggle it.

For a keyboard toggle, bind a key to the helper. The catalog installs it at:

```
$XDG_STATE_HOME/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty
```

`$XDG_STATE_HOME` defaults to `~/.local/state` (if you set `NOCTALIA_STATE_HOME`, use that instead). A plugin installed by hand lives at `~/.local/share/noctalia/plugins/dropkitty/bin/dropkitty` instead. The bindings below use the catalog location; adjust the path if yours differs.

Keybinds go in your compositor config, not in Noctalia. The widget and your keys control the same terminal only when both go through this helper. Replace any existing drop-down binding (one that runs `kitten quick-access-terminal` or a script of your own); otherwise you get a second, separate terminal.

**niri** (`config.kdl`):
```kdl
Mod+Return       { spawn "~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty" "toggle"; }
Mod+Shift+Return { spawn "~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty" "position"; }
Mod+Alt+Return   { spawn "~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty" "size"; }
Mod+Ctrl+Return  { spawn "~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty" "orientation"; }
```

**Hyprland**:
```ini
$dropkitty = ~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty
bind = SUPER, Return, exec, $dropkitty toggle
bind = SUPER SHIFT, Return, exec, $dropkitty position
```

**sway**:
```
set $dropkitty ~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty
bindsym $mod+Return exec $dropkitty toggle
bindsym $mod+Shift+Return exec $dropkitty position
```

**Mango** (`config.conf`):
```
bind=SUPER,Return,spawn_shell,~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty toggle
bind=SUPER+SHIFT,Return,spawn_shell,~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty position
```

**Umbriel** (`config.toml`):
```toml
[keybinds]
"Mod+Return" = { action = "spawn ~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty toggle", repeat = false }
"Mod+Shift+Return" = { action = "spawn ~/.local/state/noctalia/plugins/materialized/community/dropkitty/bin/dropkitty position", repeat = false }
```

The helper takes one command:

| Command | Does |
|---|---|
| `toggle` | Show or hide; starts the terminal if it isn't running |
| `show`, `hide` | Explicit show and hide |
| `position` | Landscape: top ↔ bottom. Portrait: left ↔ right |
| `grow [PCT]`, `shrink [PCT]` | Show and resize the current orientation by 1–90 percentage points (default 5), clamped to 10–100%; sets size to normal |
| `size` | Normal ↔ full |
| `orientation` | Landscape (full width, drops from top or bottom) ↔ portrait (full height, slides from the side) |
| `top`, `bottom`, `left`, `right`, `landscape`, `portrait`, `normal`, `full` | Set one directly |
| `restart` | Restart kitty to apply launch-time settings (this ends the shell session) |
| `status` | Prints `alive=0/1 visible=0/1` |
| `run CMD…` | Shows the terminal and types `CMD` at a new tab's shell prompt (the first window if the terminal wasn't running), so aliases, history and the finished-command report all work. One line only |

Live changes from these commands, including scroll resizing, last until kitty restarts or you change the matching setting (`normal_height` for landscape height, `normal_width` for portrait width). Changing a geometry default re-seeds all live geometry from settings.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `orientation` | `select` | `landscape` | Where a freshly started terminal opens. Landscape drops a full-width terminal from the top or bottom; portrait slides a full-height one from the side |
| `edge_h` | `select` | `top` | Edge for landscape: `top` or `bottom` |
| `edge_v` | `select` | `right` | Edge for portrait: `left` or `right` |
| `size` | `select` | `normal` | `normal` uses the percentages below; `full` fills the usable screen along the drop direction |
| `normal_height` | `int` | `40` | Normal landscape height, in percent of the usable screen height (10–100) |
| `normal_width` | `int` | `50` | Normal portrait width, in percent of the usable screen width (10–100) |
| `bar_aware` | `bool` | `true` | Subtract the space Noctalia bars reserve before sizing |
| `opacity` | `double` | `0.9` | Background opacity (0.1–1.0). Applies on next launch |
| `focus_policy` | `select` | `on-demand` | `on-demand` keeps compositor keybinds working while the terminal is open; `exclusive` grabs the keyboard. Applies on next launch |
| `hide_on_focus_loss` | `bool` | `false` | Hide when you click elsewhere; changes apply immediately |
| `notify_after` | `int` | `10` | Notify when a command that ran at least this many seconds finishes while the terminal is hidden. `0` turns notifications off. The badge appears either way |
| `kitty_conf` | `file` | (none) | Kitten config used instead of `~/.config/kitty/quick-access-terminal.conf`. Applies on next launch |

"Applies on next launch" (`opacity`, `focus_policy` and `kitty_conf`) means after `restart`, or the next time the terminal starts. Everything else (font, colours, shell) comes from your kitty and kitten config. The plugin's settings take precedence over the same options there.

## IPC

The helper reports state changes to the service. You don't need to send these yourself; they're listed because the service accepts them:

```sh
noctalia msg plugin lowcache/dropkitty:service all shown
noctalia msg plugin lowcache/dropkitty:service all hidden
noctalia msg plugin lowcache/dropkitty:service all exited
noctalia msg plugin lowcache/dropkitty:service all cmd-finished <exit-code>,<seconds>,<uri-encoded-command>
```

To control the terminal itself, call the helper (see Usage).

## Notes

### What it runs and writes

- The service, widget and launcher provider run only the bundled helper (`bin/dropkitty`), with the arguments shown in Usage plus `_settings key=value…` when settings or bar reserves change.
- The helper starts kitty with `kitten quick-access-terminal --instance-group dropkitty`, a group separate from your other kitty windows and any other quick-access terminal. It controls that kitty through a remote-control socket limited to it (`allow_remote_control=socket-only`). kitty loads the bundled watcher (`bin/dropkitty-watcher.py`), which calls the helper on focus changes, finished commands (exit code, run time and command line) and the last window closing. `run` opens a tab with `kitten @ launch` and types the command with `kitten @ send-text`.
- The helper sends its state changes as the IPC messages above, through `timeout 1 noctalia msg …` in the background. Failures are ignored, so the helper works without Noctalia.
- Files: `$XDG_RUNTIME_DIR/dropkitty/`, holding settings, state, a lock and kitty's socket. Nothing else is written, and there are no network calls.

### Known limits

- **Occasional badge delay.** A command that finishes just after you hide the terminal can occasionally badge (and notify) several seconds late, because kitty delivers the event late.
- **No badge or notification inside tmux or zellij.** kitty can't see commands run inside a multiplexer.
- **`run` needs shell integration to wait for the prompt.** Without it, `run` waits 3 s and types the command anyway.
- **One monitor at a time.** The terminal opens on the focused output. Moving it to another monitor needs `restart`, which ends the session.
- **Mango and Umbriel are covered by tests only.** Their output-size lookups are checked against each compositor's IPC source, but not yet run on a live session.
- **Bar sizing is approximate.** It doesn't account for per-monitor bar layouts or the shadow bleed adjustment, so it can leave a few pixels too much room.

Issues: <https://github.com/lowcache/noctalia-dropkitty-plugin/issues>

## License

MIT
