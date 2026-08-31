--!nonstrict
-- launcher-pass — Noctalia v5 launcher provider for the GNU Pass store.
-- Design notes and the QML-era behaviour archaeology live in CLAUDE.md.
--
-- Browse mode:
--   * "<leader>pass" / "<leader>pass <query>" routing (Noctalia strips the
--     leader + trigger and calls onQuery with the rest)
--   * store listed once by `find` into an index *file*; every query greps
--     that file in a subprocess (`browseGrepArgv` / `searchGrepCmd`), so
--     Luau only ever parses the capped hit set — the filtering never spends
--     the host's per-callback CPU budget
--   * match semantics (matchesFragments): whitespace-split query, every
--     fragment a contiguous case-insensitive substring, order-independent
--   * ranking: cheap pure-Luau `prerank` over every hit, then a bounded
--     `noctalia.fuzzyScore` pass (`fuzzySum`) over just the top SCORE_POOL
--   * folder drill-in / "Go back", navigation state carried entirely in the
--     launcher query string (a trailing "/" marks a folder context)
--
-- Detail mode:
--   Activating an entry rewrites the query to ":" + entry path + " " (a
--   leading ":" is never produced by browsing, so a fresh "<leader>pass "
--   always resets to browse for free). onQuery routes that to fetchDetail,
--   which runs `pass show`, parses it, and lists Copy/Type rows for password,
--   OTP (if the body has an otpauth:// line), username, then every remaining
--   key: value field, in that order. Text typed after ":" + path + " "
--   fuzzy-filters those rows (same matchesFragments rule).
--
-- The pinentry dance: the launcher panel is a layer-shell surface with an
-- exclusive keyboard grab, so a GPG pinentry dialog that `pass show` pops on
-- a locked store never receives focus while the panel is open. There is no
-- noctalia.* call to hand focus to an arbitrary window, so the panel is
-- closed and reopened afterwards via the `noctalia msg panel-close/panel-open`
-- CLI IPC (see closeLauncherPanel/reopenLauncherPanel below). This only
-- happens when needed: `pass show` is raced against a short grace period
-- (pinentryGraceMs, default 50ms), and if gpg-agent already had the
-- passphrase cached the result comes back before the grace period elapses,
-- so the panel is never touched at all. The reopen is also conditional on the
-- decrypt succeeding — a cancelled or failed pinentry leaves the launcher
-- closed rather than looping a fresh prompt. Lower values let a real pinentry
-- dialog steal focus sooner but risk a visible flicker on a warm gpg-agent
-- cache; higher values (~200/300ms) keep the launcher steadier but give the
-- dialog more time to spawn while the panel still holds the keyboard grab,
-- and depending on the window manager it may then fail to get focus at all.

local STORE_DEFAULT = "~/.password-store"
local MAX_RESULTS = 50
-- The store tree is walked once by `find` into an index *file*; every keystroke
-- greps that file in a subprocess, so the filtering never touches the Luau CPU
-- budget and the tree is re-walked only on the background refresh past this
-- TTL (a stale file is grepped meanwhile).
local INDEX_TTL_MS = 60000
-- Hard cap on grep hits pulled back into Luau (search / browse respectively).
local SCAN_CAP = 500
local BROWSE_CAP = 2000
-- Only the strongest `SCORE_POOL` candidates (by the cheap pure-Luau prerank)
-- get a `noctalia.fuzzyScore` pass — each fuzzyScore call crosses into C with
-- a ~26 KB stack frame, so scoring every hit of a broad query ("w") blows the
-- 25 ms callback budget. Kept a bit above MAX_RESULTS so the visible page is
-- fully fzy-ordered.
local SCORE_POOL = 64
-- Decrypted entries stay cached a while so re-rendering the same detail view
-- (e.g. a debounce re-fire) doesn't trigger a second `pass show` / pinentry.
local DETAIL_TTL_MS = 60000
-- `pass show` pauses on pinentry for as long as the user takes to enter a
-- passphrase or touch a hardware key — that can legitimately be a while, and
-- cutting it short would kill pinentry mid-entry. This is a safety net, not a
-- UX timer: it only exists so a truly wedged gpg-agent can't pin the async
-- callback open forever. On expiry the decrypt counts as failed, so the panel
-- stays closed (see fetchDetail) — the same graceful exit as a cancelled
-- pinentry, not a reopen.
local DECRYPT_TIMEOUT_MS = 300000

-- ── module state — caches only, no navigation state ────────────────────────
local lastQuery = nil     -- most recent onQuery text, for dropping stale async
local indexReady = false  -- the index file exists (built at least once)
local indexAt = 0         -- nowMs() of the last successful index build
local pendingIndex = false -- an index build is in flight
local detailCache = {} -- entryPath -> { at, ttl, password, hasOtp, username, fields }
-- id -> stub context for the row actions of the *currently rendered* detail
-- view. Only one detail view is ever live, so this is rebuilt on every render
-- rather than namespaced per entry.
local detailActions = {}
-- Most recently viewed entry path. The detail query is "<path> <filter>" and a
-- path can contain spaces, so splitDetailQuery() uses this (plus detailCache)
-- to decide where the path ends and the fuzzy filter begins.
local lastDetailPath = nil

-- ── small helpers ──────────────────────────────────────────────────────────
local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function storeDir()
  local p = noctalia.getConfig("storePath")
  if p == nil or p == "" then
    p = STORE_DEFAULT
  end
  return (noctalia.expandPath(p):gsub("/+$", ""))
end

-- Clipboard-clear timeout for `pass -c` / `pass otp -c` (Behaviour to preserve
-- #6): the clipTimeout setting wins when it parses to a positive integer, else
-- PASSWORD_STORE_CLIP_TIME from the environment (same test), else nil — let
-- `pass` fall back to its own default. Returned as a string, ready to drop
-- straight into an `env KEY=VAL` argv element.
local function positiveInt(raw)
  if raw == nil or raw == "" then
    return nil
  end
  local n = tonumber(raw)
  if n and n > 0 then
    return tostring(math.floor(n))
  end
  return nil
end

local function clipTimeout()
  return positiveInt(noctalia.getConfig("clipTimeout"))
      or positiveInt(noctalia.getenv("PASSWORD_STORE_CLIP_TIME"))
end

-- Non-negative integer setting (0 is a valid value here, unlike positiveInt),
-- with a fallback for a missing / non-numeric stored value. Used for the
-- typeDelay / wtypeDelay millisecond settings.
local function intSetting(key, default)
  local n = tonumber(noctalia.getConfig(key))
  if n == nil or n < 0 then
    return default
  end
  return math.floor(n)
end

-- Type actions shell out to `wtype`; probe for it once (the answer can't
-- change over a session) and drop the Type rows entirely when it's missing,
-- rather than letting every Type action fail.
local wtypeChecked, wtypeOk = false, false
local function wtypeAvailable()
  if not wtypeChecked then
    wtypeChecked = true
    wtypeOk = noctalia.commandExists("wtype") and true or false
  end
  return wtypeOk
end

-- The "Edit" action runs `pass edit` in a terminal (see editEntry). Noctalia's
-- own terminal picker isn't reachable from a plugin, so the terminal is
-- resolved here, in this order: the `terminalCommand` setting (a full argv
-- prefix that takes a command, incl. the exec flag — "foot -e", "kitty -e",
-- "gnome-terminal --"); then $TERMINAL + "-e"; then the first of a common list
-- that exists on PATH + "-e". nil when nothing resolves — the Edit row is
-- dropped then, the same way the Type rows drop without `wtype`.
local TERMINAL_CANDIDATES = { "ghostty", "kitty", "alacritty", "wezterm", "foot", "konsole", "xterm" }
local termProbe -- memoised PATH scan: nil = not scanned, false = none found, string = the winner

local function detectedTerminal()
  if termProbe == nil then
    termProbe = false
    for _, t in ipairs(TERMINAL_CANDIDATES) do
      if noctalia.commandExists(t) then
        termProbe = t
        break
      end
    end
  end
  return termProbe or nil
end

local function terminalArgv()
  local configured = trim(noctalia.getConfig("terminalCommand") or "")
  if configured ~= "" then
    local argv = {}
    for tok in configured:gmatch("%S+") do
      argv[#argv + 1] = tok
    end
    return argv
  end
  local envTerm = trim(noctalia.getenv("TERMINAL") or "")
  if envTerm ~= "" then
    return { envTerm, "-e" }
  end
  local found = detectedTerminal()
  return found and { found, "-e" } or nil
end

-- `env KEY=VAL ... <cmd...>` argv for a `pass` invocation: always exports
-- PASSWORD_STORE_DIR, and PASSWORD_STORE_CLIP_TIME too when `withClip` is set
-- and a timeout is configured. `cmd` is the pass command and its arguments as
-- a plain list ({"pass", "-c", entryPath}); no shell, no quoting.
-- `extraEnv` (optional) is a list of extra "KEY=VAL" argv elements to export
-- after the store dir — the Edit action uses it to set EDITOR.
local function passArgv(cmd, withClip, extraEnv)
  local argv = { "env", "PASSWORD_STORE_DIR=" .. storeDir() }
  if withClip then
    local t = clipTimeout()
    if t then
      argv[#argv + 1] = "PASSWORD_STORE_CLIP_TIME=" .. t
    end
  end
  if extraEnv then
    for _, e in ipairs(extraEnv) do
      argv[#argv + 1] = e
    end
  end
  for _, a in ipairs(cmd) do
    argv[#argv + 1] = a
  end
  return argv
end

-- Split the (trimmed) post-prefix query into a folder context and a search
-- term. Everything up to and including the last "/" is the folder; the rest is
-- the fuzzy search. No "/" -> root folder, whole text is the search.
local function splitPath(text)
  local folder, search = text:match("^(.*/)([^/]*)$")
  if folder == nil then
    return "", text
  end
  return (folder:gsub("/+$", "")), search
end

local function parentOf(path)
  return path:match("^(.*)/[^/]*$") or ""
end

-- Shared "Go back" row for both browse (subtitle = folder) and detail
-- (subtitle = entry path) views. `query` rewrites the launcher input, which
-- re-fires onQuery; a bare " " trims back to the root browse context.
local function goBackRow(parent, subtitle)
  return {
    id = "back:" .. parent,
    query = parent ~= "" and (parent .. "/") or " ",
    title = tr("result.go-back"),
    subtitle = subtitle,
    glyph = "arrow-left",
  }
end

local function fragments(search)
  local frags = {}
  for f in search:lower():gmatch("%S+") do
    frags[#frags + 1] = f
  end
  return frags
end

-- The QML fuzzyMatch() rule (Behaviour to preserve #4): every whitespace-split
-- fragment must appear as a contiguous, case-insensitive substring of the
-- target; the spaces between fragments act as wildcards, and order doesn't
-- matter. `hayLower` must already be lowercased; `frags` comes from fragments().
local function matchesFragments(hayLower, frags)
  for _, f in ipairs(frags) do
    if not string.find(hayLower, f, 1, true) then
      return false
    end
  end
  return true
end

-- ── store index (a file that grep filters per keystroke) ────────────────
-- `find` walks the store tree once into an index file: every non-hidden
-- `*.gpg` entry and every folder, as `%P` paths relative to the store root, a
-- trailing "/" marking folders. Every keystroke greps that file in a
-- subprocess, so filtering never spends the Luau CPU budget and the tree is
-- re-walked only on the background refresh past INDEX_TTL_MS. Luau parses only
-- the capped grep hit set.
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Escape ERE metacharacters so a folder name (which can hold ".", "+", …, e.g.
-- "web/bambulab.com") drops literally into a `grep -E` pattern.
local function reEsc(s)
  return (s:gsub("[%^%$%(%)%.%[%]%*%+%-%?{}|\\]", "\\%0"))
end

local function indexPath()
  return noctalia.pluginDataDir() .. "/store.index"
end

-- Rebuilds the index file. `onReady` (optional) fires afterwards whether the
-- build succeeded or not. Deduped via `pendingIndex`. The callback does almost
-- no Luau work (`find` redirects straight to the file), so it is safe at load.
local function buildIndex(onReady)
  if pendingIndex then
    return
  end
  pendingIndex = true
  local cmd = "find " .. shq(storeDir())
      .. " -mindepth 1 -name '.*' -prune"
      .. " -o -type f -name '*.gpg' -printf '%P\\n'"
      .. " -o -type d -printf '%P/\\n'"
      .. " > " .. shq(indexPath())
  noctalia.runAsync(cmd, function(result)
    pendingIndex = false
    if result.exitCode == 0 and not result.timedOut then
      indexReady = true
      indexAt = noctalia.nowMs()
    end
    if onReady then
      onReady()
    end
  end)
end

-- Search: AND-chain of `grep -iF` over the fragments (fixed-string, case
-- insensitive, order-independent — the QML substring rule), capped. Returned
-- as a shell string because the AND is a pipe chain.
local function searchGrepCmd(frags)
  local cmd = "grep -iF -e " .. shq(frags[1]) .. " " .. shq(indexPath())
  for i = 2, #frags do
    cmd = cmd .. " | grep -iF -e " .. shq(frags[i])
  end
  return cmd .. " | head -n " .. SCAN_CAP
end

-- Browse: exactly the direct children of `folder` (`grep -E`, bounded by that
-- folder's own child count). Still `| head`-capped as a paranoia bound so a
-- pathological folder can't hand Luau a huge list to sort.
local function browseGrepCmd(folder)
  local pat = folder == "" and "^[^/]+/?$" or ("^" .. reEsc(folder) .. "/[^/]+/?$")
  return "grep -E " .. shq(pat) .. " " .. shq(indexPath()) .. " | head -n " .. BROWSE_CAP
end

-- grep output line -> { fullPath, isDir }. `.gpg` stripped here.
local function parseHits(text)
  local hits = {}
  for line in text:gmatch("[^\n]+") do
    if line ~= "" then
      local isDir = line:sub(-1) == "/"
      local path = isDir and line:sub(1, -2) or line
      if not isDir and path:sub(-4) == ".gpg" then
        path = path:sub(1, -5)
      end
      if path ~= "" then
        hits[#hits + 1] = { fullPath = path, isDir = isDir }
      end
    end
  end
  return hits
end

-- ── ranking ──────────────────────────────────────────────────────────────
-- Cheap, pure-Luau relevance proxy — no C-boundary crossings, so it is safe
-- to run over every match of a broad query. Returns (segHits, depth):
--   segHits = how many fragments equal a whole path segment (an exact hit on
--             a "/"-bounded segment — e.g. the leaf "root" — beats a mere
--             substring, matching the QML intent).
--   depth   = number of path segments (shallower wins the tie).
-- The top SCORE_POOL rows by this key then get a real noctalia.fuzzyScore
-- pass for the final ordering (see renderSearchRows).
local function prerank(relLower, frags)
  local segs = {}
  for s in relLower:gmatch("[^/]+") do
    segs[#segs + 1] = s
  end
  local hits = 0
  for _, f in ipairs(frags) do
    for _, s in ipairs(segs) do
      if s == f then
        hits = hits + 1
        break
      end
    end
  end
  return hits, #segs
end

-- Sum of noctalia.fuzzyScore(fragment, path) — the host's native fzy scorer
-- (case-insensitive; exact = 1024; prefix / word-boundary / consecutive-run
-- bonuses). Per fragment so the match stays order-independent and the
-- inter-fragment space stays a wildcard; a fragment fzy rejects scores 0.
local function fuzzySum(relLower, frags)
  local score = 0
  for _, f in ipairs(frags) do
    score = score + (noctalia.fuzzyScore(f, relLower) or 0)
  end
  return score
end

-- ── result rows ───────────────────────────────────────────────────────────
local function entryRow(e, title)
  if e.isDir then
    return {
      id = "nav:" .. e.fullPath,
      query = e.fullPath .. "/",
      title = title,
      subtitle = tr("result.folder"),
      glyph = "folder",
    }
  end
  return {
    id = "entry:" .. e.fullPath,
    title = title,
    subtitle = tr("result.password"),
    glyph = "key",
  }
end

-- Browse rows: the grep already returned only direct children of `folder`
-- (`browseGrepArgv`); sort them by basename, cap, prepend "Go back".
local function renderBrowseRows(folder, hits)
  local rows = {}
  if folder ~= "" then
    rows[#rows + 1] = goBackRow(parentOf(folder), folder)
  end
  for _, h in ipairs(hits) do
    h.name = h.fullPath:match("[^/]+$") or h.fullPath
    h.nameLower = h.name:lower()
  end
  table.sort(hits, function(a, b)
    return a.nameLower < b.nameLower
  end)
  for i = 1, math.min(#hits, MAX_RESULTS) do
    rows[#rows + 1] = entryRow(hits[i], hits[i].name)
  end
  return rows
end

-- Search rows: `hits` is the capped grep set. Re-check matchesFragments
-- against each hit's path *relative to* `folder` (grep matched the raw line),
-- cheap prerank over every match, then a real noctalia.fuzzyScore pass over
-- only the top SCORE_POOL, cap at MAX_RESULTS. Rows show the folder-relative
-- path.
local function renderSearchRows(folder, frags, hits)
  local rows = {}
  if folder ~= "" then
    rows[#rows + 1] = goBackRow(parentOf(folder), folder)
  end

  local prefix = folder ~= "" and (folder .. "/") or ""
  local plen = #prefix

  local matched = {}
  for _, h in ipairs(hits) do
    local disp
    if plen == 0 then
      disp = h.fullPath
    elseif h.fullPath:sub(1, plen) == prefix then
      disp = h.fullPath:sub(plen + 1)
    end
    if disp then
      local rel = disp:lower()
      if matchesFragments(rel, frags) then
        matched[#matched + 1] = { h = h, disp = disp, rel = rel }
      end
    end
  end

  for _, m in ipairs(matched) do
    m.pre, m.depth = prerank(m.rel, frags)
  end
  table.sort(matched, function(a, b)
    if a.pre ~= b.pre then
      return a.pre > b.pre
    end
    if a.depth ~= b.depth then
      return a.depth < b.depth
    end
    return a.rel < b.rel
  end)

  local pool = math.min(#matched, SCORE_POOL)
  local head = {}
  for i = 1, pool do
    head[i] = matched[i]
    head[i].score = fuzzySum(head[i].rel, frags)
  end
  table.sort(head, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.depth ~= b.depth then
      return a.depth < b.depth
    end
    return a.rel < b.rel
  end)

  for i = 1, math.min(#head, MAX_RESULTS) do
    rows[#rows + 1] = entryRow(head[i].h, head[i].disp)
  end
  return rows
end


-- ── detail mode ───────────────────────────────────────────────────────────
-- Parse `pass show` output: first non-empty line is the password; every
-- later line with a ": " splits into a key/value field, in file order; any
-- line containing "otpauth://" flags the entry as OTP-capable.
local function parsePassEntry(output)
  local password, hasOtp = nil, false
  local fields = {}
  for line in output:gmatch("[^\n]+") do
    line = trim(line)
    if line ~= "" then
      if password == nil then
        password = line
      else
        if string.find(line, "otpauth://", 1, true) then
          hasOtp = true
        end
        local s, e = string.find(line, ": ", 1, true)
        if s then
          fields[#fields + 1] = { key = line:sub(1, s - 1), value = line:sub(e + 1) }
        end
      end
    end
  end
  return password or "", hasOtp, fields
end

-- Username = the value of the first login/user/username field (case
-- insensitive), with that field removed from the remaining list; falls back
-- to the entry's own basename when no such field exists.
local USERNAME_KEYS = { login = true, user = true, username = true }

local function extractUsername(entryPath, fields)
  local username, usedIndex
  for i, f in ipairs(fields) do
    if USERNAME_KEYS[f.key:lower()] then
      username, usedIndex = f.value, i
      break
    end
  end
  local remaining = {}
  for i, f in ipairs(fields) do
    if i ~= usedIndex then
      remaining[#remaining + 1] = f
    end
  end
  return username or (entryPath:match("[^/]+$") or entryPath), remaining
end

-- Build one action row for `spec` + `verb` ("copy" | "type"), record its
-- dispatch context in `detailActions` under an "act:<n>" id, and return the
-- row. `onActivate` reads the context back and hands it to `runAction`.
local function actionRow(entryPath, spec, verb, n)
  local id = "act:" .. n
  local isCopy = verb == "copy"
  local title = tr(isCopy and spec.copyKey or spec.typeKey, spec.subst)
  detailActions[id] = {
    entryPath = entryPath, verb = verb, kind = spec.kind,
    key = spec.key, value = spec.value, label = title,
  }
  return {
    id = id,
    title = title,
    subtitle = isCopy and spec.copySubtitle or spec.typeSubtitle,
    glyph = isCopy and "copy" or "typography",
  }
end

-- Value order (CLAUDE.md "Behaviour to implement"): password, OTP (if present),
-- username, then remaining key: value fields in file order. Within that, the
-- Copy/Type rows are laid out per the detailActionOrder (which verb first) and
-- detailActionGrouping (pair each value's rows, or all Copy then all Type)
-- settings.
--
-- `filter` is the text the user typed after "<entryPath> " in the detail
-- query. When non-empty it fuzzy-filters the rendered rows by title, using the
-- same rule as browse (matchesFragments) — so ":<path> otp" narrows to just
-- the Copy/Type OTP rows. `detailActions` is still populated for every row
-- (filtered-out ids simply never reach onActivate).
local function renderDetailRows(entryPath, data, filter)
  detailActions = {}
  local rows = { goBackRow(parentOf(entryPath), entryPath) }

  local specs = {
    {
      kind = "password",
      copyKey = "action.copy-password", typeKey = "action.type-password",
      copySubtitle = tr("action.copy-password-desc"), typeSubtitle = tr("action.type-password-desc"),
      value = data.password,
    },
  }
  if data.hasOtp then
    local otpDesc = tr("action.otp-desc")
    specs[#specs + 1] = {
      kind = "otp",
      copyKey = "action.copy-otp", typeKey = "action.type-otp",
      copySubtitle = otpDesc, typeSubtitle = otpDesc,
    }
  end
  specs[#specs + 1] = {
    kind = "username",
    copyKey = "action.copy-username", typeKey = "action.type-username",
    copySubtitle = data.username, typeSubtitle = data.username,
    value = data.username,
  }
  for _, f in ipairs(data.fields) do
    specs[#specs + 1] = {
      kind = "field", key = f.key, value = f.value, subst = { key = f.key },
      copyKey = "action.copy-field", typeKey = "action.type-field",
      copySubtitle = f.value, typeSubtitle = f.value,
    }
  end

  -- verbs to emit, in the configured order; "type" drops out when wtype is
  -- missing (leaving a single verb, so the order setting stops mattering).
  local ordered = noctalia.getConfig("detailActionOrder") == "type"
      and { "type", "copy" } or { "copy", "type" }
  local verbs = {}
  for _, v in ipairs(ordered) do
    if v == "copy" or wtypeAvailable() then
      verbs[#verbs + 1] = v
    end
  end

  local n = 0
  if noctalia.getConfig("detailActionGrouping") == "grouped" then
    for _, verb in ipairs(verbs) do
      for _, spec in ipairs(specs) do
        n = n + 1
        rows[#rows + 1] = actionRow(entryPath, spec, verb, n)
      end
    end
  else
    for _, spec in ipairs(specs) do
      for _, verb in ipairs(verbs) do
        n = n + 1
        rows[#rows + 1] = actionRow(entryPath, spec, verb, n)
      end
    end
  end

  -- "Edit" — spawn `pass edit` in a terminal (CLAUDE.md "Edit password
  -- action"). Sorted after all the Copy/Type rows; dropped, like the Type
  -- rows, when no terminal resolves (see terminalArgv). Row-filtered below
  -- along with everything else.
  if terminalArgv() then
    rows[#rows + 1] = {
      id = "edit:" .. entryPath,
      title = tr("action.edit"),
      subtitle = tr("action.edit-desc"),
      glyph = "pencil",
    }
  end

  -- "Generate" — regenerate the password in place (CLAUDE.md "Generate
  -- password action"). After the Edit row; activating it rewrites the query
  -- to ":!<entryPath>", the Generate confirm view (renderGenerateConfirmRows),
  -- rather than acting immediately.
  rows[#rows + 1] = {
    id = "gen:" .. entryPath,
    title = tr("action.generate"),
    subtitle = tr("action.generate-desc"),
    glyph = "refresh",
  }

  local frags = fragments(filter or "")
  if #frags == 0 then
    return rows
  end
  local kept = {}
  for _, r in ipairs(rows) do
    if matchesFragments((r.title or ""):lower(), frags) then
      kept[#kept + 1] = r
    end
  end
  return kept
end

-- The Generate confirm view. Reached by rewriting the query to
-- ":!<entryPath>" (onActivate on the "gen:" row → onQuery routes ":!" here) —
-- the same query-string-drives-navigation pattern as the ":" detail marker,
-- not a setResults() call from inside onActivate (which the host does not
-- render). Two static rows, no decrypt: Cancel is a `query` row back to the
-- normal detail view; "Regenerate now" is a genrun:<path> row that onActivate
-- hands to generateEntry.
local function renderGenerateConfirmRows(entryPath)
  return {
    {
      id = "gen-cancel",
      query = ":" .. entryPath .. " ",
      title = tr("action.generate-cancel"),
      subtitle = tr("action.generate-cancel-desc"),
      glyph = "arrow-left",
    },
    {
      id = "genrun:" .. entryPath,
      title = tr("action.generate-confirm"),
      subtitle = tr("action.generate-confirm-desc"),
      glyph = "alert-triangle",
    },
  }
end

-- ── pinentry dance ────────────────────────────────────────────────────────
-- `noctalia msg panel-close/panel-open <id> [context]` is the CLI IPC the
-- host binary exposes for its own panels (confirmed against the installed
-- `noctalia --help` / `noctalia msg --help` text: "Close the active panel,
-- or close the named panel if it is active" / "Open a panel by id,
-- optionally with context"). `panel-close` is a no-op unless the launcher is
-- the active panel, so this is safe to call even if it's already closed.
-- Argv form throughout — no shell parsing needed and none of these values
-- are attacker-controlled anyway, but it's the house style (see CLAUDE.md
-- "Subprocess rules").
local function closeLauncherPanel(cb)
  noctalia.runAsync({ "noctalia", "msg", "panel-close", "launcher" }, cb)
end

-- The character that starts a launcher command (our own CLAUDE.md examples
-- write ">pass ...", but the leading ">" itself is a user setting —
-- shell.launcher.provider_prefix, e.g. "/" on this system). Reading it wrong
-- would reopen the panel with a string it no longer recognises as a command
-- at all. noctalia.getSetting requires plugin_api = 26.
local DEFAULT_LEADER = ">"

local function launcherLeader()
  return noctalia.getSetting("shell.launcher.provider_prefix") or DEFAULT_LEADER
end

-- Reopens with the exact input the launcher had before it was closed, as the
-- panel's "context" argument — the host re-delivers that as a fresh onQuery,
-- so whatever is now in detailCache / the store index gets rendered without this
-- script tracking "what was on screen" itself. `text` is the raw onQuery
-- text (no leader/prefix), so the context reconstructs the full input.
local function reopenLauncherPanel(text)
  local context = launcherLeader() .. "pass " .. text
  noctalia.runAsync({ "noctalia", "msg", "panel-open", "launcher", context }, function() end)
end

-- If `pass show` finishes within this grace period, gpg-agent already had
-- the passphrase cached — no pinentry dialog ever appeared, so closing and
-- reopening the panel would just be a pointless flicker. Configurable via
-- the pinentryGraceMs setting; this is only the fallback for a
-- missing/invalid value. Lower values favour a real pinentry dialog getting
-- focus promptly at the cost of more flicker on a warm cache; higher values
-- (~200/300ms) trade that flicker away but give the dialog more time to pop
-- up before the panel closes, and whether it then grabs focus at all depends
-- on the window manager.
local PINENTRY_GRACE_DEFAULT_MS = 50

local function pinentryGraceMs()
  local ms = tonumber(noctalia.getConfig("pinentryGraceMs"))
  if ms == nil or ms < 0 then
    return PINENTRY_GRACE_DEFAULT_MS
  end
  return ms
end

-- Split the post-":" text into (entryPath, filter). The detail query is
-- "<entryPath> <filter>" (onActivate appends the space) and an entry path can
-- itself contain spaces, so the boundary is resolved against known paths
-- rather than the first space: the last-viewed entry first, then any warm
-- detailCache key, longest match winning. Nothing known yet (the very first
-- decrypt) → the whole trimmed string is the path, no filter.
local function splitDetailQuery(rest)
  local function tryPath(p)
    if p == nil or p == "" then
      return nil
    end
    if rest == p then
      return p, ""
    end
    if #rest > #p and rest:sub(1, #p + 1) == p .. " " then
      return p, trim(rest:sub(#p + 2))
    end
    return nil
  end

  local p, f = tryPath(lastDetailPath)
  if p then
    return p, f
  end

  local bestPath, bestFilter
  for cached in pairs(detailCache) do
    local cp, cf = tryPath(cached)
    if cp and (bestPath == nil or #cp > #bestPath) then
      bestPath, bestFilter = cp, cf
    end
  end
  if bestPath then
    return bestPath, bestFilter
  end

  return trim(rest), ""
end

-- Decrypts `entryPath` (cached — see DETAIL_TTL_MS) and publishes its detail
-- rows. `text` is the raw onQuery text (leading ":" + entryPath + " " +
-- filter), echoed back to setResults / checked against lastQuery exactly like
-- the browse path. `filter` fuzzy-narrows the rendered rows (see
-- renderDetailRows).
local function fetchDetail(entryPath, text, filter)
  lastDetailPath = entryPath -- disambiguates the next splitDetailQuery

  local hit = detailCache[entryPath]
  if hit and (noctalia.nowMs() - hit.at) < hit.ttl then
    launcher.setResults(text, renderDetailRows(entryPath, hit, filter))
    return
  end

  launcher.setResults(text, {
    goBackRow(parentOf(entryPath), entryPath),
    { id = "decrypting", title = tr("detail.decrypting"), glyph = "refresh" },
  })

  -- Populate detailCache / setResults *before* reopening the panel: reopening
  -- re-delivers `text` to onQuery, and that re-entrant fetchDetail must see a
  -- warm cache or it would start a second `pass show` (and a second pinentry
  -- prompt) right on top of this one.
  local function afterShow(result)
    if lastQuery ~= text then
      return -- a newer query superseded this one
    end
    if result.exitCode ~= 0 or result.timedOut then
      -- Decrypt failed — the user dismissed the pinentry dialog, or gpg
      -- errored, or it timed out. Show the error row for the case where the
      -- panel is still open (grace period never elapsed); when the panel was
      -- closed for pinentry this is a no-op the user won't see, and crucially
      -- the caller does *not* reopen it (that would re-fire onQuery ->
      -- fetchDetail -> a fresh `pass show` with no user action between, looping
      -- the prompt forever).
      launcher.setResults(text, {
        goBackRow(parentOf(entryPath), entryPath),
        { id = "error", title = tr("detail.error"), subtitle = entryPath, glyph = "alert-triangle" },
      })
      return
    end

    local password, hasOtp, fields = parsePassEntry(result.stdout or "")
    local username, remaining = extractUsername(entryPath, fields)
    local data = {
      at = noctalia.nowMs(),
      ttl = DETAIL_TTL_MS,
      password = password,
      hasOtp = hasOtp,
      username = username,
      fields = remaining,
    }
    detailCache[entryPath] = data
    launcher.setResults(text, renderDetailRows(entryPath, data, filter))
  end

  -- Race the decrypt against a short grace period instead of closing the
  -- panel up front: if gpg-agent already has the passphrase cached, `pass
  -- show` returns almost instantly with no pinentry dialog ever appearing,
  -- and closing/reopening the panel for that would be a pointless flicker.
  -- Only if the grace period elapses first do we assume pinentry is up and
  -- belatedly close the panel so it can get focus.
  local resolved = false   -- true once the `pass show` callback has fired
  local panelClosed = false -- true once the panel was actually closed

  noctalia.runAsync(
    passArgv({ "pass", "show", entryPath }),
    function(result)
      resolved = true
      afterShow(result)
      -- Reopen only on a successful decrypt. On failure (cancelled pinentry,
      -- gpg error, timeout) the passphrase is no longer wanted; reopening
      -- would re-deliver `text` to onQuery and start the whole `pass show` /
      -- pinentry cycle again with nothing user-driven to break it. Leaving
      -- the launcher closed is the graceful exit — the user reopens it to
      -- retry.
      local ok = result.exitCode == 0 and not result.timedOut
      if panelClosed and ok then
        reopenLauncherPanel(text)
      end
    end,
    DECRYPT_TIMEOUT_MS
  )

  noctalia.runAsync({ "sleep", tostring(pinentryGraceMs() / 1000) }, function()
    if resolved then
      return -- `pass show` already finished — no pinentry dialog to focus
    end
    panelClosed = true
    closeLauncherPanel(function() end)
  end)
end

-- ── detail-row actions ────────────────────────────────────────────────────
-- Copy actions close the launcher up front, exactly as the QML version did
-- with launcher.close(): with the panel gone a GPG pinentry prompt (from an
-- expired gpg-agent cache) receives focus on its own, so `pass -c` needs no
-- close/reopen dance around it — and the launcher staying closed afterwards
-- is the terminal state QML's copy actions left it in. `pass -c` clears the
-- clipboard itself after PASSWORD_STORE_CLIP_TIME (see passArgv / clipTimeout).
local function copyViaPass(cmd, subject)
  closeLauncherPanel(function()
    noctalia.runAsync(passArgv(cmd, true), function(result)
      if result.exitCode == 0 and not result.timedOut then
        noctalia.notify(tr("notification.copied"), subject)
      else
        noctalia.notifyError(tr("notification.copy-failed"), subject)
      end
    end, DECRYPT_TIMEOUT_MS)
  end)
end

-- Plain-value copy — the username, and (next step) the key: value fields.
-- These values are already in memory from the earlier `pass show`, so there's
-- no subprocess and no pinentry: copy straight through noctalia.copyToClipboard
-- and close the launcher, the same terminal state as the `pass -c` path (QML
-- likewise closed the launcher before piping the value to wl-copy). No
-- clipboard auto-clear here — `pass` isn't in the loop — matching QML, which
-- only ran the clearing timer for `pass -c` / `pass otp -c`.
-- noctalia.copyToClipboard requires the MIME type as a second argument
-- (it errors "missing argument #2 ... string expected" without it).
local CLIP_MIME = "text/plain"

local function copyPlain(value, subject)
  noctalia.copyToClipboard(value or "", CLIP_MIME)
  noctalia.notify(tr("notification.copied"), subject)
  closeLauncherPanel(function() end)
end

-- ── type actions (wtype) ─────────────────────────────────────────────────
-- Noctalia has no plugin-facing keystroke/paste API — a launcher provider
-- can't opt into the host's native auto-paste (PluginLauncherProvider never
-- reports supportsAutoPaste()), so typing is done here with `wtype`.
--
-- `wtype` types into whatever window currently holds focus, so every Type
-- action closes the launcher panel first (as QML did with launcher.close()),
-- then waits `typeDelay` ms for the compositor to hand focus back to the
-- window the user was on before feeding the value to `wtype -d <wtypeDelay>`.
-- The value goes after `--` as a single positional arg, so a value starting
-- with "-" is still treated as text and no shell / quote-escaping is needed
-- (unlike QML's `printf … | wtype -` pipe).
local function typeValue(value, subject)
  noctalia.runAsync({ "sleep", tostring(intSetting("typeDelay", 500) / 1000) }, function()
    noctalia.runAsync(
      { "wtype", "-d", tostring(intSetting("wtypeDelay", 12)), "--", value or "" },
      function(result)
        if result.exitCode ~= 0 or result.timedOut then
          noctalia.notifyError(tr("notification.type-failed"), subject)
        end
      end
    )
  end)
end

-- Plain value already in memory (password / username / field): close the
-- launcher, then type it.
local function typeViaWtype(value, subject)
  closeLauncherPanel(function()
    typeValue(value, subject)
  end)
end

-- OTP: the code isn't cached, so fetch it with `pass otp` (no -c) first. That
-- can hit pinentry, which gets focus fine since the panel is already closed.
local function typeOtp(entryPath, subject)
  closeLauncherPanel(function()
    noctalia.runAsync(passArgv({ "pass", "otp", entryPath }), function(result)
      if result.exitCode == 0 and not result.timedOut then
        typeValue(trim(result.stdout or ""), subject)
      else
        noctalia.notifyError(tr("notification.type-failed"), subject)
      end
    end, DECRYPT_TIMEOUT_MS)
  end)
end

-- ── edit action ──────────────────────────────────────────────────────────
-- `pass edit <entry>` decrypts the file into $EDITOR and re-encrypts it on
-- save, so it needs a real terminal — spawned via terminalArgv(). It can also
-- pop a pinentry dialog, so the launcher is closed first (and not reopened,
-- like the Copy/Type paths). The decrypted detail cache for this entry is
-- dropped afterwards so the next detail view reflects the edit. No runAsync
-- timeout: an interactive edit session is open-ended.
--
-- The `editorCommand` setting, when non-empty, is exported as EDITOR for the
-- run; blank leaves EDITOR unset so `pass` falls back to its own default.
local function editEntry(entryPath)
  local subject = entryPath:match("[^/]+$") or entryPath
  local term = terminalArgv()
  if term == nil then
    noctalia.notifyError(tr("notification.edit-failed"), subject)
    return
  end
  local editor = trim(noctalia.getConfig("editorCommand") or "")
  local extraEnv = editor ~= "" and { "EDITOR=" .. editor } or nil
  closeLauncherPanel(function()
    local argv = {}
    for _, a in ipairs(term) do
      argv[#argv + 1] = a
    end
    for _, a in ipairs(passArgv({ "pass", "edit", entryPath }, false, extraEnv)) do
      argv[#argv + 1] = a
    end
    noctalia.runAsync(argv, function(result)
      detailCache[entryPath] = nil
      if result.exitCode ~= 0 or result.timedOut then
        noctalia.notifyError(tr("notification.edit-failed"), subject)
      end
    end)
  end)
end

-- ── generate action ──────────────────────────────────────────────────────
-- `pass generate -i <entry>` replaces only the first line (the password);
-- username, OTP and other fields are kept. It decrypts the existing file, so
-- it can pop pinentry — the launcher is closed up front (like the Copy/Type
-- paths) so the dialog gets focus, then reopened into this entry's detail
-- view on success so the user can Copy/Type the new password. The detail
-- cache is dropped first so the reopen re-decrypts. On failure the panel
-- stays closed (same graceful exit as fetchDetail — no reopen loop).
local function generateEntry(entryPath)
  local subject = entryPath:match("[^/]+$") or entryPath
  closeLauncherPanel(function()
    noctalia.runAsync(passArgv({ "pass", "generate", "-i", entryPath }), function(result)
      if result.exitCode == 0 and not result.timedOut then
        detailCache[entryPath] = nil
        noctalia.notify(tr("notification.generated"), subject)
        reopenLauncherPanel(":" .. entryPath .. " ")
      else
        noctalia.log("launcher-pass: `pass generate -i " .. entryPath .. "` failed"
          .. " (exit " .. tostring(result.exitCode) .. (result.timedOut and ", timed out" or "")
          .. "): " .. trim(result.stderr or ""))
        noctalia.notifyError(tr("notification.generate-failed"), subject)
      end
    end, DECRYPT_TIMEOUT_MS)
  end)
end

-- Dispatch one detail row's recorded action.
--   copy: password / OTP go through `pass -c` / `pass otp -c` (copyViaPass:
--     clip-timeout env + close-launcher-first pinentry handling); username and
--     fields are copied verbatim from memory via copyPlain.
--   type: `wtype`, after a launcher close + typeDelay; OTP is fetched with
--     `pass otp` first. (Type rows only exist when `wtype` is installed.)
local function runAction(ctx)
  local subject = ctx.entryPath:match("[^/]+$") or ctx.entryPath
  local fieldSubject = ctx.kind == "field" and (ctx.key or subject) or subject

  if ctx.verb == "type" then
    if ctx.kind == "otp" then
      typeOtp(ctx.entryPath, subject)
    else
      typeViaWtype(ctx.value, fieldSubject)
    end
    return
  end

  if ctx.kind == "password" then
    copyViaPass({ "pass", "-c", ctx.entryPath }, subject)
  elseif ctx.kind == "otp" then
    copyViaPass({ "pass", "otp", "-c", ctx.entryPath }, subject)
  else
    copyPlain(ctx.value, fieldSubject)
  end
end

-- ── host hooks ────────────────────────────────────────────────────────────
function onQuery(text)
  lastQuery = text

  -- ":!<entryPath>" — the Generate confirm view (the "gen:" row rewrites the
  -- query to this via onActivate). Checked before the ":" detail marker
  -- because "^%s*:(.+)$" would match it too. The whole trimmed remainder is
  -- the entry path (the confirm view has no row filter, so no split needed).
  local genRest = text:match("^%s*:!(.+)$")
  if genRest then
    launcher.setResults(text, renderGenerateConfirmRows(trim(genRest)))
    return
  end

  -- A leading ":" is never produced by browsing (folder/search text has no
  -- reason to start with it), so it doubles as the detail-mode marker. The
  -- rest is "<entryPath>" or "<entryPath> <filter>" — split via
  -- splitDetailQuery (the trailing space onActivate appends means the "just
  -- opened" form is "<entryPath> " → filter ""). A fresh ">pass " (no marker)
  -- always falls through to browse, resetting detail state for free. Parsed
  -- off `text` directly, not the trimmed copy, so the filter's own spacing
  -- survives.
  local detailRest = text:match("^%s*:(.+)$")
  if detailRest then
    local entryPath, filter = splitDetailQuery(detailRest)
    fetchDetail(entryPath, text, filter)
    return
  end

  local trimmed = trim(text)
  local folder, search = splitPath(trimmed)
  local frags = fragments(search)

  -- Grep the index file for this query. grep exits 1 (no lines) as well as 0
  -- (matches) — both are success; anything else / a timeout renders as empty.
  local function dispatch()
    if (noctalia.nowMs() - indexAt) >= INDEX_TTL_MS then
      buildIndex(nil) -- refresh in the background; grep the current file now
    end
    local function onGrep(render)
      return function(result)
        if lastQuery ~= text then
          return -- a newer query superseded this one
        end
        local ok = (result.exitCode == 0 or result.exitCode == 1) and not result.timedOut
        local hits = ok and parseHits(result.stdout or "") or {}
        launcher.setResults(text, render(hits))
      end
    end
    if #frags == 0 then
      noctalia.runAsync(browseGrepCmd(folder), onGrep(function(hits)
        return renderBrowseRows(folder, hits)
      end))
    else
      noctalia.runAsync(searchGrepCmd(frags), onGrep(function(hits)
        return renderSearchRows(folder, frags, hits)
      end))
    end
  end

  if indexReady then
    dispatch()
    return
  end

  launcher.setResults(text, {
    { id = "loading", title = tr("result.loading"), glyph = "refresh" },
  })
  buildIndex(function()
    if lastQuery ~= text then
      return -- a newer query superseded this one
    end
    dispatch()
  end)
end

function onActivate(id)
  if id == nil or id == "" or id == "loading" or id == "decrypting" or id == "error" then
    return
  end

  local kind, rest = id:match("^(%a+):(.*)$")
  if kind == "nav" then
    launcher.setQuery(rest .. "/")
  elseif kind == "back" then
    launcher.setQuery(rest ~= "" and (rest .. "/") or " ")
  elseif kind == "entry" then
    -- Trailing space: detail mode is ":<path> <filter>", so the just-opened
    -- state is ":<path> " with an empty filter, ready for the user to type a
    -- row filter (":<path> otp" → only the OTP rows).
    launcher.setQuery(":" .. rest .. " ")
  elseif kind == "edit" then
    editEntry(rest)
  elseif kind == "gen" then
    -- Rewrite to the Generate confirm view (":!<path>"), mirroring how
    -- "entry:" opens the detail view. A trailing space keeps the reconstructed
    -- launcher input tidy; onQuery trims it back off.
    launcher.setQuery(":!" .. rest .. " ")
  elseif kind == "genrun" then
    generateEntry(rest)
  elseif kind == "act" then
    local ctx = detailActions[id]
    if ctx then
      runAction(ctx)
    end
  end
end

-- Build the store index at load so the first query renders without waiting on
-- `find`.
buildIndex(nil)
