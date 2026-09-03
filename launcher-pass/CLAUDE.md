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
├── plugin.toml          manifest: id, plugin_api, dependencies, [[setting]] × 12, [[service]], [[launcher_provider]]
├── launcher.luau         the whole feature — backs BOTH the [[launcher_provider]] (onQuery/onActivate) and the [[service]] (onIpc); separate VMs, one file
├── translations/         en.json (canonical) + 10 locales, nested JSON, identical key set
│   └── en it
├── README.md            the plugin's public page (follows the repo's README_TEMPLATE.md)
└── thumbnail.webp       plugin-store card image
```

`plugin_api = 26` — the highest-level runtime call used is `noctalia.getSetting`
(reads `shell.launcher.provider_prefix`). Bump only if a change pulls in
something newer.

---

## Open Points

As of now (`noctalia 5.0.0-beta9.3`, `plugin_api` 28), there are still some open points that will need to be covered when possible:

### wtype cmdline leak

Right now `noctalia.runAsync(cmdOrArgv)` does not let the plugin pass data to the supbrocess standard input, nor export environment variables, so the only way to pass the password/login/OTP/field values to `wtype` to perform autofill is by adding the values to the commandline, exposing them to external processes inspecting the `wtype` process commandline.

As soon as a more secure option is available, the `wtype` execution needs to be updated to a more secure variant.

### List item preselection

In every menu where the `Go Back` button is shown, the second item (the one after the back button) should be preselected at the submenu entry.

The current noctalia plugin api does not provide a way to do so, it should be implemented as soon as the plugin interface adds a method to preselect launcher list entries.

### Settings grouping

The plugin has a relevant number of settings, they should be grouped in logical sets inside the settings menu, as soon as the plugin api adds support for such customizations.

---

## How `launcher.luau` works

The host calls three globals — `onQuery(text)` on every keystroke (after
`debounce_ms`) and `onActivate(id)` when a row is picked (both in the
`[[launcher_provider]]` VM), plus `onIpc(event, payload)` for a `noctalia msg
plugin …:quick-actions …` call (in the `[[service]]` VM — see *Quick-action
IPC*). The script pushes rows back with `launcher.setResults(query, rows)` /
rewrites the input with `launcher.setQuery(text)`. `text` is everything after
the launcher's provider prefix + `pass ` (e.g. `/pass `). Everything else is
`local`; each VM persists for the plugin's lifetime, so module locals survive
across calls — but the two VMs share no Luau state (v5 has no plugin module
system), only `noctalia.state`.

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
| `:!work/aws/root ` | Generate confirm view for `work/aws/root` (`:!` checked before `:`) |
| `+work/aws/` | creation menu, editable new path pre-filled `work/aws/` |
| `+work/aws/new ` | creation menu, new path `work/aws/new` (has a leaf → "Create entry" row) |
| `+!work/aws/new ` | creation confirm view for `work/aws/new` (`+!` checked before `+`) |

`splitPath` peels the folder (up to the last `/`) from the search term. A leading
`:` — never produced by browsing — marks detail mode; `:!` the Generate confirm
view; `+` the creation menu and `+!` its confirm step (each `…!` variant matched
first). Module locals are caches
only (`indexReady`/`indexAt`, `detailCache`, `lastDetailPath`, `detailActions`,
`lastQuery`). The launcher VM also tracks a "current entry" (last entry opened /
acted on / narrowed to a single hit) and publishes it via
`noctalia.state.set(STATE_CURRENT_ENTRY, …)` (`setCurrentEntry`, deduped by
`lastPublishedEntry`) for the service VM's quick-action IPC — it is *not*
navigation state, nothing routes on it. Drill-in / back are
`launcher.setQuery(...)`; a bare `""`
does not re-fire `onQuery`, so root "Go back" uses `" "` (trims to empty).

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
   segment count. Also assign `group`: **0** = a folder whose *whole*
   folder-relative path was typed (`pathFullyTyped` — `frags` reconstruct the
   `/`-split `rel` one-for-one), **1** = a password file, **2** = any other
   folder.
3. Sort by `(group asc, segHits desc, depth asc, rel asc)`, take the top
   `SCORE_POOL` (64).
4. `fuzzySum` = `Σ noctalia.fuzzyScore(fragment, relLower)` over just those 64 —
   the host's native fzy scorer (case-insensitive; exact match = 1024; prefix /
   word-boundary / consecutive-run bonuses). Re-sort by `(group asc, fuzzySum
   desc, depth asc, rel asc)`, take `MAX_RESULTS` (50).

`group` is the primary key in both sorts, so folders never sit among the files
unless their full path was typed — a partial query like `aws` lists every
matching `*.gpg` first and drops the `work/aws/` folder below them; typing
`work/aws` floats that folder to the top. Non-exact folders past position 64
fall out of the pool and aren't rendered (acceptable — files own the slots).

`fuzzyScore` is only called ≤ `SCORE_POOL` times per keystroke — each call
crosses into C with a ~26 KB fzy stack frame, so scoring *every* hit of a broad
query blows the budget. Only the visible page is fully fzy-ordered.

`renderBrowseRows` is simpler: the grep already returned exactly the direct
children, so it just sorts by basename and caps. It also prepends a **"New
entry"** row (`id = "new:"..folder`, a `query` row to `"+"..folder.."/"`) after
"Go back" — the entry point to the creation menu (see below).

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
  basename. The `pass show` stdout → cache-record step is `buildEntryData`,
  shared with `withEntryData` (the non-rendering decrypt path used by the
  quick-action IPC and the Autotype row) so the two can't drift.
- **`renderDetailRows(entryPath, data, filter)`** builds a `specs` list in the
  fixed value order — **password, OTP (only if the body had `otpauth://`),
  username, then remaining fields in file order** — plus a "Go back" row. The
  Copy/Type rows within that are laid out per `detailActionOrder` (which verb
  first) and `detailActionGrouping` (pair per value, or all-Copy-then-all-Type).
  `actionRow(entryPath, spec, verb, n)` returns one row and records its context
  in `detailActions["act:"..n]` (an explicit counter). Type rows are omitted
  entirely when `wtype` is absent (`wtypeAvailable`, memoised). An **Autotype**
  row (`id = "autotype:"..entryPath`, `autotypeRowFor`) is spliced in right
  after the username's first rendered row — between the login values and the
  remaining-field rows — when the `autotypeEnabled` setting is on *and* `wtype`
  is present (in grouped mode it lands inside the first verb block, still
  between username and fields). Not an `act:` row: `onActivate` dispatches
  `autotype:` straight to `autotypeEntry`. An **Edit** row
  (`id = "edit:"..entryPath`) is appended after all the Copy/Type rows, before
  the "Go back" row — omitted when `terminalArgv()` returns nil (no terminal
  resolvable). It is not an `act:` row: `onActivate` dispatches it straight to
  `editEntry`, no `detailActions` entry. A **Generate** row
  (`id = "gen:"..entryPath`) follows the Edit row, always present. Activating it
  doesn't act: `onActivate` rewrites the query to `":!"..entryPath.." "`, which
  `onQuery` routes to `renderGenerateConfirmRows` — a Cancel (`query` row back
  to the detail view) / "Regenerate now" (`genrun:"..entryPath`) pair. None of
  `edit:` / `autotype:` / `gen:` / `genrun:` uses `detailActions`.
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

