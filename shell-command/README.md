# Shell Command

Run a shell command straight from the Noctalia launcher. Type `/sh` followed by
any command and press Enter to open it in your default terminal — a **real,
interactive shell** with live output, TUI apps, and your own native history.

No hardcoded completion table: suggestions come from the shell's own completion
engine and your command history, so they stay in sync with what's actually on
your system. Commands run through your own `$SHELL` in interactive mode, so
aliases, functions and environment from your rc config are available.

## Features

- **Instant command run** — `/sh ls -la ~/projects` opens the command in your
  default terminal.
- **Fish-style autosuggestions** — completions fetched live from Fish's
  completion engine (`fish -c 'complete -C "<query>"'`), falling back to bash
  `compgen -c` when Fish isn't installed. Type `/sh git st` and get `git status`,
  `git stash`, etc. Suggestions dynamically follow your system — no hardcoded
  list to maintain.
- **Snap-complete** — when a prefix has exactly one completion, the "Run" entry
  jumps to the completed command, so one Enter runs it instead of fill-then-run.
- **History** — previously run commands are remembered (per-plugin state, capped
  at 100) and offered as you type, most recent first.
- **Snippets** — user-defined commands shown when `/sh` is typed with an empty
  query.
- **Folder jump** — `/sh cd` lists subdirectories and lets you drill into nested
  folders. Select the "Open in:" row to launch a terminal inside the current
  directory.
- **Navigate and run in one launch** — `/sh cd ~/proj && make` changes into that
  directory and runs the command, so tools open in the right folder.
- **Suggestion fills, explicit launch runs** — completion/history/snippet rows
  fill the input (so you can keep typing or drill deeper); only "Run:" and
  "Open in:" rows actually launch a terminal.
- **Stay-open terminal** — after a fast command (e.g. `git status`) the terminal
  holds its output, shows a `[Press Enter to continue]` prompt, then drops you
  into an interactive shell.
- **Workspace-aware** — when a default workspace is set, commands start in that
  directory.

## Plugin

| Field           | Value                         |
| --------------- | ----------------------------- |
| ID              | `weinguyen/shell-command`     |
| Entry           | Launcher provider: `provider` |
| Launcher Prefix | `/sh`                         |

## Requirements

- Noctalia v5.0.0 or higher.
- `runInTerminal` needs a default terminal configured in Noctalia.
- A shell at `$SHELL` (falls back to `sh`).
- Optional: Fish (richer completions; falls back to bash otherwise).
- `ls` for the folder-jump listing.

Declared in `plugin.toml`
`dependencies`: `sh`, `ls`, plus `fish` and `bash` for the completion fallback
(the user's own `$SHELL` at runtime is whatever shell they have configured).

## Usage

Open the launcher and type `/sh` followed by a command:

```
/sh
/sh ls -la ~/projects
/sh git status
```

Press Enter to run the command in your default terminal.

With an empty query, recent commands and configured snippets are offered. As you
type a command, suggestions from the shell's completion engine appear under the
exact command you typed. Selecting a suggestion fills the input; run the filled
command by pressing Enter again (or use snap-complete when only one completion
matches).

### Navigate inside a folder first

```
/sh cd                  # list top-level folders
/sh cd proj             # list folders starting with "proj"
/sh cd ~/Builds/        # list everything directly inside ~/Builds
```

Folder rows let you drill deeper (each selection fills the path with a trailing
slash so you can keep going). The top "Open in:" row launches a terminal inside
the current parent directory.

### Run a command in a directory

```
/sh cd ~/Builds && make
```

Navigates into `~/Builds` and runs `make` there. Paths may contain spaces,
quotes and `\ ` escapes.

## Settings

| Setting             | Type          | Default | Description                                                                     |
| ------------------- | ------------- | ------- | ------------------------------------------------------------------------------- |
| `default_workspace` | `folder`      | `""`    | Working directory commands (and the `cd` listing) start in. Empty uses `$HOME`. |
| `snippets`          | `string_list` | `[]`    | Commands shown when `/sh` is typed with an empty query.                         |

## Notes

- Commands run in a real interactive terminal, so tools like `vim`, `htop` and
  `tmux` work normally.
- Commands execute via `$SHELL -ic`, so aliases and functions from your rc
  config are available. Note that completion — not alias expansion — is what
  powers suggestions; an alias defined only transitively may still need its
  underlying command.
- Completion suggestions update dynamically as Fish completions and installed
  binaries change — there is no hardcoded list to maintain.
- History is stored per-plugin (XDG state directory), capped at 100 entries,
  deduplicated, most recent command first.

## Development

- `shell_provider.luau` — the launcher provider entry.
- `translations/en.json`, `translations/vi.json` — user-facing strings.
