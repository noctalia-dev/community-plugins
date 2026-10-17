# Bloom

Claude Code on your bar. A flower spins while Claude works and turns red when a
session is waiting for your permission. The panel shows the real `/status`
limits, every running session (click one to focus its terminal) and the last 7
days of tokens.

Bloom is an unofficial community project. It is not made, endorsed or supported
by Anthropic. "Claude" and "Claude Code" are Anthropic's trademarks and are used
here only to say which tool Bloom works with.

## Plugin

| Field | Value |
| --- | --- |
| ID | `teslaoruz/bloom` |
| Entries | Bar widget: `status`; panel: `panel` |

## Requirements

Bloom draws data that its backend collects, so install the backend once:

```sh
git clone https://github.com/teslaoruz/bloom-bar
cd bloom-bar
./install.sh --noctalia
```

The backend needs `python3` with python-gobject and Claude Code. Focusing a
session's terminal needs `niri`.

## Usage

Add the `status` widget to a bar (Settings → Bar → add widget, type
`teslaoruz/bloom:status`). `install.sh` places it after `workspaces` for you.

| Bar shows | Meaning |
| --- | --- |
| dim `✽` | no session is working |
| spinning flower | a session is working |
| red `✳` | a session needs permission (a notification fires too) |
| `2` next to it | number of sessions, once there is more than one |
| `26%` | the five-hour session limit; amber from 70%, red from 90% |

Click the widget to open the panel, or toggle it from a keybind:

```sh
noctalia msg panel-toggle teslaoruz/bloom:panel
```

In the panel, click a session row to focus the terminal it runs in.

## IPC

```sh
noctalia msg plugin teslaoruz/bloom:status all open
```

Toggles the panel, the same as clicking the widget.

## Notes

- The plugin only reads `~/.local/state/claude-tray/status.json` (or under
  `$XDG_STATE_HOME`), once a second, and spawns
  `~/.local/share/claude-tray/focus.sh <window-id>` when you click a session
  row. It makes no network calls and writes no files.
- The backend writes that file. It wires a hook script into
  `~/.claude/settings.json` and puts a small shim in front of your existing
  `statusLine` command, which still runs unchanged. Claude Code publishes its
  rate limits only through the statusline payload, so limits appear once a
  session has drawn its statusline. `./uninstall.sh` undoes all of it.
- Token counts come from `~/.claude/projects/*.jsonl`, on your machine.
