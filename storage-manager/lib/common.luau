--!nonstrict
-- Shared by every entry: talking to helper/storagetool.py, and formatting.

local M = {}

M.PANEL = "shadowshard4080/storage-manager:manager"

function M.helper()
  return (noctalia.pluginDir() or ".") .. "/helper/storagetool.py"
end

function M.cacheDir()
  local base = noctalia.getenv("XDG_CACHE_HOME")
  if base == nil or base == "" then
    base = noctalia.expandPath("~/.cache")
  end
  return base .. "/noctalia-storage-manager"
end

-- same naming the helper uses to find a whole-disk scan
function M.scanFile(mount)
  local tail
  if mount == "/" then
    tail = "-root"
  else
    tail = string.gsub(mount, "[^A-Za-z0-9]+", "-")
  end
  return M.cacheDir() .. "/scan" .. tail .. ".json"
end

function M.detailFile(path)
  local tail = string.gsub(path, "[^A-Za-z0-9]+", "-")
  if #tail > 120 then
    tail = string.sub(tail, -120)
  end
  return M.cacheDir() .. "/detail" .. tail .. ".json"
end

function M.quote(s)
  return "'" .. (string.gsub(tostring(s), "'", "'\\''")) .. "'"
end

-- A quick question: the helper answers with one JSON line within a minute.
function M.ask(args, cb)
  local argv = { "python3", M.helper() }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  return noctalia.runAsync(argv, function(res)
    local data = nil
    if res.exitCode == 0 and res.stdout ~= nil and res.stdout ~= "" then
      data = noctalia.json.decode(res.stdout)
    end
    cb(data, res)
  end, 60000)
end

-- A long job (scans, cleaning, anything that may ask for a password). Runs
-- as a stream so there is no time limit. Progress lines go to onLine, the
-- helper's JSON answer (if any) and exit code to onDone.
function M.job(args, onLine, onDone, niceLevel)
  local parts = {}
  for _, a in ipairs(args) do
    table.insert(parts, M.quote(a))
  end
  local prefix = niceLevel and ("nice -n " .. tostring(niceLevel) .. " ") or ""
  local cmd = prefix .. "python3 " .. M.quote(M.helper()) .. " " .. table.concat(parts, " ")
    .. " 2>/dev/null; echo \"x $?\""
  local answer = nil
  return noctalia.runStream(cmd, function(line)
    local c = string.sub(line, 1, 1)
    if c == "{" then
      answer = line
    elseif string.sub(line, 1, 2) == "x " then
      local data = answer and noctalia.json.decode(answer) or nil
      onDone(data, tonumber(string.sub(line, 3)) or 1)
    elseif onLine then
      onLine(line)
    end
  end)
end

-- Opens a folder in the user's file manager. The helper picks it: the
-- default folder app unless that is a terminal or missing, then whichever
-- file manager answers on D-Bus, then any installed app that opens folders.
function M.openFolder(path)
  local ok = M.ask({ "open-folder", path }, function(data)
    if not (data and data.ok) then
      noctalia.openPath(path)
    end
  end)
  if not ok then
    noctalia.openPath(path)
  end
end

function M.size(b)
  b = tonumber(b) or 0
  if b <= 0 then
    return "0 B"
  end
  local units = { "B", "KB", "MB", "GB", "TB", "PB" }
  local i = 1
  while b >= 1024 and i < #units do
    b /= 1024
    i += 1
  end
  if i == 1 or b >= 100 then
    return string.format("%d %s", math.floor(b + 0.5), units[i])
  end
  return string.format("%.1f %s", b, units[i])
end

function M.count(n)
  n = math.floor(tonumber(n) or 0)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if string.sub(out, 1, 1) == "," then
    out = string.sub(out, 2)
  end
  return out
end

function M.ago(t)
  t = tonumber(t) or 0
  if t <= 0 then
    return ""
  end
  local d = noctalia.nowMs() / 1000 - t
  if d < 90 then
    return noctalia.tr("time.just_now")
  elseif d < 3600 then
    return noctalia.tr("time.minutes", { n = math.floor(d / 60) })
  elseif d < 7200 then
    return noctalia.tr("time.hour")
  elseif d < 86400 then
    return noctalia.tr("time.hours", { n = math.floor(d / 3600) })
  elseif d < 172800 then
    return noctalia.tr("time.yesterday")
  elseif d < 14 * 86400 then
    return noctalia.tr("time.days", { n = math.floor(d / 86400) })
  elseif d < 60 * 86400 then
    return noctalia.tr("time.weeks", { n = math.floor(d / 604800) })
  elseif d < 730 * 86400 then
    return noctalia.tr("time.months", { n = math.floor(d / 2592000) })
  end
  return noctalia.tr("time.years", { n = math.floor(d / 31536000) })
end

function M.freePercent(v)
  local total = (tonumber(v.used) or 0) + (tonumber(v.avail) or 0)
  if total <= 0 then
    return 100
  end
  return (tonumber(v.avail) or 0) / total * 100
end

-- where the space goes, in the helper's order
M.CATS = { "system", "apps", "pkgcache", "caches", "trash", "video", "image", "audio", "docs", "archive", "code", "other" }
M.CAT_COLOR = {
  system = "#7c8591",
  apps = "#5c7cfa",
  pkgcache = "#9775fa",
  caches = "#da77f2",
  trash = "#ff6b6b",
  video = "#ff922b",
  image = "#fcc419",
  audio = "#20c997",
  docs = "#69db7c",
  archive = "#c9a27a",
  code = "#4dabf7",
  other = "#adb5bd",
}

-- what a file is, by the helper's kind index (0-based)
M.KIND_CAT = { [0] = "other", "video", "image", "audio", "docs", "archive", "code", "apps" }
M.KIND_GLYPH = { [0] = "file", "movie", "photo", "music", "file-text", "file-zip", "code", "apps" }

function M.kindColor(k)
  return M.CAT_COLOR[M.KIND_CAT[tonumber(k) or 0] or "other"]
end

function M.basename(p)
  return string.match(p, "([^/]+)/*$") or p
end

function M.dirname(p)
  local d = string.match(p, "^(.*)/[^/]+/*$")
  if d == nil or d == "" then
    return "/"
  end
  return d
end

return M
