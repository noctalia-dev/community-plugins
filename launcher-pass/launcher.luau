--!nonstrict
-- launcher-pass — Noctalia v5 launcher provider for the GNU Pass store.
-- Design notes and the QML-era behaviour archaeology live in CLAUDE.md.
--
-- Browse mode:
--   * "<leader>pass" / "<leader>pass <query>" routing (Noctalia strips the
--     leader + trigger and calls onQuery with the rest)
--   * store listing via `find`; recursive search is pre-filtered in the
--     subprocess with piped `grep -iF` so Luau only ever handles matched lines
--   * match semantics (matchesFragments): whitespace-split query, every
--     fragment a contiguous case-insensitive substring, order-independent
--   * ranking (see rankEntry): sum of noctalia.fuzzyScore(fragment, path)
--     — the host's native fzy scorer — then depth, then alphabetical
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
-- (pinentryGraceMs, default 200ms), and if gpg-agent already had the
-- passphrase cached the result comes back before the grace period elapses,
-- so the panel is never touched at all.

local STORE_DEFAULT = "~/.password-store"
local MAX_RESULTS = 50
-- Hard cap on lines pulled out of the grep pipe before scoring. QML scored the
-- whole match set then took 50; for a pathological one-letter query this keeps
-- Luau's work bounded, at the cost of approximate ranking past this many hits.
local GREP_CAP = 500
local BROWSE_TTL_MS = 30000
local SEARCH_TTL_MS = 8000
-- Decrypted entries stay cached a while so re-rendering the same detail view
-- (e.g. a debounce re-fire) doesn't trigger a second `pass show` / pinentry.
local DETAIL_TTL_MS = 60000
-- `pass show` pauses on pinentry for as long as the user takes to enter a
-- passphrase or touch a hardware key — that can legitimately be a while, and
-- cutting it short would kill pinentry mid-entry. This is a safety net, not a
-- UX timer: it only exists so a truly wedged gpg-agent eventually reopens the
-- launcher panel instead of leaving it closed forever.
local DECRYPT_TIMEOUT_MS = 300000

-- ── module state — caches only, no navigation state ────────────────────────
local lastQuery = nil -- most recent onQuery text, for dropping stale async
local listCache = {}  -- cacheKey -> { at = <ms>, ttl = <ms>, entries = { ... } }
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

-- single-quote wrap for the string (shell) form of runAsync
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
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

