# Claude Cockpit

Watch your Claude Code sessions and plan limits from the bar. One panel
shows the running sessions, usage and cost, every past session, your
CLAUDE.md files, and the installed skills and mods.

![Live tab with one running session](images/live.png)

*The Live tab: every running session, grouped by what it needs from you.*

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/claude-cockpit` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

The headless `service` fetches usage and polls the live sessions. The
widget and the Live and Usage tabs only show what it publishes.

## Requirements

- noctalia v5.3.0 or newer (`plugin_api = 33`). The Sessions tab needs
  `revealKey` on `ui.scroll`, which keeps the keyboard selection in view. An
  older noctalia keeps getting the last version it can load.
- `bash`, `jq` and `curl`.
- The base tools the scripts call: `sh`, `find`, `xargs`, `stat`, `du`,
  `grep`, `tac`, `awk`, `cut`, `head`, `tail`, `rm`, `rmdir`, `mkdir`, `mv`.
  Every distribution ships them.
  The Sessions scan runs on up to 8 CPUs through `xargs -P` (`nproc` picks the
  count, 4 without it).
- `claude` on `PATH` for the Skills/Mods tab, and a logged-in Claude Code
  (`~/.claude/.credentials.json`) for the Usage tab.
- `xdg-open` to open a project page.
- Optional: `niri`, `hyprctl` (Hyprland) or `umbriel` to focus a session's
  terminal from the Live tab.
- Optional: `code` or `zed` to open a CLAUDE.md, or set `editor_command`.

## Usage

Add **Claude Cockpit** to a bar from the Add-widget picker. Click it to
open the panel, or:

```sh
noctalia msg panel-toggle nightwatch75/claude-cockpit:panel
```

### Bar widget

![Bar widget in activity mode](images/widget.png)

*Activity mode, the default. The tooltip lists the live sessions and the
usage figures.*

- The glyph turns into a red bell when a session waits for you.
- One dot per running session: red needs you, accent is working, grey is
  idle. After 8 dots it shows `+N`.
- Rings and percentages show the 5-hour session and the 7-day weekly
  window. They turn amber or red when usage runs ahead of the clock.

Set `display_mode` to `classic` for the glyph and percentages only.

### Live

See the screenshot at the top. Sessions are grouped into *Needs you*,
*Working* and *Idle*. Each card shows the title, the time in its state, the
path and git branch, what it waits for, the last prompt, the model, the
context size and the cost. Click a card to focus its terminal (niri, Hyprland
and Umbriel). The globe opens the session on claude.ai while Remote Control is
on.

### Usage

![Usage tab](images/usage.png)

*Everything fits on one screen. Each section has a coloured title and a
glyph: plan limits (with pace and reset time under each title), token
consumption, models this week and daily activity.*

Cost is an estimate from token counts and public prices, in the currency
you choose.

### Sessions

![Sessions tab](images/sessions.png)

*Every past session, grouped by project. Session titles are blurred in this
screenshot.*

Click a session to resume it (`claude --resume <id>`) in a terminal, in its
project directory. The search box filters by title, prompt or path.

| Key      | Action                                                      |
| ---      | ---                                                         |
| ↑ / ↓    | Move the selection through projects and sessions. Hold to repeat. |
| `Return` or keypad `Enter` | Resume the selected session, open or close the selected project, or draw more sessions when **Show N more** is selected. |

A project draws its first 20 sessions. When it has more, a **Show N more**
row ends the list: ↑ / ↓ reach it like any other row, and `Return` (or a click)
draws the next 20.

The list scrolls to keep the selection in view. The keys work on this tab
only.

Each row shows the date and time of the last update, then the time since.
A glyph marks a running session, and the project that holds one, even when
the project is closed.

A glyph marks a session that cannot resume as it is. Its tooltip gives the
reason:

- **Moved**: you renamed or moved the folder. The panel finds the new folder
  and resumes the session from there.
- **Orphan**: no folder matches the session. The tooltip says when the project
  folder still has memory files.
- **Misplaced**: the transcript is in a project folder that matches no
  folder, but its recorded working directory exists.
- **Unknown**: the scan could not check the folder.

An orphan, misplaced or unknown session does not resume from the panel.

Buttons on a session row:

- Copy puts `cd <dir> && claude --resume <id>` on the clipboard.
- The pencil renames the session with the same title `/rename` gives. Not for
  a running or orphan session.
- The repair button moves a misplaced transcript into the project folder of
  its working directory, after a confirm. It never creates a folder and never
  overwrites a file.
- The trash now also deletes the `session-env` and `file-history` folders of
  the session, when no other transcript has the same id.

Buttons on the filter row:

- **Date** and **Name** sort the projects and their sessions. Date puts the
  newest first, Name goes from A to Z. **Count** sorts the projects by their
  number of sessions, most first. Click the active button again to reverse
  the order.
- **Empty (n)** shows only the empty sessions. Claude Code leaves one behind
  when you open it and close it before you send a prompt. An empty session
  has an *empty* tag, and clicking it does nothing, because there is nothing
  to resume.
- The moved button and the orphan button (orphan and misplaced sessions)
  show only their sessions, with a count.
- The refresh button reads the sessions again.
- The bin button deletes every empty session, after a confirm. A running
  session is never deleted, even when it has no prompt yet.
- **Orphans** finds the leftovers of deleted sessions: `session-env` and
  `file-history` folders without a transcript, and project folders with no
  session. Only items older than 1 day count. **Show** lists them, **Yes**
  deletes them.

![Delete empty sessions](images/sessions-empty.png)

*The empty filter and the delete confirm.*

### CLAUDE.md

![CLAUDE.md tab](images/claude-md.png)

*Every CLAUDE.md in your home directory. Paths are blurred in this
screenshot.*

The list also has a row for each session project without a CLAUDE.md, so
you can create one. Network mounts and noise folders (`.git`,
`node_modules`, `.cache`, `.venv`) are skipped.

### Skills/Mods

![Skills/Mods tab](images/skills-mods.png)

*Installed plugins grouped by marketplace, with the install box at the
bottom.*

- Skills and mods are Claude Code plugins, so this tab drives
  `claude plugin`. Bare skill folders in `~/.claude/skills` are listed too.
  You can only remove them.
- **Check updates** fetches every marketplace and marks a plugin with a
  newer version as `old → new`. It installs nothing.
- Removing a marketplace also uninstalls its plugins.
- The install box takes `plugin@marketplace` to install a plugin, or
  `owner/repo`, a git URL or a path to add a marketplace.
- Restart Claude Code to apply plugin changes.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `usage_refresh_interval` | `int` | `2` | Minutes between usage fetches (2–15). |
| `currency` | `select` | `auto` | Cost currency: `auto` follows the locale, or one of `usd`, `eur`, `gbp`, `jpy`, `cny`, `chf`, `aud`, `cad`, `inr`. |
| `currency_api_url` | `string` | `https://api.frankfurter.dev/v1/latest` | Exchange-rate API for non-USD currencies. |
| `terminal` | `string` | `""` | Terminal to resume a session in. Empty uses `$TERMINAL`, then the usual emulators. |
| `editor_command` | `string` | `""` | Command to open a CLAUDE.md. Empty tries `code`, then `zed`. |
| `display_mode` | `select` | `activity` | Widget mode: `activity` (dots, rings, percentages) or `classic` (glyph and percentages). |
| `glyph` | `glyph` | `robot` | Widget glyph. |
| `usage_percent_display` | `select` | `both` | Windows the widget shows, in both modes: `session` (`sNN%`), `weekly` (`wNN%`), `both`, or `none`. |