### Autotype action

`autotypeEntry(entryPath)` types a whole login in sequence with `wtype`. It is
reached both from the Autotype detail row (launcher open, `detailCache` warm)
and from the `autotype` quick-action IPC event (launcher closed, cache cold),
so it closes the panel up front and resolves the entry through `withEntryData`
(cache hit, or a fresh `pass show`); a failed decrypt → `notification.type-failed`,
no typing. Sequence:

1. `username`
2. the **separator key** — `autotypeSeparator`: `Tab` (default) or `Return`
3. `password`
4. `Return` — emitted when an OTP follows in step 5, **or** when `autotypeSubmit`
   is on
5. when `hasOtp`: `pass otp <entryPath>` (no `-c`) → type the code
   5.2. `Return` — emitted only when `autotypeSubmit` is on

So `autotypeSubmit` (default on) toggles just the **final** `Return`: after the
OTP when present, otherwise after the password.

Each step is its own `wtype` process, chained through `runWtypeSteps` (a first
failed step aborts the rest with one `notification.type-failed`): a text step is
`{"wtype","-d",<wtypeDelay>,"--",value}` (same `-- value` literal-text form as
`typeValue`), a key step is `{"wtype","-k",<keysym>}`. They are **not** merged
into one `wtype` call: `wtype` allows a single terminal `--` (everything after it
is text), so literal text and `-k` keys can't be interleaved safely for
arbitrary values. `autotypeEntry` closes the launcher first (like the Type
paths), then — after the OTP fetch, if any — a single `typeDelay` sleep lets the
compositor restore focus before the chain runs.

