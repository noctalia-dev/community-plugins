# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A plugin for **Noctalia**, a Wayland desktop shell built on [Quickshell](https://quickshell.outfoxxed.me/). It adds a launcher provider that browses a [GNU Pass](https://www.passwordstore.org/) store and copies/types passwords, OTP codes, and arbitrary fields. All code is QML (Qt 6 / QtQuick). There is no build step and no test suite — Noctalia loads the QML directly at runtime.

## What this needs to become

A plugin for **Noctalia v5** written in [Luau](https://luau.org/) using the [Noctalia plugin dialect](https://docs.noctalia.dev/noctalia/plugins/development/), implementing the same feature set as the current QML version.

This is a **full rewrite**, not a translation. QML's declarative property bindings, `Process`/`Timer`/`IpcHandler` objects, and the `pluginApi`/`launcher` object contract have no equivalent — the v5 plugin is a set of `.luau` scripts driven by a fixed `noctalia.*` runtime API and a `plugin.toml` manifest. Keep [Behaviour to preserve](#behaviour-to-preserve) intact; everything else is expected to change shape.

Target `plugin_api` level: pick the lowest that supplies everything used (per the docs, the argv form of `runAsync` lands at level 24). Level **28** is the current ceiling (Noctalia `v5.0.0-beta.9`+). **Decided: `plugin_api = 26`** — see Port status.

---

## Port status — 2026-08-27

**Browse mode and detail-mode listing are complete; the row actions (copy/type/OTP/clipboard-timeout/wtype) are still stub notifications.** The v4 `.qml` files and `i18n/` are still present side-by-side and must be deleted before submission.

### Files added

| File | State |
|---|---|
| `plugin.toml` | Complete manifest + settings schema. |
| `launcher.luau` | Browse mode done. Detail mode (`pass show`, parsing, row list, "Go back", pinentry dance) done. **Copy Password + Copy OTP + Copy Username wired** (`pass -c` / `pass otp -c` via copyViaPass; username via `noctalia.copyToClipboard`); Copy field / all Type actions still stub notifications. |
| `translations/en.json` | Keys used so far only. Other locales not ported. |

### Decisions that diverge from the guidance further down this doc

- **`plugin_api = 26`**, not 28 — the highest-level feature used is `noctalia.getSetting` (see the pinentry-dance bullet below). Bump when a later step needs more.
- **Settings are top-level `[[setting]]` blocks, not `[[launcher_provider.setting]]`.** The manifest docs only document nested settings for `widget`/`panel`; every sibling launcher plugin (`pass`, `file-search`, `k8s-status`) uses top-level `[[setting]]`, and for a launcher-only plugin the two are equivalent. Five settings are present (`storePath` folder, `clipTimeout` string, `typeDelay`/`wtypeDelay`/`pinentryGraceMs` int + `advanced`).
- **`translations/en.json` is nested JSON**, not the flat dotted-key map originally specified. `noctalia.tr("settings.storePath.label")` resolves the dotted key against nesting — this is how the working sibling plugins' translations are shaped.
- **Navigation state is encoded in the query string, not module `local`s.** A trailing `/` marks a folder context (`onQuery("work/aws/")` → browse inside `work/aws`; `onQuery("work/aws/pr")` → recursive search there). This is the `proton-pass` pattern and makes reopening `>pass` reset to the store root for free (the old `onOpened()` behaviour). Module state is caches only.
- **Fuzzy *ranking* was rewritten** (match semantics unchanged — see "Behaviour to preserve #4"). The QML base-27 segment score let leaf *length* dominate, floating `root_new_1` above a shallower `root`. `rankEntry` sorts by: (1) count of query fragments that equal a whole path segment, (2) fewer path segments, (3) alphabetical. Query-aware, unlike the QML formula.
- **Detail mode is also query-string-encoded**, same trick as the trailing-`/` folder marker: a leading `:` on the post-prefix text means "detail view of entry `<rest>`" (`onQuery(":work/aws/root")`). Browsing never produces text starting with `:`, so a fresh `>pass ` always falls through to browse — no `onOpened()`-style reset hook needed. `onActivate` on an `entry:<path>` row does `launcher.setQuery(":" .. path)`.
- **Row actions use a module-local lookup table, not id-encoded data.** Each Copy/Type row gets an opaque `act:<n>` id (n derived from the row count so far — no separate counter); `detailActions[id]` holds `{entryPath, verb, kind, key, value, label}` for `onActivate` to read. Avoids encoding field keys/values (which can contain almost anything) into the id string. Only one detail view is ever live, so the table is simply rebuilt (`detailActions = {}`) on every render rather than namespaced per entry.
- **The pinentry dance is reimplemented via `noctalia msg panel-close/panel-open launcher [context]`**, not a plugin API call — there isn't one. The installed `noctalia`/`noctalia msg --help` text documents this CLI IPC: `panel-close [id]` ("close the active panel, or close the named panel if it is active" — safe to call even when already closed) and `panel-open <id> [context]` ("open a panel by id, optionally with context", e.g. `launcher /emo`). `fetchDetail` populates `detailCache`/`setResults` from the `pass show` result, *then* (if the panel was closed — see grace-period bullet below) reopens with context `<leader> .. "pass " .. text` — the host re-delivers that as a fresh `onQuery`, which finds the now-warm cache and re-renders without the script tracking "what was on screen" itself. This resolves the "IPC toggle" open question too: `noctalia msg panel-toggle/-open/-close <id>` is the v5 analogue of v4's `pluginApi.toggleLauncher()`, for any panel by id (not launcher-specific).
- **The panel is only closed if `pass show` is still running once a short grace period elapses** (`pinentryGraceMs` setting, default 200ms) — not unconditionally up front. `fetchDetail` starts `pass show` and a `{"sleep", "<pinentryGraceMs/1000>"}` call at the same time; whichever finishes first decides: if `pass show` resolves first (`resolved = true`), gpg-agent already had the passphrase cached, no pinentry dialog ever appeared, and the panel is never touched — no flicker. If the sleep fires first, pinentry is presumably up and blocking, so *that* callback does the belated `closeLauncherPanel` (`panelClosed = true`); when `pass show` eventually resolves, it checks `panelClosed` and only then calls `reopenLauncherPanel`. Both `resolved`/`panelClosed` are plain upvalues closed over by both callbacks — safe because Luau callbacks run to completion before the next one starts, so there's no true concurrency to race over, just two independent subprocesses whose completion order isn't known in advance.
- **`<leader>` is read at runtime, not hardcoded `">"`.** The character that starts a launcher command is itself a user setting — `shell.launcher.provider_prefix` (confirmed via `noctalia config export full`; e.g. `"/"` on the dev machine, not the `">"` used throughout this doc's own examples). `launcherLeader()` reads it with `noctalia.getSetting("shell.launcher.provider_prefix")`, falling back to `">"` only if that returns `nil` (an older host without plugin_api 26). This is the one thing in the pinentry-dance reopen that must never be hardcoded — get it wrong and the reopened panel's context isn't recognised as a command at all. `noctalia.getSetting` is what pushed `plugin_api` from 24 to 26.
- **No timeout is passed on ordinary calls**, but the `pass show` call specifically gets `runAsync(argv, cb, DECRYPT_TIMEOUT_MS)` with `DECRYPT_TIMEOUT_MS = 300000` (5 min) — a safety net, not a UX timer: pinentry can legitimately block a long time on a slow passphrase or a hardware-key touch, and the point of a bound at all is only to guarantee a wedged `gpg-agent` eventually reopens the panel instead of leaving it closed forever. (`runAsync`'s 3rd `timeoutMs` argument isn't on the public runtime-api docs page but is an established pattern across sibling plugins — see `ocr`, `obsidian`, `tailscale`, `hotspot`, etc.)

### How `launcher.luau` works now

- **Prefix routing** — `onQuery(text)`, `text` is everything after `>pass ` (leading/trailing space tolerated). Bare `>pass ` lists the store root.
- **Drill-in** — folder rows carry a `query` field (`"<path>/"`) for the host's native re-query; they *also* carry an `id` (`nav:<path>` / `back:<parent>`) so `onActivate` can fall back to `launcher.setQuery(<non-empty>)`. A bare empty string passed to `setQuery` does **not** re-fire `onQuery` in the tested build — root "Go back" uses `" "`, which trims to empty.
- **Listing** — browse (`search == ""`): `find -maxdepth 1` as a plain argv. Recursive search: shell string `find … -printf '%P\n' | grep -iF -e <frag> | … | head -n <GREP_CAP=500>`. The `grep -iF` chain does the fixed-string / case-insensitive / all-fragments-substring / order-independent match in C, so Luau only ever parses the capped hit set — this is what keeps the callback under the per-call CPU budget. `.gpg` stripped in Luau; parent folders synthesised from recursive hits and re-checked against the fragments.
- **Caching + prefetch** — browse listings cached 30 s, search results 8 s (per exact query), decrypted detail entries 60 s (per entry path, so a debounce re-fire while the detail view is open doesn't trigger a second `pass show` / pinentry). At module load, and whenever a browse view renders, the immediate child-folder listings are fetched in the background (cap 10, deduped via `pendingFetch` + TTL). Activating a folder then hits a warm cache and renders with no subprocess on the critical path; the residual delay is just `debounce_ms` (200).
- **Detail mode** — activating an `entry:<path>` row sets the query to `:<path>`; `onQuery` routes that (leading `:`) to `fetchDetail`, which shows a "Decrypting…" row, then races `runAsync({"env", "PASSWORD_STORE_DIR="..dir, "pass", "show", entryPath}, cb, DECRYPT_TIMEOUT_MS)` against a `pinentryGraceMs`-long `sleep` (pinentry dance — only actually closes/reopens the panel if the sleep wins the race; see Decisions above), and on success parses + caches + renders. `parsePassEntry` splits first-line password / `key: value` fields / `otpauth://` detection; `extractUsername` pulls the first `login`/`user`/`username` field (case-insensitive) out of the field list and falls back to the entry's basename. Rows render as Password, OTP (if present), Username, then remaining fields in file order, each as a Copy + Type pair, plus "Go back" to the entry's parent folder. A failed/timed-out `pass show` renders a "Go back" + error row instead (the panel is still reopened if it had been closed). **Every row's `onActivate` is currently a stub `noctalia.notify`** — see Next steps #1.

### Next steps, in order

1. **Copy / Type actions** — wire up the `act:<n>` rows' real behaviour in place of the stub notify: copy password/OTP via `env PASSWORD_STORE_DIR=… [PASSWORD_STORE_CLIP_TIME=…] pass -c` / `pass otp -c` (clip timeout per "Behaviour to preserve #6"); copy plain field/username via `noctalia.copyToClipboard`; type = `sleep <typeDelay/1000>` then feed the value to `wtype -d <wtypeDelay>` (decide stdin approach — open question). "Copied to clipboard" notice on success. Probe `wtype` / `pass-otp` with `commandExists` and hide rows / warn when missing. `pass -c` / `pass otp -c` can also hit pinentry (an expired gpg-agent cache) — reuse `closeLauncherPanel`/`reopenLauncherPanel` around those calls the same way `fetchDetail` does.

   **Progress — Copy Password + Copy OTP + Copy Username done.** `onActivate`'s `act:` branch calls `runAction(ctx)`, which dispatches: `copy`/`password` → `copyViaPass({"pass","-c",entryPath}, <basename>)`; `copy`/`otp` → `copyViaPass({"pass","otp","-c",entryPath}, <basename>)`; `copy`/`username` → `copyPlain(ctx.value, <basename>)`. `ctx.value` for the username row is `data.username` — the value `extractUsername` already resolved (first `login`/`user`/`username` field, case-insensitive; entry basename otherwise), so the "best option" logic lives in one place and the copy path just consumes it. New helpers: `positiveInt` / `clipTimeout` (setting → `PASSWORD_STORE_CLIP_TIME` env → nil), `passArgv(cmd, withClip)` (builds the `env KEY=VAL … pass …` argv; `fetchDetail`'s `pass show` call was refactored onto it), `copyViaPass` (close launcher first — like QML's `launcher.close()` before `pass -c`, so pinentry gets focus with no close/reopen dance — then run with `DECRYPT_TIMEOUT_MS`, post `notification.copied` / `notification.copyFailed`), `copyPlain` (no subprocess / no pinentry / no clipboard auto-clear: `noctalia.copyToClipboard` + notice + close launcher). `notification.copied` / `notification.copyFailed` are new `en.json` keys. Launcher stays closed after every copy, matching QML's terminal state. **Still stubs:** Copy field, every Type action. (Not yet done: `commandExists` probe for the `pass-otp` extension to hide the OTP rows when it's missing — a failed `pass otp -c` currently just shows `notification.copyFailed`.)
2. **Optimizations** - consider using native `noctalia.fuzzyScore()` method to sort output with guidance to respect default priorities and reduce cpu usage for large password stores.
3. **Translations** — add the new `action.*`/`detail.*` keys now in `en.json`; port `de fr it es ja nl pt ru tr zh-CN` from `i18n/` to `translations/`, same key set as `en.json`.
4. **README** — rewrite for v5 (settings, prefix, dependencies); document the resolved IPC section (`noctalia msg panel-*`, see Decisions above).
5. **`thumbnail.webp`** — convert/regenerate from `preview.png`.
6. **Cleanup** — delete `Main.qml`, `LauncherProvider.qml`, `Settings.qml`, `manifest.json`, `settings.json`, `preview.png`, `i18n/`.

### Open questions — updated

- **Navigation model** — *resolved*: query-string-encoded, stateless. Result-row `query` field confirmed working (post-prefix text, no `>`), same as `setQuery`. Empty-string `setQuery` does not re-fire `onQuery`.
- **Detail-mode encoding** — *resolved*: leading `:` on the query text, consistent with the trailing-`/` folder marker (see Decisions above). Row actions dispatch via a module-local `detailActions` table keyed by row id, not id-encoded data.
- **pinentry dance** — *resolved*: `noctalia msg panel-close/panel-open launcher [context]` CLI IPC, confirmed against the installed `noctalia`/`noctalia msg --help` text (no plugin API call exists for this — see Decisions above). Verified so far only against a mocked `pass show` in an isolated Luau sandbox (close → run → reopen-with-context, in that order, including on failure and skipped entirely on a cache hit) — **not yet exercised against a real pinentry prompt on the live desktop**; worth a manual check (see the test sequence proposed after this port step).
- **IPC `toggle`** — *resolved*: `noctalia msg panel-toggle/-open/-close <id> [context]`, the v5 analogue of v4's `pluginApi.toggleLauncher()`, generalized to any panel by id. README section can now document this directly instead of treating it as unresolved.
- **`wtype` stdin** — still open; `shellEscape` not yet ported.
- **`thumbnail.webp`** — still open.

---

## Target file structure (v5)

```
launcher-pass/
├── plugin.toml            # manifest: identity + [[launcher_provider]] entry + settings schema
├── launcher.luau          # the launcher provider entry script (the whole feature)
├── translations/
│   ├── en.json            # flat dotted-key bundle; reference for all keys
│   ├── de.json  fr.json  it.json  ...   # one per locale, same keys as en.json
├── README.md
└── thumbnail.webp         # replaces preview.png (community-plugins submission requirement)
```

Files that go away: `Main.qml`, `LauncherProvider.qml`, `Settings.qml`, `manifest.json`, `settings.json`, `preview.png`, `i18n/` (becomes `translations/`).

Do not keep `.qml` files in the final tree. During the port it is fine to have both side by side; the deliverable has only the v5 layout.

### `plugin.toml` shape

> **Superseded by the shipped `plugin.toml`** (see Port status): `plugin_api = 24`, and settings are top-level `[[setting]]` blocks, not `[[launcher_provider.setting]]`. The block below is the original sketch.

```toml
id = "mellotanica/launcher-pass"      # "<author>/<plugin>", globally unique
name = "Launcher pass"
version = "2.0.0"                    # MAJOR.MINOR.PATCH only, no prerelease suffix
plugin_api = 28
author = "Marco Melletti"
license = "MIT"
icon = "lock"
description = "Noctalia launcher provider for the GNU Pass password store with autotype and advanced search"
tags = ["Launcher"]

[[launcher_provider]]
id = "pass"
entry = "launcher.luau"
prefix = "pass"                      # user types ">pass " (Noctalia adds the ">")
glyph = "lock"
include_in_global_search = false
debounce_ms = 200                    # replaces the old 200 ms searchTimer

  # per-entry settings; each label/description MUST point at a translation key
  [[launcher_provider.setting]]
  key = "storePath"
  type = "folder"
  label_key = "settings.storePath.label"
  description_key = "settings.storePath.desc"
  default = ""

  [[launcher_provider.setting]]
  key = "clipTimeout"
  type = "string"                    # kept as string so "" means "fall back to env"
  label_key = "settings.clipTimeout.label"
  description_key = "settings.clipTimeout.desc"
  default = ""

  [[launcher_provider.setting]]
  key = "typeDelay"
  type = "int"
  label_key = "settings.typeDelay.label"
  description_key = "settings.typeDelay.desc"
  default = 500                      # milliseconds (see gotcha below)
  min = 0
  advanced = true

  [[launcher_provider.setting]]
  key = "wtypeDelay"
  type = "int"
  label_key = "settings.wtypeDelay.label"
  description_key = "settings.wtypeDelay.desc"
  default = 12
  min = 0
  advanced = true
```

The manifest-driven settings schema replaces `Settings.qml` entirely — Noctalia auto-generates the settings UI from these tables. Read values back with `noctalia.getConfig("storePath")` etc. Setting types available: `string`, `string_list`, `string_map`, `bool`, `int`, `double`, `select`, `file`, `folder`, `glyph`, `color`. Use `advanced = true` for what was the old "Advanced" tab; `visible_when` for conditional rows.

### Translations

> **Shipped as nested JSON instead** (see Port status) — `noctalia.tr` resolves the dotted key against nesting, matching the working sibling plugins. The rule below ("every key in every locale, `en.json` canonical") still holds.

`translations/<locale>.json` is a **flat** map of dotted keys to strings (no nesting like the old `i18n/*.json`):

```json
{
  "command.description": "Search gnu pass password entries",
  "result.goBack": "Go back",
  "action.copyField": "Copy {key}"
}
```

Look up with `noctalia.tr("action.copyField", { key = "username" })`. `{name}`-style placeholders are substituted from the second arg. `noctalia.trp(key, count)` for plurals. Every user-facing string goes through `tr`, and every key must exist in **every** locale file (`en.json` is the canonical set).

---

## Launcher provider contract (v5)

The entry script defines global functions the host calls, and pushes results back through `launcher.*`. There is no per-result `onActivate` closure and no `getResults` return value.

| Hook / call | Purpose |
|---|---|
| `function onQuery(text)` | Host calls this on each keystroke after the prefix (subject to `debounce_ms`). `text` is everything after `>pass `. |
| `function onActivate(id)` | Host calls this when the user picks a row. `id` is the string you put on that result. |
| `launcher.setResults(query, results)` | Publish rows. `query` **must echo** the `text` from the `onQuery` call they answer, so stale async results are dropped. Empty list clears. |
| `launcher.setQuery(text)` | Programmatically rewrite the launcher input; keeps the launcher open and re-fires `onQuery`. This is how drill-in / back navigation works now. |

Result table fields: `id`, `title`, `subtitle?`, `glyph?` (Tabler/Nerd-Font name), `icon?` (themed), `badge?`, `query?` (set launcher input on activate instead of calling `onActivate`), `score?` (sort key, descending; ties break on insertion order).

### Consequences for the design

- **State lives as `local` upvalues in the module.** The VM persists for the plugin's lifetime, so `currentPath`, `entryStack`, `mode` (`browse` / `detail`), `selectedEntry`, `cachedEntries`, and `lastQuery` are just file-scope locals mutated across `onQuery` / `onActivate` calls. But the launcher input is the source of truth — after any navigation, call `launcher.setQuery(...)` so the two stay in sync. **As shipped**, browse-mode navigation carries *no* module state at all — the folder path is encoded in the query string (trailing `/`) and module `local`s are caches only. Detail mode (step 1) will need either its own query encoding or a minimal `mode`/`selectedEntry` pair; keep whichever is chosen consistent with the stateless browse model.
- **Drill-in replaces per-row callbacks.** Either give folder/entry rows a `query` field (`">pass "..path.."/"`) so activating them re-runs `onQuery`, or dispatch on `id` in `onActivate` and then `setQuery`/`setResults` yourself. Pick one and be consistent.
- **Async is first-class.** `onQuery` runs off the UI thread with a per-call time budget. Return fast: publish a "Loading…" row synchronously via `setResults`, kick off `noctalia.runAsync(...)`, and call `setResults(sameQuery, realRows)` from the callback. Do not block waiting on `pass`/`find`.
- **No `include_in_global_search`** — this provider only answers its own prefix, matching current behaviour.

---

## Runtime API mapping (QML → Luau)

| Current (QML) | v5 replacement |
|---|---|
| `Process { command; environment }` + `StdioCollector` | `noctalia.runAsync(argvOrString, cb)`; `cb` gets `{exitCode, stdout, stderr, timedOut, stdoutTruncated, stderrTruncated}` |
| `Process` streaming | `noctalia.runStream(cmd, onLine)` |
| `Timer { interval: 200 }` debounce | `debounce_ms` in `plugin.toml` (no user-space timer API) |
| `Timer { interval: 300 }` pinentry probe | No scheduler is exposed — approximate with `noctalia.runAsync({"sleep", "0.3"}, cb)` or drop it (see open questions) |
| `Quickshell.env("HOME")` / `env(...)` | `noctalia.getenv("HOME")`; `noctalia.expandPath("~/.password-store")` |
| `ToastService.showNotice(...)` | `noctalia.notify(title, body)` / `noctalia.notifyError(title, body)` |
| `wl-copy` via `sh -c` | `noctalia.copyToClipboard(text, mime)` for plain fields |
| `pass -c` / `pass otp -c` (auto-clear via `PASSWORD_STORE_CLIP_TIME`) | keep `pass` doing the clearing; pass env through argv: `noctalia.runAsync({"env", "PASSWORD_STORE_DIR="..dir, "PASSWORD_STORE_CLIP_TIME="..t, "pass", "-c", entry}, cb)` |
| `pluginApi.pluginSettings.x` / `defaultSettings` | `noctalia.getConfig("x")` (defaults come from the manifest schema) |
| `pluginApi.tr(k, obj)` | `noctalia.tr(k, tbl)` / `noctalia.trp` |
| `pluginApi.saveSettings()` / `Settings.qml` | gone — settings are manifest-declared and host-managed |
| `Main.qml` `IpcHandler.toggle()` | no launcher-provider IPC toggle in v5; `noctalia msg` drives entry handlers, not "open the launcher". Revisit the README IPC section. |
| `JSON.parse` / `JSON.stringify` | `noctalia.json.decode` / `noctalia.json.encode` |
| `.trim()` | `noctalia.string.trim` |
| custom `fuzzyMatch` | reimplement in Luau to keep exact semantics (see below); `noctalia.fuzzyScore(pattern, text)` exists but has different behaviour |
| `console.log` | `noctalia.log(msg)` |

Other useful runtime calls: `noctalia.commandExists("wtype")` (probe optional deps — `wtype`, `pass-otp` — and hide rows / warn when missing), `noctalia.pluginDataDir()` (persistent storage, if ever needed), `noctalia.nowMs()`.

### Subprocess rules

- **Argv array = no shell.** `{"pass", "show", entry}` runs the binary directly with each element as one literal arg — no quoting, no `shellEscape`. Prefer this everywhere possible; it removes a whole class of injection bugs the current code guards against by hand.
- **String form = shell parsing.** Only needed where you must pipe, e.g. feeding a secret to `wtype` over stdin: `printf %s '<value>' | wtype -d <n> -`. Here you still need single-quote escaping (`'` → `'\''`) — port `shellEscape` for this path only. Consider whether `wtype` can read the value another way to avoid the shell entirely.
- **`runAsync` argv form has no documented `env` option** — prepend `env KEY=VAL ...` as argv elements (see the `pass -c` row above).

---

## Behaviour to preserve

Port these behaviours exactly; they define the plugin regardless of language.

1. **Prefix**: activates only on `>pass` / `>pass <query>`. A bare `>pass` with no query lists the store root.
2. **Two modes**:
   - *Browse* — folders + password entries under `currentPath`, filtered by the text after `>pass `. Entering a folder pushes onto a nav stack; a "Go back" row pops it.
   - *Detail* — entered after `pass show <entry>` succeeds. Rows: Copy Password, Type Password, then Copy/Type OTP **only if** the decrypted body contains `otpauth://`, then Copy/Type for every `key: value` field parsed from the body. Plus a "Go back" row.
3. **Listing**: empty query → immediate children only (`find -maxdepth 1`, files `*.gpg` + dirs). Non-empty query → recursive `*.gpg` under `currentPath`. Strip `.gpg` from display names; in recursive results synthesize parent-folder rows.
4. **Fuzzy match semantics** (`fuzzyMatch` in the QML): lowercase; split query on whitespace; **every part must appear as a contiguous substring** of the target (spaces act as wildcards between fragments); non-match → excluded. Cap at 50 rows. Reimplement with plain (non-pattern) `string.find(hay, needle, 1, true)`. **The *matching* rule is preserved as-is.** The *ranking* was rewritten (see Port status → `rankEntry`): the QML "earlier path segments / alphabetically earlier names" base-27 score made leaf length dominate; the shipped key is query-aware (exact-segment hits, then depth, then alphabetical).
5. **Pass entry parse**: first non-empty line = password; subsequent lines split on the first `": "` into `key`/`value`; presence of `otpauth://` sets an OTP flag.
6. **Clipboard timeout**: `clipTimeout` setting wins if a positive integer; else `PASSWORD_STORE_CLIP_TIME` from the environment; else let `pass` use its own default. Applies to Copy Password and Copy OTP (both go through `pass -c` / `pass otp -c`).
7. **Typing**: `sleep(typeDelay/1000)` then type the value via `wtype -d <wtypeDelay>`. `typeDelay` is **milliseconds** (the UI label "Launcher Close Delay" is misleading); `wtypeDelay` is ms between keystrokes.
8. **Store path**: `storePath` setting, else `~/.password-store` (expanded). Exported as `PASSWORD_STORE_DIR` to every `pass` invocation.
9. **Copy vs type OTP**: `pass otp -c` for copy (with clip env), `pass otp` + `wtype` for type.
10. **Notifications**: show a "Copied to clipboard" notice after a successful copy.
11. **i18n**: no hard-coded user-facing strings.

---

## Behaviour to implement

Add these new behaviours not implemented in QML code:

1. **Copy/Type username**: add to the list of options shown when a password entry is selected the option to Copy/Type the username for that password, that is the value of the `login`,`user` or `username` field if available in the `key: value` list or the name of the password entry otherwise.
2. **Password fields sorting**: the list of options shown when a password entry is selected should be sorted with the following order:
    1. `password`
    2. `otp` (if available)
    3. `username`
    4. `key: value` fields in the order they appear in the password file contents (excluding already considered `username`/`login`)

---

## Luau conventions & gotchas

- **1-based indexing.** `t[1]` is the first element; `#t` is length; `ipairs`/`pairs` for iteration. Every loop ported from the QML `for (i = 0; i < n; i++)` shifts.
- **`string.find` / `string.match` use Lua patterns, not regex.** `.`, `-`, `%`, `(`, `)`, `[`, `]`, `+`, `*`, `?`, `^`, `$` are magic. For literal substring search pass `plain = true`: `string.find(s, "otpauth://", 1, true)`. `%` escapes a magic char in a pattern.
- **Concatenation is `..`**, not `+`. `+` on strings errors.
- **No `undefined`; only `nil`.** `t.missing` is `nil`. `x and a or b` is the ternary idiom (beware when `a` can be falsy). `a or default` for fallbacks.
- **`nil` holes break arrays and `#`.** Build lists by appending (`table.insert(t, v)` or `t[#t+1] = v`); don't leave gaps.
- **Split/trim are not built in.** Use `noctalia.string.trim`; write a splitter with `string.gmatch(s, "[^\n]+")` for line splitting, or `string.gmatch(s, "%S+")` for whitespace tokens.
- **`local` everything.** Un-`local` names are globals — and for entry scripts, only globals are callable by the host (`onQuery`, `onActivate`). Keep exactly the host hooks global; everything else `local`.
- **Callbacks may be function values** (closures capturing scope) — this needs `plugin_api >= 9`, which the target level covers. Named globals also work.
- **Isolated VM, per-call time budget.** Do no heavy work synchronously in `onQuery`/`onActivate`. All `pass`/`find`/`wtype` calls go through `runAsync` with a callback; publish incremental `setResults`.
- **No `Math.random`/wall-clock in a way that matters here**; use `noctalia.nowMs()` if a timestamp is needed.
- **Numbers are doubles**; `math.floor` / `tostring` / `tonumber` for int-ish conversions (e.g. parsing `clipTimeout`).

---

## Open questions to resolve during the port

> See Port status → "Open questions — updated" for current status. The navigation-model question is resolved; pinentry, IPC `toggle`, `wtype` stdin and `thumbnail.webp` are still open.

- **Is the pinentry dance still needed?** The old code closed and reopened the launcher because the QML overlay stole focus from the GPG pinentry dialog. With `runAsync` (non-blocking, off-thread) the v5 launcher may not need it at all. Try the plain path first — `runAsync({"env","PASSWORD_STORE_DIR="..dir,"pass","show",entry}, cb)`, show a "Decrypting…" row, populate detail mode in `cb` — and only add focus juggling if pinentry actually fails to appear. There is no 300 ms timer primitive to reproduce `pinentryTimer` exactly.
- **IPC `toggle`.** `Main.qml`'s `IpcHandler` has no v5 analogue for launcher providers. Confirm against the Workflow docs whether anything replaces it; update the README "IPC" section accordingly (likely: remove it, or document opening the launcher generically).
- **`wtype` stdin.** Decide whether to keep the `printf … | wtype -` shell pipe (needs the ported `shellEscape`) or find an argv-only way to hand `wtype` the secret.
- **`thumbnail.webp`.** community-plugins submission wants a `thumbnail.webp`; convert `preview.png` or regenerate.

---

## Legacy reference — current v4 / QML implementation

Kept for behaviour archaeology. None of this structure survives the port.

`manifest.json` declares three QML entry points, each instantiated with a `pluginApi` property:

| File | Role |
|------|------|
| `Main.qml` | Background component. Only an `IpcHandler` exposing `toggle()`. |
| `LauncherProvider.qml` | The entire feature. Implements Noctalia v4's launcher-provider object contract. |
| `Settings.qml` | Settings UI, built from Noctalia's `N*` widgets; persists via `pluginApi.saveSettings()`. |

`LauncherProvider.qml` is driven by Noctalia calling well-known functions / reading well-known properties (`name`, `supportedLayouts`, `handleSearch`, `supportsAutoPaste`; `init()`, `onOpened()`, `handleCommand(text)`, `commands()`, `getResults(text)`). `pluginApi` provided `pluginSettings`, `manifest`, `tr()`, `saveSettings()`, `withCurrentScreen(cb)`, `toggleLauncher(screen)`; `launcher` provided `setSearchText()`, `updateResults()`, `close()`. Each result row was `{ name, description, icon, isTablerIcon, singleLine, onActivate }`, with `onActivate` closures capturing loop vars via an IIFE.

Search: `performSearch()` shelled out to `find` (maxdepth 1 for empty query, recursive for non-empty), then `fuzzyMatch()` scored client-side with a 200 ms `searchTimer` debounce.

The pinentry dance: `pass show` triggers a GPG pinentry dialog that needs focus. `pinentryTimer` (300 ms) detected `showProc` running with no stdout yet → set `pinentryActive`, `launcher.close()`. On `showProc` exit, if `pinentryActive`, reopen via `pluginApi.toggleLauncher()` and set `restoringFromPinentry`; `onOpened()` checked that flag first and returned early so the restored session kept its state.

Settings: `manifest.json` → `metadata.defaultSettings` held defaults/keys (`storePath`, `typeDelay`, `wtypeDelay`, `clipTimeout`); `Settings.qml` read `pluginApi.pluginSettings` with those as fallback and wrote back in `saveSettings()`. `typeDelay` was milliseconds despite its "Launcher Close Delay" label. The repo's `settings.json` was a stale local snapshot, not authoritative. `PASSWORD_STORE_DIR` came from `storePath` or `~/.password-store`; `PASSWORD_STORE_CLIP_TIME` from `clipTimeout` or the ambient env var (`getPassEnvironment()` for copy actions).

Conventions: all shell-interpolated values passed through `shellEscape()` (single-quote escaping) before `sh -c`. `qs.Commons`, `qs.Widgets`, `qs.Services.UI` were Noctalia shell modules, not part of this repo. Every user-facing string went through `pluginApi.tr()` with a key in every `i18n/*.json`.

---

## Workflow

- Define the next steps in brief clear text
- Prompt the user for a quick test of what was modified proposing a test sequence
- Create a local commit detailing what has been modified and why, add the coauthored tag, **NEVER** perform any other git operations
