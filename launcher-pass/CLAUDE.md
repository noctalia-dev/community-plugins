# CLAUDE.md

Guidance for working on **launcher-pass**, a [Noctalia](https://noctalia.dev) v5
launcher-provider plugin. Written in [Luau](https://luau.org/) against the
Noctalia plugin runtime; no build step, no test suite (the host loads
`launcher.luau` directly). Noctalia shell sources:
<https://github.com/noctalia-dev/noctalia>.

The plugin browses a [GNU Pass](https://www.passwordstore.org/) store from the
launcher and copies or auto-types passwords, OTP codes, usernames, and arbitrary
fields.

---

## Files

```
launcher-pass/
├── plugin.toml          manifest: id, plugin_api, dependencies, [[setting]] × 9, [[launcher_provider]]
├── launcher.luau         the whole feature (one entry script)
├── translations/         en.json (canonical) + 10 locales, nested JSON, identical key set
│   └── en it
├── README.md            the plugin's public page (follows the repo's README_TEMPLATE.md)
└── thumbnail.webp       plugin-store card image
```

`plugin_api = 26` — the highest-level runtime call used is `noctalia.getSetting`
(reads `shell.launcher.provider_prefix`). Bump only if a change pulls in
something newer.

---

## New features

New proposed features that are to be implemented:

### Autotype action

Add an optional autotype action that will perform automatic insertion of all login details, this action will perform the following steps:

1. Type username
2. Type separator character (configurable, default: `<tab>`, it can also be `<enter>`)
3. Type password
4. Type `<enter>`
5. If OTP is available:
    1. Type OTP
    2. Type `<enter>`

Step 4. can be disabled via a dedicated option, if OTP is available it will be step 5.2. to be disabled instead.

### Quick action shortcuts

Add new shortcuts that will let the user perform the following actions without the need to open the details view while highlighting a password:

- Type/Copy password
- Type/Copy username
- Type/Copy otp
- Autotype action

### Generate password action

Add a "Generate" option to details view that will ask for confirmation ad after approval it will generate a new password with `pass generate -i` and keep the launcher open to let the user copy or type the new password.

### Creation menu

Add a "New" option to folder view that will open a submenu letting the user create a new password entry in the current path (editable).
The new password will be created with `pass generate` and opened with `pass edit` straight afterwards. As soon as the `pass edit` command returns, the launcher will show the details view for the new password.

---

## How `launcher.luau` works

The host calls two globals — `onQuery(text)` on every keystroke (after
`debounce_ms`) and `onActivate(id)` when a row is picked — and the script pushes
rows back with `launcher.setResults(query, rows)` / rewrites the input with
`launcher.setQuery(text)`. `text` is everything after the launcher's provider
prefix + `pass ` (e.g. `/pass `). Everything else is `local`; the VM persists for
the plugin's lifetime, so module locals survive across calls.

### Navigation is encoded in the query string, not module state

`onQuery` routes on the shape of `text`:

| `text` | meaning |
|---|---|
| `""` | browse the store root |
| `foo` | search the whole store for `foo` |
| `work/aws/` | browse inside folder `work/aws` (trailing `/`) |
| `work/aws/pr` | search inside `work/aws` for `pr` |
| `:work/aws/root ` | detail view of entry `work/aws/root`, empty row filter |
| `:work/aws/root otp` | detail view, row filter `otp` |

`splitPath` peels the folder (up to the last `/`) from the search term. A leading
`:` — never produced by browsing — marks detail mode. Module locals are caches
only (`indexReady`/`indexAt`, `detailCache`, `lastDetailPath`, `detailActions`,
`lastQuery`). Drill-in / back are `launcher.setQuery(...)`; a bare `""` does not
re-fire `onQuery`, so root "Go back" uses `" "` (trims to empty).

### Listing — index file + grep

Filtering must not run in Luau: the host aborts an async callback after **25 ms**
(and module load after 100 ms). So:

- **`buildIndex`** runs, once, `find <store> -mindepth 1 -name '.*' -prune -o
  -type f -name '*.gpg' -printf '%P\n' -o -type d -printf '%P/\n' >
  <pluginDataDir>/store.index` (shell string, redirected). The callback only sets
  `indexReady` / `indexAt` — negligible Luau, safe at load. Rebuilt in the
  background once past `INDEX_TTL_MS` (60 s); the current file is grepped
  meanwhile. `%P` = path relative to the store root; trailing `/` marks a folder.
- **Every `onQuery`** greps that file in a subprocess (off the CPU budget):
  - search → `searchGrepCmd`: `grep -iF -e <f1> file | grep -iF -e <f2> | … |
    head -n SCAN_CAP` (500). The `-iF` AND-chain is the fixed-string /
    case-insensitive / all-fragments / order-independent match.
  - browse → `browseGrepCmd`: `grep -E '^<reEsc folder>/[^/]+/?$' file | head -n
    BROWSE_CAP` (2000) — exact direct children; root pattern `^[^/]+/?$`.
- **`parseHits`** turns the capped grep output into `{fullPath, isDir}` (`.gpg`
  stripped here).

### Ranking — cheap prerank, then a bounded fuzzyScore pass

`renderSearchRows`:

1. Re-check `matchesFragments` against each hit's path **relative to `folder`**
   (grep matched the raw line; a search inside `work/` must match against
   `aws/root`, not `work/aws/root`).
2. `prerank(relLower, frags)` — pure Luau, no C crossings, run over every match →
   `(segHits, depth)`: fragments equal to a whole `/`-bounded segment, then
   segment count.
3. Sort by `(segHits desc, depth asc, rel asc)`, take the top `SCORE_POOL` (64).
4. `fuzzySum` = `Σ noctalia.fuzzyScore(fragment, relLower)` over just those 64 —
   the host's native fzy scorer (case-insensitive; exact match = 1024; prefix /
   word-boundary / consecutive-run bonuses). Re-sort by `(fuzzySum desc, depth
   asc, rel asc)`, take `MAX_RESULTS` (50).

`fuzzyScore` is only called ≤ `SCORE_POOL` times per keystroke — each call
crosses into C with a ~26 KB fzy stack frame, so scoring *every* hit of a broad
query blows the budget. Only the visible page is fully fzy-ordered.

`renderBrowseRows` is simpler: the grep already returned exactly the direct
children, so it just sorts by basename and caps.

Rows: `entryRow(e, title)` → `{id = "nav:"..path | "entry:"..path, title,
subtitle, glyph, query? = path.."/"}`. Search rows show the folder-relative
path; browse rows the basename.

### Detail mode

`onActivate` on an `entry:<path>` row does `launcher.setQuery(":" .. path ..
" ")` (trailing space → empty row filter, ready to type into).

- **`splitDetailQuery(rest)`** peels `<entryPath>` from an optional trailing
  `<rowFilter>`. An entry path can contain spaces, so it does not split on the
  first space: it tries `lastDetailPath` first, then every warm `detailCache`
  key (longest match wins), matching `rest == p` or `rest` starting with
  `p .. " "`; nothing known yet → the whole trimmed `rest` is the path, filter
  empty. Degrades to "no filter" if the host ever strips the trailing space.
- **`fetchDetail(entryPath, text, filter)`** — cache hit (60 s TTL) renders
  immediately; otherwise a "Decrypting…" row, then `pass show` (see pinentry
  dance). `parsePassEntry` → first non-empty line = password; later lines split
  on the first `": "` into `key`/`value`; any `otpauth://` sets the OTP flag.
  `extractUsername` pulls the first `login` / `user` / `username` field
  (case-insensitive), removes it from the field list, falls back to the entry
  basename.
- **`renderDetailRows(entryPath, data, filter)`** builds a `specs` list in the
  fixed value order — **password, OTP (only if the body had `otpauth://`),
  username, then remaining fields in file order** — plus a "Go back" row. The
  Copy/Type rows within that are laid out per `detailActionOrder` (which verb
  first) and `detailActionGrouping` (pair per value, or all-Copy-then-all-Type).
  `actionRow(entryPath, spec, verb, n)` returns one row and records its context
  in `detailActions["act:"..n]` (an explicit counter). Type rows are omitted
  entirely when `wtype` is absent (`wtypeAvailable`, memoised). An **Edit** row
  (`id = "edit:"..entryPath`) is appended after all the Copy/Type rows, before
  the "Go back" row — omitted when `terminalArgv()` returns nil (no terminal
  resolvable). It is not an `act:` row: `onActivate` dispatches it straight to
  `editEntry`, no `detailActions` entry.
- **Row filter** — a non-empty `filter` fuzzy-narrows the rendered rows by
  `title` with the same `matchesFragments` rule (`:<path> otp` → only the OTP
  rows). `detailActions` is populated for every row *before* filtering, so
  activating a still-visible narrowed row always resolves. The "Go back" row is
  filtered too (deliberate divergence from browse, which keeps its back row).
- **`onActivate`** on an `act:<n>` row reads `detailActions[id]` and hands the
  `{entryPath, verb, kind, key, value, label}` context to `runAction`, which
  branches on `verb` then `kind`.

### Copy / Type actions

`storeDir()` = `storePath` setting or `~/.password-store` (expanded).
`passArgv(cmd, withClip, extraEnv)` builds `{"env", "PASSWORD_STORE_DIR="..dir,
["PASSWORD_STORE_CLIP_TIME="..t,] [<extraEnv…>,] <cmd...>}`. `extraEnv` is an
optional list of extra `KEY=VAL` argv elements — only the Edit action uses it,
to pass `EDITOR=<editorCommand>`. `clipTimeout()` resolves the clip timeout:
`clipTimeout` setting (positive int) → `PASSWORD_STORE_CLIP_TIME` env (positive
int) → nil (let `pass` default).

| Action | Path |
|---|---|
| Copy Password | `copyViaPass({"pass","-c",entryPath})` |
| Copy OTP | `copyViaPass({"pass","otp","-c",entryPath})` |
| Copy Username / field | `copyPlain(ctx.value)` |
| Type Password / Username / field | `typeViaWtype(ctx.value)` |
| Type OTP | `typeOtp(entryPath)` — `pass otp` (no `-c`) → `typeValue(code)` |

- **`copyViaPass`** closes the launcher first (so a pinentry prompt from an
  expired gpg-agent cache gets focus — no reopen dance), runs the command with
  `DECRYPT_TIMEOUT_MS`, and posts `notification.copied` / `notification.copyFailed`.
  `pass -c` / `pass otp -c` do the clipboard auto-clear themselves.
- **`copyPlain`** — `noctalia.copyToClipboard(value or "", "text/plain")` (the
  MIME arg is mandatory), `notification.copied`, close launcher. No auto-clear.
- **`typeValue(value)`** — `runAsync({"sleep", <typeDelay/1000>})` then
  `runAsync({"wtype", "-d", <wtypeDelay>, "--", value})`. Argv only: the value
  after `--` is literal text even if it starts with `-`, so no `printf | wtype -`
  pipe and no shell escaping. `typeViaWtype` closes the launcher first (wtype
  types into the focused window); the `typeDelay` sleep lets the compositor
  restore focus. Failures → `notification.typeFailed`.
- `typeDelay` / `wtypeDelay` are **milliseconds** (`intSetting`, 0 allowed).

### Edit action

`editEntry(entryPath)` closes the launcher (never reopens — `pass edit` runs
`$EDITOR` and may pop pinentry, both want the keyboard) and runs
`<term…> env PASSWORD_STORE_DIR=… [EDITOR=<editorCommand>] pass edit
<entryPath>`. `editorCommand` is passed to `passArgv` as its `extraEnv` arg only
when non-empty — blank leaves `EDITOR` unset. The term prefix is
`terminalArgv()`: the `terminalCommand` setting split on whitespace (a full argv
prefix that takes a command, exec flag included — `foot -e`, `gnome-terminal
--`); else `{$TERMINAL, "-e"}`; else `{<first of TERMINAL_CANDIDATES on PATH>,
"-e"}` (`detectedTerminal`, memoised like `wtypeAvailable`); else nil. On the
`runAsync` callback `detailCache[entryPath]` is cleared so the next detail view
re-decrypts the edited file. No `runAsync` timeout — an interactive edit is
open-ended. When `terminalArgv()` is nil the row was never rendered; a
defensive `editEntry` call still fires `notification.edit-failed`.

**Native auto-paste is not reachable from a plugin.** `LauncherPanel::finishActivation()`
in the Noctalia source fires `shell.launcher.auto_paste` only when
`provider.supportsAutoPaste()`, which `PluginLauncherProvider` never overrides;
there is no manifest key / `noctalia.*` call / `noctalia msg` command to flip it.
`wtype` is the only insertion path this plugin has.

### The pinentry dance

The launcher panel is a layer-shell surface with an exclusive keyboard grab, so a
GPG pinentry dialog `pass show` pops on a locked store can't get focus while the
panel is open. There is no `noctalia.*` call to hand focus to an arbitrary
window, so the panel is closed and reopened via CLI IPC:
`noctalia msg panel-close launcher` / `noctalia msg panel-open launcher
<context>` (safe to call when already closed).

`fetchDetail` races `pass show` (`runAsync(passArgv{...}, cb,
DECRYPT_TIMEOUT_MS)` — 5 min, a safety net for a slow passphrase / hardware key)
against a `{"sleep", <pinentryGraceMs/1000>}` (default 50 ms — lower values let a
real pinentry dialog take focus more easily but flicker the launcher more often;
higher values, ~200/300 ms, keep the launcher steadier but give a pinentry
dialog more time to spawn while the panel is still open, and depending on the
window manager it may then fail to get focus at all). If `pass show`
wins, gpg-agent had the passphrase cached, no dialog appeared, the panel is never
touched — no flicker. If the sleep wins, the panel is closed; when `pass show`
finally resolves **successfully** it reopens with context `<leader> .. "pass " ..
text`, which the host re-delivers as a fresh `onQuery` that finds the now-warm
`detailCache` and re-renders. `<leader>` is
`noctalia.getSetting("shell.launcher.provider_prefix")` (fallback `">"`) —
**never hardcode it**, or the reopened context isn't recognised as a command.
`copyViaPass` / `typeViaWtype` sidestep all this by closing the launcher up front
and never reopening.

The reopen is **conditional on the decrypt succeeding**. If `pass show` exits
non-zero (the user dismissed the pinentry dialog, or gpg errored) or times out,
the panel stays closed — that is the graceful exit. Reopening on failure would
re-fire `onQuery` → `fetchDetail` → a fresh `pass show` (the failure is never
cached) with nothing user-driven in between, looping the pinentry prompt
forever. Retrying is then an explicit act: the user reopens the launcher.

---

## Behaviour contract

Do not regress these without a deliberate reason:

1. **Prefix** — activates only on the provider prefix + `pass` / `pass <query>`;
   a bare `pass ` lists the store root.
2. **Match semantics** (`matchesFragments`) — lowercase, split the query on
   whitespace, **every fragment must be a contiguous substring** of the target
   (spaces act as wildcards between fragments), order-independent, non-match
   excluded. `string.find(hay, frag, 1, true)` (plain, not a pattern). Used for
   search *and* the detail row filter.
3. **Detail rows** — Copy Password, Copy OTP (**only if** the body has
   `otpauth://`), Copy Username, then Copy for each remaining `key: value` field
   in file order; a Type counterpart for each when `wtype` is present; an "Edit"
   row after all of those when a terminal resolves (`terminalArgv()`); a "Go
   back" row. Order/grouping of Copy vs Type per `detailActionOrder` /
   `detailActionGrouping`; value order is fixed.
4. **Username** — the value of the first `login` / `user` / `username` field
   (case-insensitive), or the entry's basename if none. That field is not also
   shown as a generic field row.
5. **Pass entry parse** — first non-empty line = password; later lines split on
   the first `": "`; `otpauth://` anywhere → OTP flag.
6. **Clipboard timeout** — `clipTimeout` setting (positive int) wins, else
   `PASSWORD_STORE_CLIP_TIME` env, else `pass`'s default. Applies to Copy
   Password / Copy OTP (`pass -c` / `pass otp -c`).
7. **Typing** — `sleep(typeDelay/1000)` then `wtype -d <wtypeDelay>`. Both are ms.
8. **Store path** — `storePath` setting or `~/.password-store` (expanded),
   exported as `PASSWORD_STORE_DIR` on every `pass` call.
9. **OTP copy vs type** — `pass otp -c` for copy (with clip env), `pass otp` +
   `wtype` for type.
10. **Notifications** — a "Copied to clipboard" notice after a successful copy.
11. **i18n** — no hard-coded user-facing strings; every string through
    `noctalia.tr`, every key in every locale file.

---

## Design decisions

Choices made during the QML→Luau rewrite and later, with the reasoning that
should survive into future changes:

- **`plugin_api = 26`.** Lowest level that supplies everything used; the ceiling
  at time of writing is 28. `noctalia.getSetting` (for the launcher leader) is
  what set the floor at 26.
- **Settings are top-level `[[setting]]` blocks**, not
  `[[launcher_provider.setting]]`. The manifest docs only document nested
  settings for `widget`/`panel`, and every sibling launcher plugin uses top-level
  blocks; for a launcher-only plugin the two are equivalent. `select` settings
  use inline-table `options = [{ value, label_key }, …]`, each `label_key` a
  `settings.<key>.options.<value>` translation key. The setting `key` stays
  camelCase (`detailActionOrder`), but **translation keys must be kebab-case**
  (`settings.detail-action-order.options.copy`) — the plugin-store validator
  rejects any uppercase or dotted-into-one segment in `translations/*.json`
  keys and in `label_key` / `description_key` values.
- **Nine settings.** `storePath` (folder), `clipTimeout` (string — kept a string
  so `""` means "fall back to env"), `typeDelay` / `wtypeDelay` /
  `pinentryGraceMs` (int, `advanced`), `detailActionOrder` /
  `detailActionGrouping` (select, `advanced`), `terminalCommand` (string,
  `advanced` — `""` means auto-detect the terminal for the Edit action),
  `editorCommand` (string, `advanced` — `""` means don't export `EDITOR`, let
  `pass edit` use its own default). Read back with `noctalia.getConfig(key)`;
  defaults come from the manifest.
- **Navigation state lives in the query string**, not module locals — a trailing
  `/` for a folder context, a leading `:` for detail mode. Reopening the launcher
  resets to the store root for free (no `onOpened`-style hook exists in v5).
  Module locals are caches only.
- **Detail path/filter boundary resolved against known paths.** `:<path> <filter>`
  can't split on the first space because a path may contain spaces;
  `splitDetailQuery` uses `lastDetailPath` then `detailCache` (longest match).
  This also fixed a bug where typing anything in an open detail view turned the
  whole string into a bogus entry path and fired a `pass show` per keystroke.
- **Row actions dispatch via a module-local `detailActions` table**, keyed by an
  opaque `act:<n>` id, not by encoding `{verb, kind, key, value}` into the id
  string (field keys/values can contain anything). Only one detail view is live,
  so the table is rebuilt on every render, not namespaced.
- **Store index is a file that grep filters per keystroke.** Two earlier designs
  failed: (a) `find <store> | grep | head` per distinct query re-walked the whole
  tree; (b) an all-in-Luau index (`find` → parse into a Lua array → filter in
  `onQuery`) blew the 25 ms budget (parsing ~1.5 k lines at load, and
  `matchesFragments` over the array per keystroke). The file + subprocess-grep
  design keeps all filtering in C, off the budget, and re-walks the tree only on
  the background refresh. Caps: `SCAN_CAP` 500 (search), `BROWSE_CAP` 2000
  (browse), `SCORE_POOL` 64, `MAX_RESULTS` 50.
- **Ranking = cheap `prerank` over all hits, then `noctalia.fuzzyScore` over the
  top `SCORE_POOL` only.** fzy scoring every hit (each call a Lua→C crossing with
  a ~26 KB stack frame) blew the budget on a broad query. `fuzzyScore` is summed
  *per fragment* (not one whole-query fzy pattern) to keep the match
  order-independent and the inter-fragment space a wildcard. `noctalia.fuzzyScore`
  is subsequence/order-dependent, so it can only *rank*, never *match* — matching
  stays `matchesFragments`.
- **`typeValue` passes the secret as a positional arg after `wtype … --`**, not
  over a `printf %s '<val>' | wtype -` pipe. Argv-only means no shell, no
  single-quote escaping, and a value with a leading `-` is still literal text.
- **Copy/Type close the launcher up front and never reopen.** QML did the same
  (`launcher.close()` before `pass -c`); with the panel gone a pinentry prompt
  gets focus on its own, so these paths skip the close/reopen dance that
  `fetchDetail` needs.
- **The pinentry close only happens if `pass show` is still running after
  `pinentryGraceMs`** — a race, not an unconditional close — so a cached
  passphrase produces no flicker.
- **`<leader>` (`shell.launcher.provider_prefix`, `/` by default) is read at
  runtime.** The one value in the pinentry reopen that must never be hardcoded.
- **`translations/*.json` is nested JSON.** `noctalia.tr("settings.store-path.label")`
  resolves the dotted key against the nesting — how the working sibling plugins
  are shaped. `en.json` is canonical; every key must exist in all 11 locales
  (verified by regenerating all of them from one source whenever keys change).
- **Native auto-paste** — verified unreachable from a plugin (see the pinentry /
  actions sections). `wtype` is the fallback; a native path would need an
  upstream `auto_paste` flag on the `[[launcher_provider]]` manifest block.

---

## Noctalia plugin runtime reference

### Launcher-provider contract

| Hook / call | Purpose |
|---|---|
| `function onQuery(text)` | keystroke handler; `text` is everything after the prefix (subject to `debounce_ms`) |
| `function onActivate(id)` | row picked; `id` is the string set on that row |
| `launcher.setResults(query, rows)` | publish rows; `query` **must echo** the answering `onQuery` text so stale async results are dropped; `{}` clears |
| `launcher.setQuery(text)` | rewrite the launcher input, keep it open, re-fire `onQuery` (drill-in / back). A bare `""` does not re-fire. |

Row fields: `id`, `title`, `subtitle?`, `glyph?` (Tabler name), `icon?`,
`badge?`, `query?` (set the input on activate instead of calling `onActivate`),
`score?` (sort key, desc; ties on insertion order — not used here, insertion
order is already the sorted order).

### `noctalia.*` calls used

| Call | Notes |
|---|---|
| `runAsync(argvOrString, cb [, timeoutMs])` | argv array = no shell; string = `sh -c`. `cb` gets `{exitCode, stdout, stderr, timedOut, stdoutTruncated, stderrTruncated}`. 3rd arg (undocumented but established across sibling plugins) bounds the run. No `env` option — prepend `env KEY=VAL …` argv elements. |
| `getConfig(key)` | manifest setting value (default from the manifest) |
| `getSetting("shell.launcher.provider_prefix")` | host config; `plugin_api ≥ 26` |
| `getenv(name)` / `expandPath(p)` | environment / `~` expansion |
| `copyToClipboard(text, mime)` | `mime` is **mandatory** (`"text/plain"`) |
| `notify(title, body)` / `notifyError(title, body)` | toasts |
| `fuzzyScore(pattern, text)` | fzy scorer; `nil` on no match, `1024` on exact, else a `double`. Subsequence/order-dependent. |
| `commandExists(name)` | probe optional deps (`wtype`) |
| `pluginDataDir()` | persistent per-plugin dir (the index file) |
| `nowMs()` | monotonic ms |
| `string.trim(s)` | (also a local `trim` in the script) |
| `tr(key [, tbl])` / `trp(key, count)` | i18n; `{name}` placeholders from `tbl` |
| `log(msg)` | debug log |

### CPU budget

The host aborts an async callback after **25 ms** (module load after 100 ms) with
`script callback '…' exceeded its CPU budget` and, on repeats, disables the
plugin. Keep per-callback Luau work minimal: push filtering/sorting of large sets
to subprocesses (`grep`), parse only capped output, cap C-boundary calls
(`fuzzyScore`). The budget is wall-clock, so headroom matters on a busy desktop.

### Subprocess rules

- **Argv array = no shell.** `{"pass", "show", entry}` — each element one literal
  arg, no quoting. Prefer this.
- **String form = `sh -c`.** Needed only for pipes / redirects (`find … > file`,
  the `grep -iF` AND-chain). `shq(s)` single-quote-escapes; `reEsc(s)` escapes
  ERE metachars for a `grep -E` pattern.

---

## Luau conventions & gotchas

- **1-based indexing.** `t[1]` first, `#t` length, `ipairs`/`pairs` to iterate.
- **`string.find` / `string.match` use Lua patterns, not regex.** `. - % ( ) [ ]
  + * ? ^ $` are magic. For a literal substring pass `plain = true`:
  `string.find(s, "otpauth://", 1, true)`. `%` escapes a magic char.
- **Concatenation is `..`.** `+` on strings errors.
- **Only `nil`, no `undefined`.** `x and a or b` is the ternary idiom (careful
  when `a` can be falsy). `a or default` for fallbacks.
- **`nil` holes break `#` and arrays.** Append with `t[#t+1] = v`.
- **Split/trim aren't built in.** `string.gmatch(s, "[^\n]+")` for lines,
  `"%S+"` for whitespace tokens.
- **`local` everything.** Only globals are host-callable; keep exactly `onQuery`
  / `onActivate` global.
- **Closures as callbacks** need `plugin_api ≥ 9` (covered).
- **Numbers are doubles.** `math.floor` / `tostring` / `tonumber` for int-ish
  conversions.
- **No wall-clock beyond `noctalia.nowMs()`.**

---

## Working on this plugin

### Testing (no test suite)

`luac5.4 -p launcher.luau` catches syntax errors. For behaviour, drive the real
script under `luau` with a mocked host: define `noctalia` and `launcher` as bare
globals (the CLI freezes `_G`, so `noctalia = {...}` not `_G.noctalia = {...}`),
stub `runAsync` to return captured `find` / `grep` output synchronously, then
call `onQuery("…")` / `onActivate("…")` and record `setResults` / `setQuery` +
time each call. Capture fixtures from the real store:
`find ~/.password-store -mindepth 1 -name '.*' -prune -o -type f -name '*.gpg'
-printf '%P\n' -o -type d -printf '%P/\n'`.

### Translations

Adding or changing a user-facing string: update `en.json`, then regenerate **all
existing** `translations/*.json` from a single source so the key sets stay identical
(nested JSON; `noctalia.tr` resolves dotted keys against the nesting). A
throwaway Python generator with a per-locale flat-key map + a nested template is
the way — keep `en.json` byte-identical whether hand-edited or generated.

### Workflow

- Define the next steps in brief clear text.
- If anything is unclear or has multiple interpretations, stop and ask.
- Prompt the user for a quick test of what changed, proposing a test sequence.
- Create a local commit detailing what changed and why, with the co-authored
  tag. **NEVER** perform any other git operation.
