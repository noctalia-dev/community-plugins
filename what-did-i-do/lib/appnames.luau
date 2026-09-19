-- lib/appnames.luau — application display-name resolution.
--
-- app_id vs display_name: sessions store the stable technical identifier
-- (Hyprland window class / initialClass); the UI shows a human-readable
-- label. The identifier is never rewritten or dropped — only the UI label is
-- resolved from it, so grouping/dedup/diagnostics keep working.
--
-- Resolution order (cheap -> expensive, all local, zero network):
--   1. a provider/metadata appName that is already human-readable (has
--      uppercase or differs from the id) and is not itself package-like
--   2. the local .desktop database (single lazy scan, per-id cached;
--      resolver host adapter only — the pure core stays testable)
--   3. safe normalization of the identifier itself
--       "@codebuff/freebuff-desktop" -> "Freebuff"
--       "brave-browser"              -> "Brave"
--       "org.telegram.desktop"       -> "Telegram"
--   4. fallback: the identifier (or "?") — the label is never empty

local M = {}

-- Reverse-DNS first labels ("org.telegram.desktop", "com.github.xyz", ...).
local REVERSE_DNS_PREFIX = {
  org = true, com = true, net = true, io = true, dev = true, de = true,
  fr = true, it = true, jp = true, uk = true, br = true, cz = true,
  hu = true, pl = true, ru = true, se = true, tr = true,
  ["in"] = true, cn = true, kr = true, es = true, pt = true, nl = true,
}

-- Trailing dot-segments that name a form factor, not an application.
local GENERIC_LAST = {
  desktop = true, app = true, bin = true, client = true,
}

-- Trailing hyphen/underscore words that qualify a product name.
local QUALIFIER_WORDS = {
  browser = true, desktop = true, app = true, oss = true, bin = true,
  esr = true, client = true, nightly = true, beta = true, dev = true,
}

function M.isPackageLike(id)
  if type(id) ~= "string" or id == "" then
    return false
  end
  if id:find("/", 1, true) then
    return true
  end
  local first = id:match("^[^.]+")
  if first and REVERSE_DNS_PREFIX[first:lower()] and id:find(".", 1, true) then
    return true
  end
  return false
end

-- A metadata name is trusted when it is non-empty, not package-like, and
-- says something the id does not (differs case-insensitively). This keeps
-- real metadata ("Telegram", "Freebuff") while routing pure class echoes
-- ("brave-browser", "dev.noctalia.Noctalia") into derivation.
function M.isHumanReadableName(name)
  if type(name) ~= "string" then
    return false
  end
  local trimmed = name:match("^%s*(.-)%s*$")
  if trimmed == "" or M.isPackageLike(trimmed) then
    return false
  end
  return true
end

local function capWord(word)
  if word:find("%u") or word:find("^%d+$") then
    return word
  end
  return word:sub(1, 1):upper() .. word:sub(2)
end