### Quick-action IPC

Runs **one detail action without opening the launcher**, so the user can bind
copy / type / autotype to any external shortcut:

```
noctalia msg plugin mellotanica/launcher-pass:quick-actions all <event> [entryPath]
```

**It is addressed to the `[[service]]` entry, not the launcher provider.**
`[[launcher_provider]]` entries are *not* IPC-addressable in v5 (`noctalia msg
plugin …:pass …` errors with "no plugin entry matched"), so the manifest adds a
headless `[[service]]` entry `quick-actions` that also points at `launcher.luau`.
`onIpc` therefore only ever fires in the service VM. That VM still runs the
whole file at load (defines `onQuery`/`onActivate` — unused — and does one
redundant `buildIndex`; harmless).

**Target resolution.** A launcher provider has no row-highlight callback (only
`onQuery` / `onActivate`), so "the highlighted entry" can't be read. The target
is the launcher VM's **current entry**, set wherever the user demonstrably
picked one:

- `fetchDetail` — opened the detail view;
- `runAction` — activated a Copy/Type row;
- `onQuery`'s grep callback — the query narrowed to **exactly one** `entry:`
  row (0 or 2+ leaves the previous value; folders never count).

Each of those calls `setCurrentEntry`, which publishes the path via
`noctalia.state.set(STATE_CURRENT_ENTRY, …)` (deduped by `lastPublishedEntry`)
— the only channel the service VM can read it on. State persists across the
launcher closing, so a shortcut fired seconds later still hits the entry that
was on screen. `onIpc` reads `noctalia.state.get(STATE_CURRENT_ENTRY)` when no
payload is given. An explicit `[entryPath]` payload overrides it (and is
re-published as the current entry) — but `noctalia msg` splits its args on
whitespace, so that payload **must be space-free**; an entry whose name has
spaces is only reachable through the no-payload / state path. `event` not in
`QUICK_ACTIONS` → `notification.quick-action-unknown`; no payload and nothing in
state yet → `notification.no-current-entry`; both under the
`notification.quick-action-failed` title, nothing runs.

`QUICK_ACTIONS` maps each event to the **same helper the matching detail row
uses**:

| event | path |
|---|---|
| `copy-password` | `copyViaPass({"pass","-c",p})` |
| `copy-otp` | `copyViaPass({"pass","otp","-c",p})` |
| `type-otp` | `typeOtp(p)` |
| `copy-username` | `quickResolve` → `copyPlain(data.username)` |
| `type-username` | `quickResolve` → `typeValue(data.username)` |
| `type-password` | `quickResolve` → `typeValue(data.password)` |
| `autotype` | `autotypeEntry(p)` |

`copy-password` / `copy-otp` / `type-otp` decrypt through `pass` themselves and
need nothing more. The username/password ones need the parsed body first:
`quickResolve(entryPath, subject, failKey, fn)` closes the launcher (so a
pinentry dialog can focus) then calls `withEntryData` — a warm `detailCache`
hit, else a `pass show` — and hands `data` to `fn`, or fires `tr(failKey)` on a
failed decrypt. `autotype` defers wholly to `autotypeEntry`, which already
closes + resolves the same way. There is no notification on *success* beyond
what the reused helper already posts (`copyViaPass` / `copyPlain` →
`notification.copied`; the type paths are silent) — same as activating the row.

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
re-decrypts the edited file. The `runAsync` call passes **`EDIT_TIMEOUT_MS`**
(24 h) — `noctalia.runAsync` applies a short default bound when the 3rd arg is
omitted, which would kill the terminal a few seconds into the edit. When
`terminalArgv()` is nil the row was never rendered; a defensive `editEntry`
call still fires `notification.edit-failed`.

### Generate action

