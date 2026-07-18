# Zed Provider

![Zed Provider thumbnail](thumbnail.webp)

Zed Provider integrates recent Zed workspaces with the Noctalia launcher so you
can reopen a project quickly without leaving the shell.

## Plugin

| Field | Value |
| --- | --- |
| ID | `cleboost/zed-provider` |
| Entry | Launcher provider: `provider` |
| Launcher Prefix | `/zed` |

## Requirements

Install [Zed](https://zed.dev) and ensure `zed` is available on `PATH` as
`zeditor`. The `sqlite3` command must also be available to read Zed's workspace
database. `nohup` command is required to launch Zed.

## Usage

Open the Noctalia launcher and type `/zed` to list recent local Zed workspaces.
Continue typing to filter projects by name, then select one to open it with
`zeditor`.

## Settings

- `db_path` — path to Zed's `db.sqlite` workspace database.
- `max_results` — maximum number of projects shown in the launcher.

## Notes

Projects are read from Zed's workspace database, typically at
`~/.local/share/zed/db/0-stable/db.sqlite`. Remote workspaces are excluded.
The list is cached for the launcher session and refreshed when you clear the
query.
