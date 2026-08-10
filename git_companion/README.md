# Git Companion

Monitor your git repositories from the Noctalia bar. See your open pull requests
and issues at a glance, and jump to any of them on the web without leaving your
desktop. Works with **GitHub** (via `gh`) and **GitLab** (via `glab`).

## Plugin

| Field | Value |
| --- | --- |
| ID | `tphilippot/git_companion` |
| Entries | Bar widget: `widget`; panel: `main`; service: `service` |

## Requirements

Install the CLI for the platform you want to monitor and sign in once:

- `gh` — the [GitHub CLI](https://cli.github.com/), for `platform = github`. Run `gh auth login`.
- `glab` — the [GitLab CLI](https://glab.readthedocs.io/), for `platform = gitlab`. Run `glab auth login`.
- `xdg-open` — opens a PR/MR or issue in your default browser when you click it in the panel.

You only need the CLI matching your chosen `platform`; both are listed so the
requirement shows up regardless of which one you pick.

## Usage

**Bar widget** — add the `widget` entry to your bar to see a platform glyph plus
your open PR/MR and issue counts. Click it to open the panel.

```sh
noctalia msg panel-toggle tphilippot/git_companion:main
```

**Panel** — two tabs, **Pull Requests / Merge Requests** and **Issues**, each
listing your items. Click an item to open it on the web (GitHub or GitLab) in
your browser; the panel closes as it opens. Use the **refresh** button in the
header to re-fetch immediately. The last-updated time is shown next to the tabs.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `platform` | `select` | `github` | `github` (uses `gh`) or `gitlab` (uses `glab`). |
| `repo` | `string` | `""` | Scope to one repo: `owner/repo` (GitHub) or the project path (GitLab). Leave empty to use the group/owner. |
| `group` | `string` | `""` | Filter by group (GitLab) or owner (GitHub). Leave empty to use `repo`. |
| `refresh_interval` | `int` | `60` | Seconds between automatic refreshes (minimum 10). |
| `bar_display_mode` | `select` | `both` | What the bar shows next to the glyph: `none`, `prs` (PRs/MRs only), `issues` (Issues only), or `both`. |

On GitHub the widget lists pull requests **authored by you** and issues **assigned
to you**; on GitLab it lists merge requests and issues **assigned to you**.

## IPC

```sh
noctalia msg plugin tphilippot/git_companion:service all refresh
```

Re-fetch PRs/MRs and issues immediately. The service is a singleton, so it is
addressed with the `all` target. Results land in the panel automatically when the
fetch completes.

## Notes

- **Network:** each refresh calls the GitHub or GitLab API through the installed
  CLI (`gh search prs/issues` or `glab mr/issue list`), scoped by your `repo` or
  `group` setting.
- **Processes:** the service spawns `gh` or `glab` for fetches; the panel spawns
  `xdg-open` (non-blocking) when you click an item.
- **Filesystem:** nothing is written to disk — plugin state is in-memory only and
  is cleared when the plugin stops.
- **GitLab scope:** GitLab requires a `repo` or `group` scope in settings; the
  service shows an error notification if neither is set.