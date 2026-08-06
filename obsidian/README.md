# Obsidian

Quick daily capture and git sync for a local [Obsidian](https://obsidian.md/) vault from Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `davemhammer/obsidian` |
| Entries | Bar widget: `status`; panel: `manager`; service: `service` |
| Launcher Prefix | `/ob` |

## Requirements

- `obsidian` on `PATH` (for `obsidian://` open via `xdg-open`)
- `git` on `PATH` for status / commit / pull / push
- A local vault path (default targets a common layout; change in settings)

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
| `daily_folder` | `string` | _(empty)_ | Daily notes folder relative to vault (empty = vault root). |
| `daily_format` | `string` | `%Y-%m-%d` | Daily filename without `.md` (strftime). |
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

## Notes

- **Filesystem:** reads/writes daily note markdown under the vault; scans `*.md` mtimes (skips `.obsidian`, `.git`, `.claudian`).
- **Processes:** `find`, `git status|add|commit|pull|push`, `xdg-open` for Obsidian URIs.
- **Git pull** uses `git pull --no-rebase --autostash` so the vault is not left mid-rebase. If a rebase/merge is already in progress, use **Abort rebase/merge** on the Git tab.
- Does not talk to Obsidian Sync cloud APIs; git is your sync layer.
- Brand assets under `assets/` (Simple Icons–style mark).
