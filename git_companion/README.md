# Git Companion

Monitor your git repositories from the Noctalia bar. See your open pull requests
and issues at a glance, and jump to any of them on the web without leaving your
desktop. Works with **GitHub** (via `gh`), **GitLab** (via `glab`) and
**Gitea** (via `gt`).

## Plugin

| Field | Value |
| --- | --- |
| ID | `tphilippot/git_companion` |
| Entries | Bar widget: `widget`; panel: `main`; service: `service` |

## Requirements

Install the CLI for the platform you want to monitor and sign in once:

- `gh` — the [GitHub CLI](https://cli.github.com/), for `platform = github`. Run `gh auth login`.
- `glab` — the [GitLab CLI](https://glab.readthedocs.io/), for `platform = gitlab`. Run `glab auth login`.
- `gt` — the [Gitea CLI](https://gitea.com/gitea/cli), for `platform = gitea`. Run
  `gt auth login --host https://git.example.com`. With accounts on several instances,
  `gt config set default_host https://git.example.com` picks the one the plugin follows.
- `xdg-open` — opens a PR/MR or issue in your default browser when you click it in the panel.

You only need the CLI matching your chosen `platform`; all three are listed so the
requirement shows up regardless of which one you pick. No token is ever stored by
the plugin — each CLI keeps its own credentials.

The CLI must be on the `PATH` Noctalia runs with, which is the session's, not
your shell's. If the panel reports "gt is not installed" while `gt` works in a
terminal (for example because it lives in `~/.local/bin`), link it into a
system folder:

```sh
sudo ln -s ~/.local/bin/gt /usr/local/bin/gt
```

## Usage

**Bar widget** — add the `widget` entry to your bar to see a platform glyph plus
your open PR/MR and issue counts. Click it to open the panel.

```sh
noctalia msg panel-toggle tphilippot/git_companion:main
```

**Panel** — a triage view of your work. The header shows your avatar, the
plugin name and, under it, the platform glyph with your username and scope
(your `group` if set, otherwise your `repo`, otherwise your profile bio), then a
**settings** button that opens the plugin settings, a **refresh** and a
**close** button. A footer gives the time of the last update
and the refresh interval.

Up to three tabs follow, with their count in the label:

- **Pull requests / Merge requests** — the ones you authored.
- **Issues** — the ones assigned to you.
- **Reviews** — open, unmerged PR/MRs waiting on your review.
- **Deploys** (GitLab and GitHub) — for each followed repository, the last
  successful deployment of each environment: the version (tag or branch) and
  its date and time. Environments that never deployed successfully are left
  out. The tab follows `deploy_repos`, else `repo`; with neither, or with
  `show_deploys` off, it is hidden. Gitea has no deployments API, so the tab
  never shows there.

`tab_style` sets how the tabs read: **Simple** (name and count), **Full** (the
same with the tab glyph) or **Compact** (glyph and count, the name as a tooltip;
handy with four tabs).

Each row shows a status chip, the title, the status in words with the
reference, and the branch badge of its target branch. Your own PR/MRs are
grouped by what they ask of you:

- **Needs you** — CI failed, conflicts, out of date with the target branch,
  changes requested, unresolved threads (and GitLab's other author-side checks).
- **Ready to merge** — nothing blocks the merge.
- **Waiting** — CI running, review required, draft, blocked by something else.

The status comes from GitLab's `detailed_merge_status`, from GitHub's merge
state, review decision and checks, and from Gitea's mergeability and review
decision. **Gitea has no CI status**: reading it would cost one call per pull
request. Clicking a row opens it in the browser and closes the panel.

Each tab can be hidden with its `show_*` setting, and a hidden tab is not
fetched at all. Hide every tab and the panel says so instead of showing an empty
list. An empty tab, a missing CLI, a missing GitLab scope and a CLI that is not
signed in each get their own message; the sign-in one has a **Copy command**
button for `gh auth login` or `gt auth login`.

**Branch badges** — a coloured chip at the end of a PR/MR row shows the branch
it targets, so a merge request into `develop` reads differently from one into
`release/18.3.4` at a glance. Issues have no target branch and never carry one.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `platform` | `select` | `github` | `github` (uses `gh`), `gitlab` (uses `glab`) or `gitea` (uses `gt`). |
| `repo` | `string` | `""` | Scope to one repo: `owner/repo` (GitHub, Gitea) or the project path (GitLab). Leave empty to use the group/owner. |
| `group` | `string` | `""` | Filter by group (GitLab) or owner (GitHub, Gitea). Leave empty to use `repo`. |
| `tab_style` | `select` | `simple` | How the tabs read: `simple` (name), `full` (name and glyph) or `compact` (glyph and count, name in a tooltip). |
| `refresh_interval` | `int` | `60` | Seconds between automatic refreshes (minimum 10). |
| `bar_display_mode` | `select` | `both` | What the bar shows next to the glyph: `none`, `prs` (PRs/MRs only), `issues` (Issues only), or `both`. |
| `show_prs` | `bool` | `true` | Show the PRs/MRs tab. |
| `show_issues` | `bool` | `true` | Show the Issues tab. |
| `show_reviews` | `bool` | `true` | Show the Code Review tab. |
| `count_reviews_with_prs` | `bool` | `false` | Add the review count to the PR/MR number in the bar. Hidden while `show_reviews` is off. |
| `show_deploys` | `bool` | `true` | Show the Deploys tab. GitHub and GitLab only. |
| `deploy_repos` | `string_list` | `[]` | Repositories of the Deploys tab: `owner/repo` (GitHub) or the project path (GitLab). Empty uses `repo`; with neither, the tab is hidden. Hidden while `show_deploys` is off. |
| `deploy_hidden_envs` | `string_list` | `[]` | Environments left out of the Deploys tab, in every repository: an exact name (`prod`) or a prefix ending in `*` (`bot-*`), case-insensitive. Hidden while `show_deploys` is off. |
| `notify_mr_mergeable` | `bool` | `true` | Notify when one of your PR/MRs becomes ready to merge. See **Notifications**. |
| `notify_mr_pipeline_failed` | `bool` | `true` | Notify when the CI of one of your PR/MRs fails. GitHub and GitLab only. |
| `notify_mr_conflict` | `bool` | `true` | Notify when one of your PR/MRs has conflicts or falls behind its target branch. |
| `notify_mr_changes_requested` | `bool` | `true` | Notify when a reviewer requests changes on one of your PR/MRs. |
| `branch_badge_primary` | `string_list` | `["develop"]` | Branch patterns badged in the theme's primary accent. |
| `branch_badge_secondary` | `string_list` | `["release/*"]` | Branch patterns badged in the secondary accent. |
| `branch_badge_tertiary` | `string_list` | `[]` | Branch patterns badged in the tertiary accent. |
| `branch_badge_alert` | `string_list` | `["master", "main"]` | Branch patterns badged in the theme's alert colour. |

The four `branch_badge_*` lists decide the colour of the branch chip. Put one
branch pattern per entry: either an exact branch name (`develop`) or a prefix
ending in `*` (`release/*` matches `release/18.3.4`). The lists are checked in
the order above and **the first match wins**, so a branch listed under two
colours takes the earlier one. A branch matching nothing gets no chip.

The colour is the setting you put the branch in, so there is no colour to type.
Adding a fifth colour requires a plugin change rather than configuration.

On GitHub and Gitea the widget lists pull requests **authored by you** and issues
**assigned to you**. On GitLab it lists merge requests and issues **authored by
you** — both GitLab lists are filtered by author, not by assignee. The Code
Review tab is filtered by **requested reviewer** and includes drafts. On Gitea
that filter only runs across a whole instance, so with a `repo` set the plugin
searches the repo's owner and keeps the pull requests of that repo.

### Notifications

A notification is sent when one of **your** PR/MRs (the first tab) enters a
merge status that asks something of you. The status comes with the list the
panel already fetches, so watching it costs nothing extra. Each case has its
own toggle:

| Setting | Status | Meaning |
| --- | --- | --- |
| `notify_mr_mergeable` | `mergeable` | Nothing blocks the merge any more. |
| `notify_mr_pipeline_failed` | `ci_must_pass` | The CI finished and failed (not on Gitea). |
| `notify_mr_conflict` | `conflict`, `need_rebase` | Conflicts, or the branch is behind its target. |
| `notify_mr_changes_requested` | `requested_changes` | A reviewer requested changes. |

Every other status is deliberately left out: running CI, pending approvals and
unresolved threads change too often, drafts and closed requests are your own
doing, and the rest depend on project settings.

- The first fetch after the service starts (or after the first tab is turned
  back on) only records the current state, so nothing is replayed at login.
- A newly opened PR/MR is not notified; its later status changes are.
- Each request shows one status at a time, the most pressing one, so a
  conflict can stay hidden behind another blocker and be notified only once
  that one clears.
- Three or more changes in one refresh are grouped into a single notification.
- Notifications have no click action: `noctalia.notify` takes a title and a
  body only. Open the panel to jump to the request.

Setup errors (missing CLI, missing GitLab scope, `gh` or `gt` not signed in)
are notified once when they first occur, not on every refresh while they last.

### Gitea

Since 2.0.0 the plugin drives `gt`, the CLI Gitea now recommends, instead of
`tea`. `gt` runs from any directory and picks the instance itself, like `glab`:
the only one you are signed in to, else its `default_host`. The former
`gitea_login` setting is gone. Other Gitea-compatible forges (Forgejo,
Codeberg) expose the same v1 API and should work through `gt` as well, but
they are not tested here.

`show_reviews` is the master switch for the Code Review feature: turned off, the
tab disappears, nothing is fetched for it, and `count_reviews_with_prs` has no
effect. The bar tooltip always lists issues, PRs/MRs and reviews separately, so
a folded count is never ambiguous.

## IPC

```sh
noctalia msg plugin tphilippot/git_companion:service all refresh
```

Re-fetch PRs/MRs and issues immediately. The service is a singleton, so it is
addressed with the `all` target. Results land in the panel automatically when the
fetch completes.

## Notes

- **Network:** each refresh calls the forge API through the installed CLI,
  scoped by your `repo` or `group` setting, one call per visible tab, so hiding
  a tab removes its request:
  - GitLab: `glab mr list` (`--author=@me`, `--reviewer=@me`) and `glab issue list`;
    merge requests carry their status and target branch.
  - GitHub: one `gh api graphql` search per pull request tab (`author:@me`,
    `review-requested:@me`), which returns the merge state, review decision,
    checks and target branch of every pull request at once; issues use
    `gh search issues --assignee=@me`.
  - Gitea: `gt search pr` / `gt search issue`, then, for the pull request tabs,
    one `gt pr list` per repository found in the results to read mergeability,
    review decision and target branch.

  The Deploys tab adds one `glab api graphql` call per GitLab project, or two
  `gh api graphql` calls per GitHub repository (the environments, then their
  recent deployments). Your account comes from `<cli> api user`, and your
  avatar is then downloaded from the forge.
- **Processes:** the service spawns `gh`, `glab` or `gt` for fetches; the panel spawns `xdg-open` (non-blocking) when
  you click an item.
- **Filesystem:** the service downloads your profile picture to the plugin's own
  data directory, at `~/.local/state/noctalia/plugins/data/tphilippot/git_companion/avatar`
  (it follows `NOCTALIA_STATE_HOME` if you set it), so the panel can show it next
  to your username. It is re-downloaded only when the avatar URL changes, and the
  file persists until you delete it. Nothing else is written: the PR/MR
  and issue lists are in-memory only and are cleared when the plugin stops.
- **GitLab scope:** GitLab requires a `repo` or `group` scope in settings; the
  service shows an error notification if neither is set. GitHub and Gitea both
  search across all your repositories when no scope is set.
- **Failed fetches:** when a CLI call fails, the panel keeps showing the items it
  last fetched and reports the failure in a strip above them, quoting the CLI's
  own message — so a mistyped `repo` reads as `Error: not found` rather than a
  silently empty tab.
