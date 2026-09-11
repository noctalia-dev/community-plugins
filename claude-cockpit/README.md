# Claude Cockpit

Keep an eye on your Claude Code subscription and manage every local session
from the bar: rate-limit windows and token cost, every session on the
machine grouped by project with one click to resume it in a terminal, and
quick access to edit CLAUDE.md files (global and per project) in your own
editor.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/claude-cockpit` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

The `service` entry is headless and owns the usage fetch loop; `panel` is a
thin client of its published state for the Usage tab, and fetches sessions
and CLAUDE.md data itself, on demand, for its other two tabs.

## Requirements

- `jq` and `curl` on `PATH` — required for the Usage tab (the service checks
  for both and reports a status instead of running when either is missing).
- `bash`, plus the base userland `get-claude-usage` and
  `list-claude-sessions` call: `find`, `stat`, `grep`, `tac`, `awk`, `head`,
  `tail`, `rm`. These ship with coreutils, findutils, gawk, grep and bash on
  every supported distribution.
- An authenticated Claude Code install for the Usage tab, i.e.
  `~/.claude/.credentials.json` exists. Sessions and CLAUDE.md work
  regardless.
- `code` or `zed` on `PATH` to open a CLAUDE.md from the panel (or set
  `editor_command` to something else).

## Usage

Add the **Claude Cockpit** widget to a bar from the Add-widget picker. Click
it to open the panel:

```sh
noctalia msg panel-toggle nightwatch75/claude-cockpit:panel
```

The panel has three tabs:

- **Usage** — rate-limit windows (5-hour session, 7-day plan-wide week, and a
  model-scoped week when the plan has one), token consumption for today,
  this week and this month with estimated cost, a Monday-to-Sunday activity
  chart (hover a bar for that day's detail), a per-model breakdown and
  all-time session/message stats.
- **Sessions** — every local Claude Code session, grouped by the project
  (working directory) it ran in, most recent first. Click a session to
  resume it (`claude --resume <id>`) in a terminal, opened in that project's
  directory. The brain glyph opens that project's `CLAUDE.md` in the editor
  (offering to create it if missing); the eye glyph expands a preview (the
  session's opening prompt); the trash glyph deletes the session's transcript
  after an inline confirm. The
  search box filters by title, opening prompt or project path. Fetched when the
  tab is first opened and on the header refresh button — never polled in the
  background.
- **CLAUDE.md** — the global file, every CLAUDE.md `find-claude-md` finds
  under `$HOME` (symlinks to e.g. `AGENTS.md` included, noise dirs — `.git`,
  `node_modules`, `.cache`, `.venv` — and remote/network mounts excluded),
  plus one row per session-linked project that has none yet so it can still
  be created. Each row has a badge and a button that opens it in your editor.

Rename is deliberately not offered: Claude Code has no command to rename a
session after it is created, so there is nothing this panel could persist
that Claude's own `/resume` picker would also show. A session's label is its
AI-generated title, or its last prompt cut short when no title exists yet.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `usage_refresh_interval` | `int` | `2` | Minutes between background usage fetches (2–15). |
| `currency` | `select` | `auto` | Cost display: `auto` follows the locale, or force one of `usd`, `eur`, `gbp`, `jpy`, `cny`, `chf`, `aud`, `cad`, `inr`. |
| `currency_api_url` | `string` | `https://api.frankfurter.dev/v1/latest` | Exchange-rate API `get-claude-usage` fetches non-USD rates from (ECB rates via Frankfurter by default). |
| `terminal` | `string` | `""` | Command to open a terminal for resuming a session. Empty uses the system's own terminal discovery ($TERMINAL, then the usual emulators). |
| `editor_command` | `string` | `""` | Command to open a CLAUDE.md file. Empty tries `code`, then `zed`. |
| `glyph` | `glyph` | `robot` | Bar widget glyph. |
| `usage_percent_display` | `select` | `both` | What rides beside the glyph: `session` (`sNN%`, the 5-hour window), `weekly` (`wMM%`, the 7-day window), `both`, or `none`. |

## Notes

What this plugin touches, so nothing is a surprise:

- **Reads** `~/.claude/.credentials.json` for the OAuth token that
  authorizes the usage query, `~/.claude/stats-cache.json` for all-time
  session/message stats (Usage tab only), and every
  `~/.claude/projects/**/*.jsonl` session transcript — never a whole file,
  only small `grep`/`tac`+`awk` slices, since a single line in one of these
  files can itself be hundreds of KB.
- **Writes** `~/.claude/pricing-cache.json` (LiteLLM model prices + currency
  rates, refreshed daily) and `~/.claude/usage-cache.json` (the rate-window
  API response, cached 120s) — both Usage tab only, both disposable caches
  safe to delete.
- **Network**: the Anthropic usage API for your account's rate windows;
  LiteLLM's public model-price table to cost the tokens; the `currency_api_url`
  exchange-rate API (Frankfurter/ECB by default) for USD to the configured
  currency. All over HTTPS, on the usage refresh interval — the Sessions and
  CLAUDE.md tabs make no network calls.
- **Spawns** `get-claude-usage`, `list-claude-sessions` and `find-claude-md`
  through `bash`; `claude --version` (Usage tab, to set the API's
  `User-Agent`); a configured or auto-discovered terminal to resume a
  session; `code`/`zed` (or `editor_command`) to open a CLAUDE.md.
  `find-claude-md` walks `$HOME` on the CLAUDE.md tab's first open and its
  refresh button only, never on a timer — remote/network mounts (NFS, SMB,
  sshfs, and similar) under `$HOME` are detected via `/proc/mounts` and
  excluded, so a stalled share cannot stall it.
- **Deletes** files: the trash glyph on a session removes its
  `<uuid>.jsonl` transcript and, if present, its `<uuid>/` subagent sidecar
  directory — after an inline confirm, never without one.

The Usage tab's data engine, `get-claude-usage`, is copied (MIT) from
[jrohland/claudecode](https://github.com/jrohland/noctalia-v5-claudecode)
with the Frankfurter exchange-rate API URL updated (`frankfurter.app` moved
to `frankfurter.dev`) and its Claude Code Switch (`~/.ccs/instances`)
multi-account scan removed — this plugin only ever reads the default
`~/.claude` account; see its own header comment and this plugin's `LICENSE`
for attribution. This plugin's own `shared.luau` is a trimmed port of its
formatters, same account scope.

Localized in English. Translations for other locales are welcome through
[Noctalia Translate](https://i18n.noctalia.dev).

## License

[MIT](LICENSE)
