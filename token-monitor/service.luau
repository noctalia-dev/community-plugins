local Service = require("./lib/service.luau")
local Model = require("./lib/model.luau")
local Credentials = require("./lib/credentials.luau")
local Pins = require("./lib/pins.luau")
local autoRefresh = true
local pollInterval = 60000
local deferred = {}

-- Separate large decode/normalization/cache phases into native VM calls.
-- The short timer only runs while work is queued; idle polling stays configured.
local function defer(callback)
  deferred[#deferred + 1] = callback
  noctalia.setUpdateInterval(16)
end

local pins = Pins.new({
  decode = noctalia.json.decode, encode = noctalia.json.encode,
  read = noctalia.readFileAsync, write = noctalia.writeFile,
  path = function()
    local directory = noctalia.pluginDataDir()
    return directory and (directory .. "/selection.json") or nil
  end,
  publish = function(value) noctalia.state.set("pinned_account", value) end,
})

local engine = Service.new({
  now = os.time,
  decode = noctalia.json.decode,
  encode = noctalia.json.encode,
  read = noctalia.readFileAsync,
  write = noctalia.writeFile,
  http = noctalia.http,
  getenv = noctalia.getenv, expandPath = noctalia.expandPath, listDir = noctalia.listDir, exists = noctalia.fileExists,
  defer = defer,
  reportProcessingError = function(kind, phase, category)
    noctalia.log("Token Monitor processing: " .. kind .. " " .. phase .. " " .. category)
  end,
  cachePath = function()
    local directory = noctalia.pluginDataDir()
    return directory and (directory .. "/snapshot.json") or nil
  end,
  publish = function(value) noctalia.state.set("dashboard", value) end,
})

local function configure()
  local interval = math.clamp(tonumber(noctalia.getConfig("refresh_interval_seconds")) or 60, 30, 3600)
  autoRefresh = noctalia.getConfig("auto_refresh") ~= false
  -- The host clamps zero to 16 ms, so disabling polling uses a dormant tick
  -- and an explicit guard instead of accidentally creating a fast timer.
  pollInterval = autoRefresh and interval * 1000 or 3600000
  noctalia.setUpdateInterval(#deferred > 0 and 16 or pollInterval)
  local url = noctalia.getConfig("hub_url") or "http://127.0.0.1:17321"
  local credentialFile = noctalia.getConfig("credentials_file") or ""
  local autoDiscover = noctalia.getConfig("auto_discover_credentials") ~= false
  pins.configure(Credentials.scope(Model.origin(url), credentialFile, autoDiscover))
  engine.configure({
    url = url, credentialFile = credentialFile, autoDiscover = autoDiscover,
  })
end

function update()
  if #deferred > 0 then
    local callback = table.remove(deferred, 1)
    callback()
    noctalia.setUpdateInterval(#deferred > 0 and 16 or pollInterval)
    return
  end
  if autoRefresh then engine.refresh() end
end
function onConfigChanged() configure() end
function onIpc(event, _payload)
  if event == "refresh" then engine.refresh()
  elseif event == "test-connection" then engine.testConnection() end
end

noctalia.state.watch("refresh_requested", function() engine.refresh() end)
noctalia.state.watch("connection_test_requested", function() engine.testConnection() end)
noctalia.state.watch("pin_requested", function(request)
  if type(request) ~= "table" or request.scope ~= pins.get().scope then return end
  local dashboard = noctalia.state.get("dashboard") or {}
  pins.select(request.key, dashboard.providers or {})
end)
configure()
