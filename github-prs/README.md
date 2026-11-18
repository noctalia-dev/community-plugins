# GitHub Pull Requests

Track the pull requests that matter to you from the Noctalia bar. The plugin uses your existing GitHub CLI authentication and shows CI, review, draft, and activity status in a compact panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `raycursive/github-prs` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `fetch` |

## Requirements

- Noctalia plugin API 9 or newer (used for closure-backed panel interactions).
- `gh` on `PATH`, authenticated with `gh auth login`.
- `xdg-open` on `PATH` to open a selected pull request in the default browser.

## Usage

Enable `raycursive/github-prs` in **Settings → Plugins**, then add the `bar` entry from **Settings → Bar → Widgets**. Click the widget to open the `panel` entry. The `fetch` service starts automatically and refreshes the configured searches in the background.

Each **Search rules** item is a GitHub search query fragment. The service prefixes every rule with `is:pr is:open` and, unless the rule already contains `archived:`, adds `archived:false`. Results from all rules are merged and deduplicated.

Examples:

| Rule | Matches |
| --- | --- |
| `author:@me` | Pull requests you created. |
| `review-requested:@me org:acme` | Reviews requested from you in one organization. |
| `assignee:@me -repo:acme/legacy draft:false` | Non-draft pull requests assigned to you, excluding one repository. |
| `involves:@me org:acme org:other-org` | Pull requests involving you across two organizations. |

GitHub's `repo:` qualifier matches exact repositories. Use **Excluded repositories** for plugin-side glob patterns such as `legacy-*` or `acme/private-*`. A pattern without an owner matches repository names in every organization; matching is case-insensitive and `*` matches any number of characters.

The panel groups pull requests by repository and orders them by latest activity. Select a repository header to collapse or expand it, or select a pull-request title to open it in the browser. Open the panel without the bar widget with:

```sh
noctalia msg panel-toggle raycursive/github-prs:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `rules` | `string_list` | `author:@me` | GitHub search fragments; one `gh api graphql` request runs per non-empty rule. |
| `excluded_repositories` | `string_list` | empty | Case-insensitive repository-name or `owner/name` glob patterns removed after fetching. |
| `refresh_interval` | `int` | `180` seconds | Background refresh interval, limited to 30–3600 seconds. |
| `glyph` | `glyph` | `git-pull-request` | Glyph used by this bar-widget instance. |
| `hide_when_zero` | `bool` | `false` | Hides the bar widget when no matching open pull requests remain. |

## IPC

The `fetch` service accepts these events:

```sh
# Fetch all configured search rules immediately.
noctalia msg plugin raycursive/github-prs:fetch all refresh

# Write status, result count, last update, and any error to the Noctalia log.
noctalia msg plugin raycursive/github-prs:fetch all dump
```

## Notes

- For every configured rule, the service spawns `gh api graphql`, which sends the resulting search query to GitHub using the GitHub CLI's current authentication. The plugin does not read or store a GitHub token itself.
- Selecting a pull request spawns `xdg-open` with the GitHub URL. The plugin does not write files.
- Each rule returns at most 50 rows. The panel reports additional matches as truncated instead of silently presenting the list as complete.
- A partial rule failure is shown alongside successful results. If every rule fails, the last successful in-memory result remains visible until the plugin reloads or a later fetch succeeds.
