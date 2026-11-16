-- dropkitty launcher provider: `/dk` toggles the drop-down, `/dk <command>` shows it and runs
-- the command at a new shell prompt through the helper (bin/dropkitty run).

local GLYPH = "terminal-2"
local RUN_TIMEOUT_MS = 15000 -- cold start: up to 5 s for the lock, 3 s for kitty, 3 s for the prompt

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function helper()
  local dir = noctalia.pluginDir and noctalia.pluginDir()
  return dir and (dir .. "/bin/dropkitty") or nil
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function failed(message)
  noctalia.notifyError(tr("widget.title"), message or tr("widget.launch_failed"))
end

local function report(result)
  if type(result) ~= "table" or result.exitCode == 0 then
    return
  end
  local msg = result.timedOut and "" or tostring(result.stderr or ""):gsub("%s+$", "")
  failed(msg ~= "" and msg or nil)
end

local function call(argv)
  local bin = helper()
  if not bin then
    failed()
    return
  end
  table.insert(argv, 1, bin)
  if not noctalia.runAsync(argv, report, RUN_TIMEOUT_MS) then
    failed()
  end
end

function onQuery(query)
  local text = trim(query)
  if text == "" then
    launcher.setResults(query, { { id = "toggle", title = tr("launcher.toggle"), subtitle = tr("launcher.hint"), glyph = GLYPH } })
  else
    launcher.setResults(query, { { id = "run:" .. text, title = tr("launcher.run"), subtitle = text, glyph = GLYPH } })
  end
end

function onActivate(id)
  if id == "toggle" then
    call({ "toggle" })
  elseif id:sub(1, 4) == "run:" then
    call({ "run", id:sub(5) })
  end
end