Two-step, and the first step is **navigation, not a `setResults` call from
`onActivate`** — the host does not render a `setResults` made during activation
dispatch (an early version tried it; the confirm view never appeared). Instead
`onActivate` on `gen:<path>` does `launcher.setQuery(":!"..path.." ")`, exactly
the way `entry:<path>` opens the detail view. `onQuery` matches `":!"` **before**
the `":"` detail marker (a leading `!` after the colon; `"^%s*:(.+)$"` would
otherwise swallow it) and calls `renderGenerateConfirmRows(path)` →
`launcher.setResults(text, …)`: a **Cancel** row (a `query` row back to
`":"..path.." "`, the normal detail view) and a **"Regenerate now"**
`genrun:<path>` row. No decrypt in this view — the rows are static.

`genrun:` → `generateEntry(path)`: closes the panel up front (like Copy/Type —
`pass generate -i` decrypts the existing file so pinentry may pop and needs
focus), runs `pass generate -i <path>` (first line only, so username / OTP /
fields survive), then **on success only** clears `detailCache[path]`, fires
`notification.generated`, and `reopenLauncherPanel(":"..path.." ")` so the host
re-delivers `onQuery` → `fetchDetail` re-decrypts (gpg-agent warm from the
generate) and shows the new password ready to Copy/Type. On failure:
`noctalia.log` with the exit code + stderr, `notification.generate-failed`,
panel stays closed (same reopen-loop rationale as `fetchDetail`). `pass generate
-i` skips its own overwrite `yesno` prompt, so no tty is needed.

### Creation menu

Its own `+` prefix (never produced by browsing), `+!` for the confirm step
(matched before `+`, the same leading-`!` trick as `:!`). Entered from the
**"New entry"** row in every browse view (`renderBrowseRows`, a `query` row to
`"+"..folder.."/"`) or by typing `+`.

- `onQuery` `+<rest>` → `showCreateMenu(text, rest)` (async, like `fetchDetail`):
  `trim(rest)` is the new path (relative to the store root, editable by typing).
  Renders "Go back" to `parentOf(path)`, then: empty / folder-only path → a
  `create-hint` info row; otherwise the **"Create entry"** row (`id =
  "create-go"`, a `query` row to `"+!"..path.." "`) *optimistically*, then a
  `test -e <storeDir>/<path>.gpg` (per keystroke, cheap). If the path is taken
  the row is replaced in place with `create-exists` (`test` erroring →
  `create-error`) so the confirm / notification phase is never reached for a
  name that can't be created. Stale callbacks drop on `lastQuery`.
  `create-hint` / `create-exists` / `create-error` are inert: activating one
  does nothing but re-assert `lastQuery` via `setQuery`, so the host keeps the
  creation menu open instead of closing the launcher.
- `onQuery` `+!<path>` → `renderCreateConfirmRows(path)`: **Cancel** (`query`
  back to `"+"..path.." "`, the editable menu) and **"Create entry now"**
  (`newrun:<path>`). Static rows.
- `onActivate` `newrun:<path>` → `newEntry(path)`: re-`trim`s and rejects an
  empty / trailing-`/` path (`notification.create-failed`). Then repeats the
  `test -e <storeDir>/<path>.gpg` guard as a TOCTOU safety net (and for a
  hand-typed `+!<path>` that skipped the menu) — **`pass generate` silently
  overwrites an existing entry** when run without a tty (its `yesno` overwrite
  prompt does `[[ -t 0 ]] || return 0`, i.e. answers *yes*), so only exit 1
  "does not exist" proceeds; exit 0 → `notification.create-exists`, anything
  else → `notification.create-failed`. On "proceed": close the panel, run
  `pass generate <path>` (no `-i` — brand-new entry, encrypt only, no pinentry;
  `pass` still rejects `..`; `DECRYPT_TIMEOUT_MS` safety net). On success
  `buildIndex(nil)` (new entry enters the store index); then if `terminalArgv()`
  resolves, spawn `pass edit <path>` in that terminal (EDITOR from
  `editorCommand`, as in `editEntry`) with **`EDIT_TIMEOUT_MS`** — omitting the
  bound lets a short runAsync default kill the terminal mid-edit. The launcher
  **stays closed** either way; the only completion signal is
  `notification.created`, fired when `pass edit` returns (or right after
  `pass generate` when there is no terminal). No reopen into the detail view —
  that produced a close/reopen flicker when the editor exited.

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
   a bare `pass ` lists the store root. Within the post-`pass ` text, a leading
   `:` / `:!` / `+` / `+!` are internal navigation markers (detail view, Generate
   confirm, creation menu, creation confirm) — not user-facing syntax, but a real
   entry whose name starts with one of those characters is unreachable by typing.
