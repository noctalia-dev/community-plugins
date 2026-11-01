--!nonstrict
-- Command Code usage meters.
--
-- Two data sources:
--  1. `cc_usage.py` (local transcripts) — always available, approximated.
--  2. An optional `usage_command` that prints the same JSON shape (title,
--     description, month_percent, five_hour_percent, weekly_percent,
--     renew_in_days, five_hour_reset, weekly_reset). When set, it is invoked
--     every `usage_interval_minutes` and its fresh result wins. Point this at a
--     headless usage command once one exists (CommandCodeAI/command-code#1093).

noctalia.setUpdateInterval(60000)

local state = {
  title = "Command Code",
  description = "carregando…",
}

local server = nil
local cachePath = nil

local function render()
  desktopWidget.render(ui.column({
    gap = 2,
    padding = 10,
    fill = "surface/0.55",
    radius = 12,
    align = "start",
  }, {
    ui.label({
      text = state.title,
      fontSize = 20,
      fontWeight = "bold",
      color = "primary",
    }),
    ui.label({
      text = state.description,
      fontSize = 12,
      color = "on_surface/0.8",
    }),
  }))
end

local function apply(data)
  if type(data) ~= "table" then
    return
  end
  if type(data.title) == "string" and data.title ~= "" then
    state.title = data.title
  end
  if type(data.description) == "string" and data.description ~= "" then
    state.description = data.description
  end
  render()
end

local function refreshInterval()
  return (tonumber(noctalia.getConfig("usage_interval_minutes")) or 60) * 60
end

local function isFresh()
  return server ~= nil and server.fetched_at ~= nil
      and os.time() - server.fetched_at < refreshInterval()
end

local function readCache()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return
  end
  cachePath = dir .. "/usage.json"
  local raw = noctalia.readFile(cachePath)
  if raw == nil then
    return
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if ok and type(data) == "table" and data.fetched_at ~= nil then
    server = data
  end
end

local function writeCache()
  if cachePath == nil or server == nil then
    return
  end
  local ok, encoded = pcall(noctalia.json.encode, server)
  if ok and encoded ~= nil then
    noctalia.writeFile(cachePath, encoded)
  end
end

local function fetchServer()
  local command = noctalia.getConfig("usage_command")
  if command == nil or command == "" or isFresh() then
    return
  end
  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 or result.stdout == "" then
      return
    end
    local ok, data = pcall(noctalia.json.decode, result.stdout)
    if not ok or type(data) ~= "table" then
      return
    end
    if data.title == nil and data.month_percent == nil then
      return
    end
    data.fetched_at = os.time()
    server = data
    writeCache()
    apply(server)
  end)
end

local function localEstimate()
  local script = noctalia.pluginDir() .. "/cc_usage.py"
  local plan = noctalia.getConfig("plan") or "GOAT"
  local mult5h = noctalia.getConfig("multiplier") or 2.5
  local mult7d = noctalia.getConfig("weekly_multiplier") or mult5h
  local multMonth = noctalia.getConfig("month_multiplier") or mult5h
  local billingDay = noctalia.getConfig("billing_day") or 28
  local command = string.format(
    "CC_USAGE_PLAN='%s' CC_USAGE_MULT_5H='%s' CC_USAGE_MULT_7D='%s' CC_USAGE_MULT_MONTH='%s' CC_USAGE_BILLING_DAY='%s' python3 '%s' --json",
    plan, tostring(mult5h), tostring(mult7d), tostring(multMonth),
    tostring(billingDay), script)
  noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 or result.stdout == "" then
      return
    end
    local ok, data = pcall(noctalia.json.decode, result.stdout)
    if not ok or type(data) ~= "table" then
      return
    end
    -- A fresh server reading is authoritative; only fill in when it is stale.
    if isFresh() then
      return
    end
    apply(data)
  end)
end

function update()
  fetchServer()
  localEstimate()
end

readCache()
if isFresh() then
  apply(server)
else
  render()
end
update()