-- `env KEY=VAL ... <cmd...>` argv for a `pass` invocation: always exports
-- PASSWORD_STORE_DIR, and PASSWORD_STORE_CLIP_TIME too when `withClip` is set
-- and a timeout is configured. `cmd` is the pass command and its arguments as
-- a plain list ({"pass", "-c", entryPath}); no shell, no quoting.
local function passArgv(cmd, withClip)
  local argv = { "env", "PASSWORD_STORE_DIR=" .. storeDir() }
  if withClip then
    local t = clipTimeout()
    if t then
      argv[#argv + 1] = "PASSWORD_STORE_CLIP_TIME=" .. t
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

local function folderDir(folder)
  if folder == "" then
    return storeDir()
  end
  return storeDir() .. "/" .. folder
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
    title = tr("result.goBack"),
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

-- ── ranking ──────────────────────────────────────────────────────────────
-- Returns (score, depth) for one entry against the query fragments:
--   score = sum of noctalia.fuzzyScore(fragment, path) — the host's native
--           fzy scorer (case-insensitive; exact match = 1024; bonuses for
--           prefix / word-boundary / consecutive-run matches; longer text
--           penalised). A fragment the scorer rejects contributes 0 — it
--           already passed matchesFragments, so the row stays, just ranks
--           low. Summing per fragment keeps the match order-independent and
--           the inter-fragment space a wildcard, unlike passing the whole
--           query as one fzy pattern.
--   depth = number of path segments (shallower wins the tie)
-- Rows are then sorted by score desc, depth asc, then path alphabetically.
-- Moving the scoring into the C scorer is the point of this step — for a big
-- store with a broad query it runs over the whole capped grep hit set.
local function rankEntry(nameLower, frags)
  local score = 0
  for _, f in ipairs(frags) do
    score = score + (noctalia.fuzzyScore(f, nameLower) or 0)
  end
  local _, slashes = nameLower:gsub("/", "")
  return score, slashes + 1
end

-- ── subprocess commands ───────────────────────────────────────────────────
-- Browse: immediate children of `dir` (files *.gpg + non-hidden dirs). Small,
-- so it runs as a plain argv (no shell).
local function browseArgv(dir)
  return {
    "find", dir, "-maxdepth", "1", "-mindepth", "1",
    "-type", "f", "-name", "*.gpg", "-printf", "%f\n",
    "-o", "-type", "d", "-not", "-name", ".*", "-printf", "%f/\n",
  }
end

local function browseCacheKey(dir)
  return table.concat({ dir, "s", "" }, "\0")
end

-- Recursive search: every *.gpg path under `dir`, AND-filtered by the query
-- fragments with a chain of `grep -iF` (fixed-string, case-insensitive,
-- order-independent — the same semantics as the QML substring test), capped.
local function searchCmd(dir, frags)
  local cmd = "find " .. shq(dir) .. " -mindepth 1 -type f -name '*.gpg' -printf '%P\\n'"
  for _, f in ipairs(frags) do
    cmd = cmd .. " | grep -iF -e " .. shq(f)
  end
  return cmd .. " | head -n " .. GREP_CAP
end

-- ── parse `find` / grep output into entry rows ────────────────────────────
-- { name, nameLower, fullPath, isDir }. recursive == true: names may contain
-- "/", so parent folders are synthesised as their own rows.
local function parseEntries(text, folder, recursive)
  local entries = {}
  local seenDirs = {}
  local skipName = nil
  if folder ~= "" then
    skipName = folder:match("[^/]+$") or folder
  end

  for line in text:gmatch("[^\n]+") do
    line = trim(line)
    if line ~= "" then
      local isDir = line:sub(-1) == "/"
      local name = isDir and line:sub(1, -2) or line
      if not isDir and name:sub(-4) == ".gpg" then
        name = name:sub(1, -5)
      end

      if not (isDir and name == skipName) then
        local fullPath = folder == "" and name or (folder .. "/" .. name)

        if recursive then
          local parent = name:match("^(.*)/[^/]*$")
          if parent and parent ~= "" and not seenDirs[parent] then
            seenDirs[parent] = true
            local parentFull = folder == "" and parent or (folder .. "/" .. parent)
            entries[#entries + 1] = {
              name = parent,
              nameLower = parent:lower(),
              fullPath = parentFull,
              isDir = true,
            }
          end
        end

        entries[#entries + 1] = {
          name = name,
          nameLower = name:lower(),
          fullPath = fullPath,
          isDir = isDir,
        }
      end
    end
  end

  return entries
end

-- ── background prefetch ──────────────────────────────────────────────────
-- Navigation always drills into a folder already visible in the current list,
-- so as soon as a browse view is rendered its child folders are listed in the
-- background. Activating one then hits a warm cache and renders with no
-- subprocess on the critical path.
local PREFETCH_MAX = 10
local pendingFetch = {} -- browse cacheKey -> true while a background find runs

local function prefetchBrowse(dir, folderPath)
  local key = browseCacheKey(dir)
  local hit = listCache[key]
  if pendingFetch[key] or (hit and (noctalia.nowMs() - hit.at) < hit.ttl) then
    return
  end
  pendingFetch[key] = true
  noctalia.runAsync(browseArgv(dir), function(result)
    pendingFetch[key] = nil
    if result.exitCode == 0 and not result.timedOut then
      listCache[key] = {
        at = noctalia.nowMs(),
        ttl = BROWSE_TTL_MS,
        entries = parseEntries(result.stdout or "", folderPath, false),
      }
    end
  end)
end

local function prefetchChildren(entries)
  local base = storeDir()
  local n = 0
  for _, e in ipairs(entries) do
    if e.isDir then
      n = n + 1
      if n > PREFETCH_MAX then
        break
      end
      prefetchBrowse(base .. "/" .. e.fullPath, e.fullPath)
    end
  end
end

-- ── result rows ───────────────────────────────────────────────────────────
local function renderRows(folder, search, entries)
  local rows = {}

  if folder ~= "" then
    rows[#rows + 1] = goBackRow(parentOf(folder), folder)
  end

  local frags = fragments(search)

  -- Re-check fragments against the suffix-stripped name: `grep` matched the raw
  -- "%P" line (with ".gpg"), whereas QML fuzzy-matched the stripped name, and
  -- synthesised parent-folder rows were fuzzy-matched too. Cheap: the grep
  -- output is already small.
  local matched = {}
  for _, e in ipairs(entries) do
    if matchesFragments(e.nameLower, frags) then
      matched[#matched + 1] = e
    end
  end

  if #frags == 0 then
    -- empty search (folder browse): pure alphabetical
    table.sort(matched, function(a, b)
      return a.nameLower < b.nameLower
    end)
  else
    for _, e in ipairs(matched) do
      e.score, e.depth = rankEntry(e.nameLower, frags)
    end
    table.sort(matched, function(a, b)
      if a.score ~= b.score then
        return a.score > b.score
      end
      if a.depth ~= b.depth then
        return a.depth < b.depth
      end
      return a.nameLower < b.nameLower
    end)
  end

  local n = math.min(#matched, MAX_RESULTS)
  for i = 1, n do
    local e = matched[i]
    if e.isDir then
      rows[#rows + 1] = {
        id = "nav:" .. e.fullPath,
        query = e.fullPath .. "/",
        title = e.name,
        subtitle = tr("result.folder"),
        glyph = "folder",
      }
    else
      rows[#rows + 1] = {
        id = "entry:" .. e.fullPath,
        title = e.name,
        subtitle = tr("result.password"),
        glyph = "key",
      }
    end
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
      copyKey = "action.copyPassword", typeKey = "action.typePassword",
      copySubtitle = tr("action.copyPasswordDesc"), typeSubtitle = tr("action.typePasswordDesc"),
      value = data.password,
    },
  }
  if data.hasOtp then
    local otpDesc = tr("action.otpDesc")
    specs[#specs + 1] = {
      kind = "otp",
      copyKey = "action.copyOtp", typeKey = "action.typeOtp",
      copySubtitle = otpDesc, typeSubtitle = otpDesc,
    }
  end
  specs[#specs + 1] = {
    kind = "username",
    copyKey = "action.copyUsername", typeKey = "action.typeUsername",
    copySubtitle = data.username, typeSubtitle = data.username,
    value = data.username,
  }
  for _, f in ipairs(data.fields) do
    specs[#specs + 1] = {
      kind = "field", key = f.key, value = f.value, subst = { key = f.key },
      copyKey = "action.copyField", typeKey = "action.typeField",
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
-- so whatever is now in detailCache/listCache gets rendered without this
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
-- missing/invalid value.
local PINENTRY_GRACE_DEFAULT_MS = 200

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
      if panelClosed then
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
        noctalia.notifyError(tr("notification.copyFailed"), subject)
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
          noctalia.notifyError(tr("notification.typeFailed"), subject)
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
        noctalia.notifyError(tr("notification.typeFailed"), subject)
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
  local recursive = search ~= ""
  local dir = folderDir(folder)
  local cacheKey = recursive
      and table.concat({ dir, "r", search }, "\0")
      or browseCacheKey(dir)

  local function publish(entries)
    if not recursive then
      prefetchChildren(entries) -- warm the sub-folders the user might open next
    end
    launcher.setResults(text, renderRows(folder, search, entries))
  end

  local hit = listCache[cacheKey]
  if hit and (noctalia.nowMs() - hit.at) < hit.ttl then
    publish(hit.entries)
    return
  end

  launcher.setResults(text, {
    { id = "loading", title = tr("result.loading"), glyph = "refresh" },
  })

  local cb = function(result)
    local entries = {}
    if result.exitCode == 0 and not result.timedOut then
      entries = parseEntries(result.stdout or "", folder, recursive)
    end
    listCache[cacheKey] = {
      at = noctalia.nowMs(),
      ttl = recursive and SEARCH_TTL_MS or BROWSE_TTL_MS,
      entries = entries,
    }
    if lastQuery ~= text then
      return -- a newer query superseded this one
    end
    publish(entries)
  end

  if recursive then
    noctalia.runAsync(searchCmd(dir, fragments(search)), cb)
  else
    noctalia.runAsync(browseArgv(dir), cb)
  end
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
  elseif kind == "act" then
    local ctx = detailActions[id]
    if ctx then
      runAction(ctx)
    end
  end
end

-- Warm the store-root listing at load so the first ">pass" renders instantly;
-- rendering it then prefetches its sub-folders, and so on down the tree.
prefetchBrowse(storeDir(), "")
