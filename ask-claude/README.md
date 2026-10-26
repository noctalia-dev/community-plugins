# Ask Claude

Ask Claude Code a question from the Noctalia launcher and read the answer in the same window. When you want to go
further, press Enter on the answer to continue the same Claude Code session in your terminal, or in a new tab of the
multiplexer you already use: herdr, tmux, tuios or zellij.

## Plugin

| Field | Value |
| --- | --- |
| ID | `0rgl/ask-claude` |
| Entries | Launcher provider: `ai` |
| Launcher Prefix | `/ai` |

## Requirements

- Noctalia 5.3.0 or newer (plugin API 24, for `presentation = "detail"` rows).
- `claude`: [Claude Code](https://claude.com/claude-code), logged in, recent enough to support `--safe-mode` and
  `--permission-prompts`. It is looked up on `PATH` first, then in `~/.local/bin`, where the native installer puts
  it, since a graphical session's `PATH` often lacks that folder.
- `timeout`, `bash`, `grep`, `head`, `chmod`, `mkdir` and `rm` for the ask wrapper. They come with coreutils, grep
  and bash on any normal distribution.
- A terminal emulator. The plugin opens terminal windows through Noctalia: `$TERMINAL` if set, otherwise the first of
  ghostty, kitty, alacritty, wezterm, foot, konsole, gnome-terminal, kgx, ptyxis or xterm found on `PATH`.

Optional, only for the multiplexer you pick in **Continue in**:

- One of `herdr`, `tmux`, `tuios` or `zellij`. zellij 0.44 or newer gets a new tab; older versions get a new pane in
  the current tab. `herdr` is looked up on `PATH` first, then in `~/.local/bin`.
- `jq`, `pgrep`, `ps`, `tr`, `awk` and `sort` to find the multiplexer session and its terminal window.
- Your compositor's CLI to focus that window: `hyprctl` (Hyprland), `niri` (niri), `swaymsg` (Sway) or `umbriel`
  (Umbriel). On other compositors, or when no client is attached, the plugin attaches to the multiplexer in a new
  terminal window instead.

## Usage

Open the launcher and type `/ai` followed by your question, for example:

```
/ai how do I check which kernel version I'm running?
```

| Type | What happens |
| --- | --- |
| `/ai <question>` + Enter | The answer streams into the launcher as a scrollable card |
| Enter on a finished card | The session (`claude --resume <id>`) opens where **Continue in** points: a new terminal window, or a new tab in your running multiplexer |
| `/ai !<question>` + Enter | Incognito ask. Nothing is saved locally, and Enter on the card copies the answer |
| `<question>` with no prefix | An **Ask AI** row shows up under web search once you type 2 characters. Enter on it does the same as `/ai <question>` |
| `/ai` | A hint, **Copy last answer** and your last 5 asks. Picking an old ask shows the saved answer without asking the model again |

Starting a new ask cancels the one still running.

### Continuing a conversation

Pick where Enter on a finished card takes you in **Continue in**:

| Continue in | What happens |
| --- | --- |
| New terminal window (default) | Your terminal opens in the working directory and runs `claude --resume <id>`. Works with any terminal Noctalia can find. |
| New herdr tab | A tab opens in the focused herdr workspace. |
| New tmux window | A window opens in the session of the most recently active tmux client, or the most recently used session when none is attached. |
| New tuios window | A window opens in the attached tuios session, or the most recently active one. |
| New zellij tab | A tab opens in the newest running zellij session (a pane on zellij older than 0.44). |

With a multiplexer, the plugin then focuses the terminal window that shows it on Hyprland, niri, Sway and Umbriel. If
the multiplexer isn't running, the session opens in a new terminal window instead. If no window can be focused, for
example on another compositor or when no client is attached, a new terminal window attaches to the multiplexer.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `model` | `select` | `sonnet` | Model for launcher asks: `sonnet`, `haiku`, `opus`, or `default` (whatever Claude Code is set to). |
| `tools` | `select` | `web` | `web` allows only WebSearch and WebFetch. `none` answers from the model alone. |
| `open_target` | `select` | `terminal` | Where Enter on a finished card continues the session: `terminal`, `herdr`, `tmux`, `tuios` or `zellij`. A multiplexer must already be running; if it isn't, the session opens in a terminal window. |
| `workdir` | `folder` | `~` | Working directory for asks and resumed sessions. Falls back to `~` if the folder doesn't exist. |
| `timeout_s` | `int` | `120` | Seconds before the ask is killed (15 to 900, step 15). |
| `max_turns` | `int` | `8` | Advanced. Upper bound on agent turns per ask, which in practice caps the number of web searches (1 to 30). |
| `extra_prompt` | `string` | empty | Advanced. Extra instructions appended to the system prompt of launcher asks. |

## Notes

### Security and privacy

`bin/ask` runs `claude -p --safe-mode`, so a launcher ask doesn't load your CLAUDE.md, auto memory, skills, hooks or
plugins and can't leak them. `--strict-mcp-config` and `--disallowedTools 'mcp__*'` keep MCP servers out. The only
tools are WebSearch and WebFetch, or none if you set Tools to None. Everything else is denied by
`--permission-mode dontAsk --permission-prompts none`, and `--max-turns` caps how long the agent can loop.

The question never appears in argv. The plugin writes it to `$XDG_RUNTIME_DIR/ask-claude/`, which only your user can
read. The wrapper opens the file and deletes it before `claude` starts, so `ps` won't show the question. Questions over
8000 characters are rejected.

If an ask used the web, the card says so and lists the sources. Web pages can carry prompt injection, so that session
resumes with `--permission-mode default` and every Bash or Edit call needs your approval, even if your usual mode is
more permissive.

The card drops ANSI sequences and control characters and stops at 30,000 characters. The end-of-stream marker
includes a nonce that changes with every ask.

### Network, files and processes

The plugin makes no network calls of its own. Questions and web results go to Anthropic through Claude Code, the same as in any Claude Code session.

It writes the prompt file and a pid file to `$XDG_RUNTIME_DIR/ask-claude/`; the prompt file is deleted before
`claude` starts. The last 5 answered asks (question, answer, session id, sources) are kept in `history.json` in the
plugin data dir (`noctalia.pluginDataDir()`, chmod 600). Incognito asks never go there.

Claude Code keeps its own transcript of normal asks in `~/.claude/projects/`, which is what makes resuming possible.
Incognito asks run with `--no-session-persistence` and leave no transcript, but they are not anonymous.

`bin/ask` runs `timeout` and `claude`. A new ask sends SIGTERM to the previous one, but only if that process carries
the plugin's `ASK_CLAUDE=1` marker. `bin/resume` calls the multiplexer you picked (`herdr`, `tmux`, `tuios` or
`zellij`) to open a tab and list its clients, uses `jq`, `pgrep`, `ps`, `awk` and `sort` to find the client's window,
and calls the compositor's CLI (`hyprctl`, `niri`, `swaymsg` or `umbriel`) to list and focus windows. Terminal
windows are opened with `noctalia.runInTerminal`.

A resumed session is a regular interactive Claude Code session with your full configuration.

### Limitations

- Only Enter opens the card, because Noctalia's detail view doesn't handle clicks.
- The card is plain text, and Markdown is stripped from the answer.
- A resumed session keeps the launcher's "plain text" system prompt until it gets compacted.
- The plugin can't tell global search apart from `/ai`. Typing `!<question>` without the prefix also starts an
  incognito ask, and typing your last question again shows its answer instead of **Ask AI**.

### Credits

The shell quoting helper and the login error check come from lowcache's
[claude-companion](https://github.com/noctalia-dev/community-plugins/tree/main/claude-companion) plugin (MIT).