2. **Match semantics** (`matchesFragments`) — lowercase, split the query on
   whitespace, **every fragment must be a contiguous substring** of the target
   (spaces act as wildcards between fragments), order-independent, non-match
   excluded. `string.find(hay, frag, 1, true)` (plain, not a pattern). Used for
   search *and* the detail row filter.
3. **Detail rows** — Copy Password, Copy OTP (**only if** the body has
   `otpauth://`), Copy Username, then Copy for each remaining `key: value` field
   in file order; a Type counterpart for each when `wtype` is present; an
   "Autotype" row between the Username row(s) and the first field row when
   `autotypeEnabled` is on and `wtype` is present; an "Edit" row after all of
   those when a terminal resolves (`terminalArgv()`); a "Generate" row after
   Edit (always); a "Go back" row. Order/grouping of Copy vs Type per
   `detailActionOrder` / `detailActionGrouping`; value order is fixed. Autotype
   types username → separator key (`autotypeSeparator`: Tab/Enter) → password →
   Enter → OTP + Enter (OTP steps only when present); `autotypeSubmit` (default
   on) toggles the final Enter. Generate is a two-step confirm (Cancel /
   "Regenerate now").
   3a. **Browse rows** — every folder view (root included) carries a "New entry"
   row after "Go back". It opens the creation menu (`+` prefix): an editable new
   path, a "Create entry" row once the path has a leaf, then a two-step confirm
   (Cancel / "Create entry now"). A path that already has an entry is refused
   *in the menu* (the "Create entry" row becomes an "already exists" message,
   from a `test -e` check) — and again in `newEntry` as a TOCTOU guard, since
   `pass generate` would silently overwrite. A free path runs `pass generate
   <path>` then `pass edit <path>` (when a terminal resolves).
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
12. **Quick-action IPC** — `onIpc(event, payload)` on the `[[service]]` entry
    (`…:quick-actions`, *not* the launcher provider — those aren't
    IPC-addressable) runs exactly one detail action with the launcher closed.
    Events: `copy-password`, `copy-otp`, `type-otp`, `copy-username`,
    `type-username`, `type-password`, `autotype` — each routed to the *same*
    helper as the matching detail row (via `withEntryData` for the ones needing
    the decrypted body). Target: the `[entryPath]` payload (space-free — CLI
    splits on whitespace), else the launcher VM's current entry bridged through
    `noctalia.state` (`STATE_CURRENT_ENTRY`; last entry opened / acted on /
    narrowed to a single search hit). Unknown event →
    `notification.quick-action-unknown`; no target →
    `notification.no-current-entry`. Events are matched in `QUICK_ACTIONS`, not
    declared in `plugin.toml`.
13. **Search result order** — password files rank above folders unless the
    query typed a folder's *entire* folder-relative path (`pathFullyTyped`), in
    which case that folder leads. `m.group` (0 exact folder / 1 file / 2 other
    folder) is the primary sort key, ahead of prerank and `fuzzySum`. Browse
    (empty query) is unaffected — it stays basename-sorted.

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
- **Twelve settings.** `storePath` (folder), `clipTimeout` (string — kept a
  string so `""` means "fall back to env"), `typeDelay` / `wtypeDelay` /
  `pinentryGraceMs` (int, `advanced`), `detailActionOrder` /
  `detailActionGrouping` (select, `advanced`), `terminalCommand` (string,
  `advanced` — `""` means auto-detect the terminal for the Edit action),
  `editorCommand` (string, `advanced` — `""` means don't export `EDITOR`, let
  `pass edit` use its own default), `autotypeEnabled` (bool, default `false` —
  gates the Autotype row), `autotypeSeparator` (select `tab`/`enter`, default
  `tab` — the username→password key), `autotypeSubmit` (bool, `advanced`,
  default `true` — the final submit Enter). Read back with
  `noctalia.getConfig(key)` (a `bool` setting comes back as a Lua boolean —
  compare `== true`); defaults come from the manifest.
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
- **A folder only outranks the password files on a fully-typed path.** During
  search the user is almost always after an entry, not a folder — a folder that
  merely substring-matches (`aws` → `work/aws/`) pushing `*.gpg` hits down the
  list is noise. So `m.group` sorts files above folders unless `pathFullyTyped`
  (the query's fragments reconstruct a folder's whole relative path segment for
  segment) — then that one folder leads, since the user clearly meant to drill
  in. It's an ordered exact check, not "all segments hit somewhere", so `a b`
  won't count as fully typing `b/a`.