-- deriveDisplayName(id) -> display string, or nil when nothing sensible
-- can be derived (caller falls back to the raw id).
function M.deriveDisplayName(id)
  if type(id) ~= "string" then
    return nil
  end
  local s = id:match("^%s*(.-)%s*$")
  -- Path-ish ids: keep the leaf ("@codebuff/freebuff-desktop" -> "freebuff-desktop").
  local leaf = s:match("^.*/(.+)$")
  if leaf then
    s = leaf
  end
  s = s:gsub("^@", "")

  local segs = {}
  for seg in s:gmatch("[^.]+") do
    segs[#segs + 1] = seg
  end
  if #segs == 0 then
    return nil
  end
  -- Reverse-DNS: strip "org." / "com." / ... prefixes.
  while #segs > 1 and REVERSE_DNS_PREFIX[segs[1]:lower()] do
    table.remove(segs, 1)
  end
  -- "org.telegram.desktop" -> "telegram"; "dev.noctalia.Noctalia" stays.
  if #segs > 1 and GENERIC_LAST[segs[#segs]:lower()] then
    table.remove(segs)
  end
  -- With several segments left, the leaf carries the product name.
  local candidate = segs[#segs]

  -- Split the candidate on separators and drop a trailing qualifier.
  local words = {}
  for word in candidate:gmatch("[^%-%_%.%s]+") do
    words[#words + 1] = word
  end
  while #words > 1 and QUALIFIER_WORDS[words[#words]:lower()] do
    table.remove(words)
  end
  if #words == 0 then
    return nil
  end

  local out = {}
  for i, word in ipairs(words) do
    out[i] = capWord(word)
    if i >= 3 then
      break -- never assemble a sentence from one id
    end
  end
  return table.concat(out, " ")
end

-- resolveDisplayName(appId, appName) -> display string; never empty.
function M.resolveDisplayName(appId, appName)
  local id = (type(appId) == "string" and appId ~= "") and appId
    or (type(appName) == "string" and appName or nil)
  if id == nil then
    return "?"
  end
  local trusted = appName
    and M.isHumanReadableName(appName)
    and appName:lower() ~= id:lower()
  if trusted then
    local trimmed = appName:match("^%s*(.-)%s*$")
    return trimmed
  end
  return M.deriveDisplayName(id) or id
end

-- ── host adapter: cached .desktop lookup ─────────────────────────────────────
--
-- newResolver({ readFile, listDir, getenv }) wraps the pure core with a
-- one-shot scan of the local applications directories. Host functions mirror
-- the noctalia.* signatures (readFile -> (contents?, err?), listDir ->
-- (names?, err?), getenv -> string?). Failures are absorbed: the resolver
-- always returns a usable label.

local XDG_DATA_HOME_DEFAULT = "~/.local/share"
local XDG_DATA_DIRS_DEFAULT = "/usr/local/share:/usr/share"

function M.newResolver(host)
  host = host or {}
  local cache = {} -- id -> display string (positive and negative results)
  local stems = nil -- lowercase stem -> desktop filename
  local readFailed = {} -- desktop-file path -> true (unreadable, don't retry)

  local function splitDirs(value, fallback)
    local out = {}
    for part in (value or fallback):gmatch("[^:]+") do
      out[#out + 1] = part
    end
    return out
  end

  local function scan()
    if stems ~= nil then
      return
    end
    stems = {}
    local dataHome = host.getenv and host.getenv("XDG_DATA_HOME") or nil
    if dataHome == nil or dataHome == "" then
      local home = host.getenv and host.getenv("HOME") or nil
      dataHome = home and (home .. "/.local/share") or XDG_DATA_HOME_DEFAULT
    end
    local dirs = splitDirs(host.getenv and host.getenv("XDG_DATA_DIRS") or nil, XDG_DATA_DIRS_DEFAULT)
    for i, dir in ipairs(dirs) do
      dirs[i] = dir .. "/applications"
    end
    table.insert(dirs, dataHome .. "/applications")
    table.insert(dirs, dataHome .. "/flatpak/exports/share/applications")
    table.insert(dirs, "/var/lib/flatpak/exports/share/applications")
    for _, dir in ipairs(dirs) do
      local names = host.listDir and host.listDir(dir) or nil
      if type(names) == "table" then
        for _, name in ipairs(names) do
          local base = name:match("^.*/(.+)$") or name
          local stem = base:match("^(.-)%.desktop$")
          if stem and stems[stem:lower()] == nil then
            -- Store the full path so the read goes to the same directory
            -- the stem was found in (user, flatpak and system exports differ).
            stems[stem:lower()] = dir .. "/" .. base
          end
        end
      end
    end
  end

  local function readDesktopName(path)
    if readFailed[path] then
      return nil
    end
    local contents = host.readFile and host.readFile(path) or nil
    if type(contents) ~= "string" then
      readFailed[path] = true
      return nil
    end
    for line in contents:gmatch("[^\r\n]+") do
      -- Plain "Name=" only: localized variants ("Name[de]=") and keys inside
      -- [Desktop Action] sections are ignored by the exact prefix match.
      local value = line:match("^Name=(.+)$")
      if value and value ~= "" then
        return value
      end
    end
    readFailed[filename] = true
    return nil
  end

  local function lookupDesktopName(id)
    scan()
    if next(stems) == nil then
      return nil
    end
    local candidates = { id }
    local leaf = id:match("^.*/(.+)$")
    if leaf then
      candidates[#candidates + 1] = leaf
    end
    local lastSeg = id:match("%.([^%.]+)$")
    if lastSeg then
      candidates[#candidates + 1] = lastSeg
    end
    for _, candidate in ipairs(candidates) do
      local path = stems[candidate:lower()]
      if path then
        local name = readDesktopName(path)
        if name then
          return name
        end
      end
    end
    return nil
  end

  return {
    resolve = function(appId, appName)
      local id = (type(appId) == "string" and appId ~= "") and appId
        or (type(appName) == "string" and appName or nil)
      if id == nil then
        return "?"
      end
      if cache[id] then
        return cache[id]
      end
      local display = M.resolveDisplayName(id, appName)
      if display == id or display == M.deriveDisplayName(id) then
        -- Pure derivation did not beat the id by much; try local metadata.
        local fromDesktop = lookupDesktopName(id)
        if fromDesktop and M.isHumanReadableName(fromDesktop) then
          display = fromDesktop
        end
      end
      if type(display) ~= "string" or display == "" then
        display = id
      end
      cache[id] = display
      return display
    end,
  }
end

return M
