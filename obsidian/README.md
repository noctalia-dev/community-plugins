# Obsidian

Quick daily capture and git sync for a local [Obsidian](https://obsidian.md/) vault from Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/obsidian` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service`; launcher: `ob` |
| Launcher Prefix | `/ob` |

## Requirements

Install these on `PATH` (declared in `plugin.toml` `dependencies`):

- `obsidian` — desktop app / URI handler so `obsidian://` opens work (the plugin launches URIs via `xdg-open`, not the CLI)
- `git` — status, commit, pull, push, abort
- `xdg-open` — launches `obsidian://` URIs
- `find`, `sort`, `head` — recent-notes scan under the vault (`find -P`)
- `realpath` — canonicalize paths before read/write (symlink escape checks)

Also configure a local vault path (must contain `.obsidian`).

## Usage

Set **Vault path** (and optional daily folder/format) in plugin settings. Daily notes default to the vault root with filenames `%Y-%m-%d` (override folder/format to match your Daily Notes plugin).

Add the **status** bar widget (`davemhammer/obsidian:status`):

- **Click** — open panel
- **Right-click** — open today’s daily note

Panel tabs:

- **Daily** — type a line and **Add to daily** (appends `- HH:MM text`); open daily
- **Recent** — last modified markdown notes; open / copy `[[link]]` / path
- **Git** — dirty list; commit (optional message), pull, push, pull+push; **Abort** if rebase/merge stuck

Launcher:

- `/ob` — categories
- `/ob capture buy milk` — append timestamped line to daily
- `/ob daily` — open daily
- `/ob git` — git actions

```sh
noctalia msg panel-toggle davemhammer/obsidian:manager
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vault_path` | `folder` | `~/Documents/Obsidian Vault` | Vault root (must contain `.obsidian`). |
| `vault_name` | `string` | _(empty)_ | Name for `obsidian://` URIs; empty = folder name. |
| `daily_folder` | `string` | _(empty)_ | Daily notes folder relative to vault (empty = vault root). Must stay under the vault (`..` rejected). |
| `daily_format` | `string` | `%Y-%m-%d` | Daily filename stem without path separators (strftime); `.md` is appended. |
| `git_commit_message` | `string` | `vault: capture from Noctalia` | Default commit message. |
| `refresh_interval` | `int` | `20` | Rescan recent notes + git every N seconds. |
| `notify_on_action` | `bool` | `true` | Notify after capture/git actions. |
| `show_dirty` | `bool` (widget) | `true` | Show dirty file count on the bar. |

## IPC

```sh
noctalia msg panel-toggle davemhammer/obsidian:manager
noctalia msg plugin davemhammer/obsidian:service all refresh
noctalia msg plugin davemhammer/obsidian:service all daily
noctalia msg plugin davemhammer/obsidian:service all pull
noctalia msg plugin davemhammer/obsidian:service all push
noctalia msg plugin davemhammer/obsidian:service all sync
```

Capture with payload (text line for daily):

```sh
noctalia msg plugin davemhammer/obsidian:service all capture '{"text":"buy milk"}'
```

(Exact payload syntax depends on your Noctalia IPC version; the service expects event `capture` with a table containing `text` or `line`.)

## Notes

- **Filesystem:** reads/writes daily note markdown **only under** the configured vault; `daily_folder` / note paths reject `..` and absolute paths; existing path components that are symlinks are refused; `realpath` must keep the target under the vault. Recent scan uses `find -P` (never follows symlinks) for `*.md` mtimes (skips `.obsidian`, `.git`, `.claudian`); listed paths are re-normalized before display and again before open.
- **Processes:** `find -P`, `sort`, `head` (recent notes); `realpath` + `test -L` (path confinement); `git status|add|commit|pull|push` and `git rebase|merge --abort` when requested; `xdg-open` for `obsidian://` URIs only.
- **Vault required:** capture and open-daily refuse to create files unless `vault_path` is a real vault (contains `.obsidian`).
- **Git pull** uses `git pull --no-rebase --autostash` so the vault is not left mid-rebase. If a rebase/merge is already in progress, use **Abort rebase/merge** on the Git tab.
- Does not talk to Obsidian Sync cloud APIs; git is your sync layer.
- Brand assets under `assets/` (Simple Icons–style mark).
