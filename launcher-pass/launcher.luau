--!nonstrict
-- launcher-pass — Noctalia v5 launcher provider for the GNU Pass store.
--
-- Port step 1 of the QML -> Luau rewrite (see CLAUDE.md): browse mode only.
-- Implemented here:
--   * ">pass" / ">pass <query>" prefix routing (Noctalia strips the prefix)
--   * store listing via `find`; recursive search is pre-filtered in the
--     subprocess with piped `grep -iF` so Luau only ever handles matched lines
--   * match semantics from LauncherProvider.qml's fuzzyMatch(): whitespace-split
--     query, every fragment a contiguous substring, order-independent
--   * ranking: query-aware (see rankEntry) — the QML base-27 segment score let
--     leaf *length* dominate, floating "foo_new_1" above a shallower "foo"
--   * folder drill-in / "Go back", with the navigation state carried entirely
--     in the launcher query string (a trailing "/" marks a folder context)
--
-- NOT implemented yet (later steps): `pass show`, copy/type, OTP, clipboard
-- timeout, wtype. Activating a password entry is a stub notification.

local STORE_DEFAULT = "~/.password-store"
local MAX_RESULTS = 50
-- Hard cap on lines pulled out of the grep pipe before scoring. QML scored the
-- whole match set then took 50; for a pathological one-letter query this keeps
-- Luau's work bounded, at the cost of approximate ranking past this many hits.
local GREP_CAP = 500
local BROWSE_TTL_MS = 30000
local SEARCH_TTL_MS = 8000

-- ── module state — caches only, no navigation state ────────────────────────
local lastQuery = nil -- most recent onQuery text, for dropping stale async
local listCache = {}  -- cacheKey -> { at = <ms>, ttl = <ms>, entries = { ... } }

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

local function fragments(search)
  local frags = {}
  for f in search:lower():gmatch("%S+") do
    frags[#frags + 1] = f
  end
  return frags
end

-- ── ranking ──────────────────────────────────────────────────────────────
-- Returns (exact, depth) for one entry against the query fragments:
--   exact = how many fragments equal a whole path segment (an exact hit on a
--           segment boundary beats a mere substring — e.g. "root" == the leaf
--           "root" ranks above "root" inside "root_new_1")
--   depth = number of path segments (shallower wins the tie)
-- Rows are then sorted by exact desc, depth asc, then full path alphabetically.
local function rankEntry(nameLower, frags)
  local segs = {}
  for s in nameLower:gmatch("[^/]+") do
    segs[#segs + 1] = s
  end
  local exact = 0
  for _, f in ipairs(frags) do
    for _, s in ipairs(segs) do
      if s == f then
        exact = exact + 1
        break
      end
    end
  end
  return exact, #segs
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
    local parent = folder:match("^(.*)/[^/]*$") or ""
    rows[#rows + 1] = {
      id = "back:" .. parent,
      -- rewrites the launcher input, which re-fires onQuery; a bare " " trims
      -- back to the root context
      query = parent ~= "" and (parent .. "/") or " ",
      title = tr("result.goBack"),
      subtitle = folder,
      glyph = "arrow-left",
    }
  end

  local frags = fragments(search)

  -- Re-check fragments against the suffix-stripped name: `grep` matched the raw
  -- "%P" line (with ".gpg"), whereas QML fuzzy-matched the stripped name, and
  -- synthesised parent-folder rows were fuzzy-matched too. Cheap: the grep
  -- output is already small.
  local matched = {}
  for _, e in ipairs(entries) do
    local ok = true
    for _, f in ipairs(frags) do
      if not string.find(e.nameLower, f, 1, true) then
        ok = false
        break
      end
    end
    if ok then
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
      e.exact, e.depth = rankEntry(e.nameLower, frags)
    end
    table.sort(matched, function(a, b)
      if a.exact ~= b.exact then
        return a.exact > b.exact
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

-- ── host hooks ────────────────────────────────────────────────────────────
function onQuery(text)
  lastQuery = text
  local folder, search = splitPath(trim(text))
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
  if id == nil or id == "" or id == "loading" then
    return
  end

  local kind, rest = id:match("^(%a+):(.*)$")
  if kind == "nav" then
    launcher.setQuery(rest .. "/")
  elseif kind == "back" then
    launcher.setQuery(rest ~= "" and (rest .. "/") or " ")
  elseif kind == "entry" then
    -- pass show / copy / type land in a later port step.
    noctalia.notify(tr("command.description"), tr("detail.pending", { entry = rest }))
  end
end

-- Warm the store-root listing at load so the first ">pass" renders instantly;
-- rendering it then prefetches its sub-folders, and so on down the tree.
prefetchBrowse(storeDir(), "")
