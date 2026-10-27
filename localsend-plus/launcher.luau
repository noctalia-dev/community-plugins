--!nonstrict
-- Launcher provider: "LocalSend" opens the panel (also from the global
-- search); "/ls" lists send actions for every nearby online device.

local lib = require("./lib.luau")

local ACTIONS = {
  { kind = "files", glyph = "file-upload", key = "launcher.send_files" },
  { kind = "folder", glyph = "folder-up", key = "launcher.send_folder" },
  { kind = "clipboard", glyph = "clipboard", key = "launcher.send_clipboard" },
}

local VISIBILITY_ACTIONS = {
  { mode = "everyone" },
  { mode = "favorites" },
  { mode = "hidden" },
  { mode = "everyone", temp = true },
}

local function tr(key, args)
  return noctalia.tr(key, args)
end

-- Scores the query the way Noctalia scores an application named "LocalSend"
-- (app_provider.cpp: name match = 3000 + fuzzy * 5, +500 when the name starts
-- with the query). That ranks it among the apps and above web search (2048)
-- and the other fixed-score providers. nil when the query does not match.
local function appScore(query)
  local q = query:lower():gsub("%s+", "")
  if #q < 2 then return nil end
  local s = noctalia.fuzzyScore(q, "localsend")
  if s == nil then return nil end
  s = 3000 + s * 5
  if ("localsend"):sub(1, #q) == q then s = s + 500 end
  return s
end

-- Empty queries list everything; otherwise rank with the native fuzzy matcher.
local function score(query, text)
  if query == "" then return 0 end
  return noctalia.fuzzyScore(query, text)
end

-- Online devices, favorites first.
local function devices()
  local ls = noctalia.state.get("ls") or {}
  local list = {}
  for _, entry in ipairs(lib.sortedDevices(ls.devices)) do
    local d = entry.device
    if d.online and d.address ~= nil then table.insert(list, d) end
  end
  return list
end

function onQuery(text)
  local q = lib.trim(text)
  local named = appScore(q)
  local results = {}

  local s = named or score(q, "LocalSend " .. tr("launcher.open"))
  if s ~= nil then
    table.insert(
      results,
      { id = "open", title = "LocalSend", subtitle = tr("launcher.open"), glyph = "send", score = s + 1 }
    )
  end

  -- Device actions follow the "open" row when the query names LocalSend.
  local rank = 0
  for _, d in ipairs(devices()) do
    for _, a in ipairs(ACTIONS) do
      local title = tr(a.key, { name = d.alias })
      rank = rank + 1
      local ds = named and named - rank * 0.01 or score(q, title .. " localsend")
      if ds ~= nil then
        table.insert(results, {
          id = a.kind .. ":" .. d.fingerprint,
          title = title,
          subtitle = "LocalSend · " .. (d.address.host or ""),
          glyph = a.glyph,
          score = ds,
        })
      end
    end
  end

  -- Visibility switches, after the device actions. The extra words let
  -- "ukryj", "hide" or "widoczny" find them too.
  local vis = (noctalia.state.get("ls") or {}).vis or {}
  local temp = (vis.tempUntil or 0) > 0
  for _, v in ipairs(VISIBILITY_ACTIONS) do
    local title = v.temp and tr("visibility.temp") or tr("launcher.visibility", { mode = tr("visibility." .. v.mode) })
    local current = v.temp and temp or (not v.temp and not temp and vis.base == v.mode)
    rank = rank + 1
    local vs = named and named - rank * 0.01 or score(q, title .. " localsend " .. tr("launcher.visibility_words"))
    if vs ~= nil then
      table.insert(results, {
        id = "vis:" .. (v.temp and "temp" or v.mode),
        title = title,
        subtitle = current and tr("launcher.current") or "LocalSend",
        glyph = v.temp and "clock" or lib.visibilityGlyph(v.mode),
        score = vs,
      })
    end
  end

  launcher.setResults(text, results)
end

function onActivate(id)
  if id == "open" then
    lib.openPanel()
    return
  end
  local kind, fingerprint = id:match("^(%a+):(.+)$")
  if kind == nil then return end
  if kind == "vis" then
    if fingerprint == "temp" then
      lib.requestVisibility("everyone", true)
    elseif lib.VISIBILITY[fingerprint] then
      lib.requestVisibility(fingerprint, false)
    end
    return
  end
  for _, d in ipairs(devices()) do
    if d.fingerprint == fingerprint then
      -- The clipboard goes out only after the panel previewed it.
      if kind == "clipboard" then
        lib.askClipboard(d)
      else
        lib.request(kind, d)
      end
      return
    end
  end
  lib.openPanel() -- the device went away; show the current list
end