- **`typeValue` passes the secret as a positional arg after `wtype … --`**, not
  over a `printf %s '<val>' | wtype -` pipe. Argv-only means no shell, no
  single-quote escaping, and a value with a leading `-` is still literal text.
- **Autotype is a chain of one-shot `wtype` processes, not a single call.**
  `wtype`'s grammar is `[OPTION_OR_TEXT]… -- [TEXT]…` with one terminal `--`, so
  once you switch to literal-text mode for an arbitrary value you can't emit a
  `-k` key after it. Each username/password/OTP segment therefore gets its own
  `wtype … -- <value>` and each separator/Enter its own `wtype -k <keysym>`,
  run in sequence (`runWtypeSteps`); the alternative — bare text args before
  `--` — would misparse a value starting with `-` as an option.
- **Copy/Type close the launcher up front and never reopen.** QML did the same
  (`launcher.close()` before `pass -c`); with the panel gone a pinentry prompt
  gets focus on its own, so these paths skip the close/reopen dance that
  `fetchDetail` needs.
- **The pinentry close only happens if `pass show` is still running after
  `pinentryGraceMs`** — a race, not an unconditional close — so a cached
  passphrase produces no flicker.
- **Quick-action IPC needs a `[[service]]` entry — a launcher provider can't
  receive IPC.** `noctalia msg plugin …:<launcher-id> …` errors with "no plugin
  entry matched"; only `[[service]]` / `[[widget]]` / `[[panel]]` / … entries
  are addressable. So the manifest adds a headless `[[service]]` `quick-actions`
  pointed at the *same* `launcher.luau` (the v5 pattern — cf. obsidian /
  claude-companion, which register one file as both a provider and a service).
  `onIpc` runs only in that service VM.
- **Quick-action IPC dispatches to the existing action helpers, it does not
  re-implement them.** `QUICK_ACTIONS` is a table of thin closures over
  `copyViaPass` / `typeOtp` / `copyPlain` / `typeValue` / `autotypeEntry` — the
  same code paths the detail rows use, so copy/type/autotype behaviour (clip
  env, pinentry handling, notifications) can't drift between the launcher and a
  shortcut. The only IPC-specific piece is `withEntryData` (a decrypt path that
  isn't tied to rendering a detail view — factored out of `fetchDetail` via
  `buildEntryData` so the parse/cache logic stays single-sourced).
- **The IPC target is a tracked "current entry" bridged over `noctalia.state`,
  not an argument.** The user asked for shortcuts that act on the
  highlighted/last-used entry *without* passing a path. A launcher provider gets
  no highlight callback, so the provider VM updates a "current entry" on the
  observable proxies — opening the detail view, acting on a row, a query
  narrowing to a single `entry:` hit — and `setCurrentEntry` publishes it via
  `noctalia.state.set`; the service VM reads it back in `onIpc`
  (`noctalia.state.get`), since the two VMs share no Luau state. The single-hit
  rule is deliberately strict (not "top of the list"): auto-typing into a
  focused window is unforgiving, so a broad query with several matches must
  *not* silently retarget. A space-free `payload` path is still accepted as an
  explicit override (`noctalia msg` splits args on whitespace, so a spaced entry
  name can only come through the state path).
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
| `function onIpc(event, payload)` | fires in the `[[service]]` VM only: `noctalia msg plugin <id>:quick-actions all <event> [payload]`. `[[launcher_provider]]` entries are **not** IPC-addressable. `payload` is the CLI args after `<event>`, whitespace-joined → space-free in practice. |
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
| `state.set(key, value)` / `state.get(key)` | cross-entry key-value the host brokers between a plugin's VMs — the only way the `[[service]]` VM sees the launcher VM's `currentEntry`. (`state.watch` exists too; unused here — `onIpc` reads `get` at call time.) |
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
- **`local` everything.** Only globals are host-callable; keep exactly
  `onQuery` / `onActivate` / `onIpc` global.
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