## Notes

What the plugin touches:

- **Reads** `~/.claude/sessions/*.json` and the transcripts of running
  sessions, every 2 seconds, only while the widget is in activity mode or
  the Live or Sessions tab is open. A transcript is parsed again only when it changes.
  The Usage and Sessions tabs read the other transcripts in small slices.
  To find a moved folder, the Sessions scan lists only the folders on the
  path that its project folder name gives.
- **Reads** `~/.claude/.credentials.json` for the token of the usage query.
- **Writes** two caches you can delete: `~/.claude/pricing-cache.json` and
  `~/.claude/usage-cache.json`. In the plugin data dir: `live/` (session
  stats) and `rings/` (widget ring images).
- **Network**: the Anthropic usage API, the LiteLLM price table and the
  exchange-rate API, all over HTTPS. The Sessions and CLAUDE.md tabs make
  no network calls.
- **Spawns** the plugin's own scripts through `bash`, `claude plugin` on a
  click in the Skills/Mods tab, your terminal, your editor, `xdg-open`, and
  `niri msg`, `hyprctl` or `umbriel msg` to focus a window (window ids and pids only,
  never titles).
- **Writes** to a transcript only on a rename: one `custom-title` line at
  the end, the same line `/rename` writes. **Moves** a misplaced transcript
  only on a repair, after an inline confirm.
- **Deletes**, always after an inline confirm: a session transcript and its
  `session-env`/`file-history` folders (trash glyph on its row), all empty
  sessions at once (bin button on the filter row, running sessions kept),
  orphan leftovers (**Orphans** button), a plugin or marketplace (through `claude plugin`), a local skill
  folder (a symlink loses the link only).

The Usage engine, `get-claude-usage`, is copied (MIT) from
[jrohland/claudecode](https://github.com/jrohland/noctalia-v5-claudecode),
reading only the default `~/.claude` account. See its header comment and
`LICENSE`.

Localized in English. Translations are welcome through
[Noctalia Translate](https://i18n.noctalia.dev).

## License

[MIT](LICENSE)
