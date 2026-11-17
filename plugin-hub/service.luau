--!nonstrict
-- Plugin Hub service: every plugin you use in one list, with what each can do. A plugin's
-- panels come from its manifest, and its commands from the `noctalia msg` lines its README
-- shows. Noctalia's own panels are a fixed list, and the owner adds commands of their own.
-- Each of these is an action: something `noctalia msg` runs, which the panel and the
-- launcher run and which can get a key.
--
-- The plugins are the enabled ones, read from `noctalia msg plugins list`, and the ones the
-- hub saw enabled before, so a plugin switched off here can be switched on again. Manifests
-- and READMEs are read from Noctalia's copy of each plugin, which it keeps while the plugin
-- is off and deletes when the plugin is removed; a removed plugin is forgotten.
--
-- Keys, own commands and the plugins seen are kept in hub.json in the data folder.
--
-- A plugin's settings are read when its settings page opens, and saved one change at a time.
--
-- Publishes "hub.model" and "hub.settings", and takes commands on "hub.command".

local Binds = require("./lib/binds.luau")
local Settings = require("./lib/settings.luau")
local Toml = require("./lib/toml.luau")

local SYNC_MS = 30000

-- Noctalia's own panels, as "noctalia msg" arguments and a translation key for each name.
local NOCTALIA = {
  { command = "panel-toggle launcher", name = "noctalia.launcher" },
  { command = "panel-toggle launcher /emo", name = "noctalia.emoji" },
  { command = "panel-toggle launcher /pan", name = "noctalia.panels" },
  { command = "panel-toggle control-center", name = "noctalia.control_center" },
  { command = "panel-toggle control-center audio", name = "noctalia.audio" },
  { command = "panel-toggle control-center network", name = "noctalia.network" },
  { command = "panel-toggle control-center bluetooth", name = "noctalia.bluetooth" },
  { command = "panel-toggle control-center media", name = "noctalia.media" },
  { command = "panel-toggle control-center notifications", name = "noctalia.notifications" },
  { command = "panel-toggle control-center calendar", name = "noctalia.calendar" },
  { command = "panel-toggle control-center weather", name = "noctalia.weather" },
  { command = "panel-toggle control-center system", name = "noctalia.system" },
  { command = "panel-toggle control-center power", name = "noctalia.power" },
  { command = "panel-toggle control-center screen-time", name = "noctalia.screen_time" },
  { command = "panel-toggle wallpaper", name = "noctalia.wallpaper" },
  { command = "panel-toggle clipboard", name = "noctalia.clipboard" },
  { command = "panel-toggle session", name = "noctalia.session" },
  { command = "settings-toggle", name = "noctalia.settings" },
  { command = "notification-dnd-toggle", name = "noctalia.dnd" },
}

-- A command that runs without a shell: words of letters, digits and - _ . / : + only, so
-- nothing from a README can run more than noctalia msg.
local function safe(command)
  return type(command) == "string" and command:match("^[%w][%w%-_%./:%+ ]*$") ~= nil
end

local dataDir = noctalia.pluginDataDir() or ""
local dataFile = dataDir .. "/hub.json"

-- { keys = { [command] = "SUPER + K" }, custom = { command }, known = { [id] = source } }
local saved = { keys = {}, custom = {}, known = {} }
local loaded = false
local plugins = {} -- { id, source, enabled, name, panels = { panel id }, commands = { command }, settings }
local status = {}
local lastSyncMs = 0
local discovering = false

local function save()
  noctalia.mkdirAll(dataDir)
  noctalia.writeFile(dataFile, noctalia.json.encode(saved) or "")
end

local function publish()
  local groups = {}
  local noctaliaActions = {}
  for _, item in ipairs(NOCTALIA) do
    table.insert(noctaliaActions, { command = item.command, title = noctalia.tr(item.name), kind = "panel" })
  end
  table.insert(groups, { id = "noctalia", title = noctalia.tr("group.noctalia"), actions = noctaliaActions })
  for _, plugin in ipairs(plugins) do
    local actions = {}
    for _, panel in ipairs(plugin.panels) do
      table.insert(actions, {
        command = `panel-toggle {plugin.id}:{panel}`,
        title = #plugin.panels > 1 and noctalia.tr("action.panel_named", { name = panel }) or noctalia.tr("action.panel"),
        kind = "panel",
      })
    end
    local panelCommands = {}
    for _, action in ipairs(actions) do
      panelCommands[action.command] = true
    end
    for _, item in ipairs(plugin.commands) do
      if not panelCommands[item.command] then
        -- "plugin <id>:<entry> all next" reads as "next", or as the README's note on it.
        local title = item.note ~= "" and item.note or item.command:match("^plugin %S+ %S+ (.+)$") or item.command
        table.insert(actions, { command = item.command, title = title, kind = "command" })
      end
    end
    table.insert(groups, {
      id = plugin.id,
      title = plugin.name or plugin.id,
      plugin = true,
      enabled = plugin.enabled,
      settings = plugin.settings,
      actions = actions,
    })
  end
  local custom = {}
  for _, command in ipairs(saved.custom) do
    table.insert(custom, { command = command, title = command, kind = "command", custom = true })
  end
  table.insert(groups, { id = "custom", title = noctalia.tr("group.custom"), actions = custom, custom = true })
  noctalia.state.set("hub.model", {
    ready = loaded,
    groups = groups,
    keys = saved.keys,
    status = status,
    canBind = Binds.available(),
  })
end

local function applyKeys()
  local wanted = {}
  for command, key in pairs(saved.keys) do
    wanted[key] = command
  end
  Binds.set(wanted)
end

Binds.watch(function(value)
  status = value
  publish()
end)

-- What one plugin is called, its panels, whether it has settings, and the `noctalia msg`
-- lines of its README, from Noctalia's copy of it.
local function readPlugin(plugin, manifest, readme)
  for _, section in ipairs(Toml.manifest(manifest, { name = true, id = true })) do
    if section.header == nil and type(section.values.name) == "string" then
      plugin.name = section.values.name
    elseif section.header == "panel" and type(section.values.id) == "string" then
      table.insert(plugin.panels, section.values.id)
    elseif section.header and (section.header == "setting" or section.header:match("%.setting$")) then
      plugin.settings = true
    end
  end
  for line in (readme or ""):gmatch("[^\n]+") do
    local rest = line:match("^%s*noctalia msg (.+)$")
    if rest then
      -- A note after "#" names the command.
      local command, note = rest:match("^(.-)%s+#%s*(.*)$")
      command = noctalia.string.trim(command or rest)
      if safe(command) and not plugin.seen[command] then
        plugin.seen[command] = true
        table.insert(plugin.commands, { command = command, note = noctalia.string.trim(note or "") })
      end
    end
  end
end

-- The plugins whose files are still to read, and how far the reading is. One plugin is read
-- per update tick, quickly while there are any: reading them all in one callback can go over
-- its CPU time.
local pending = nil
local reading = false
local FAST_TICK_MS, TICK_MS = 50, 1000

-- Reads each plugin's manifest and README. A plugin that is off and whose copy is gone was
-- removed in Noctalia, so the hub forgets it.
local function discover(list)
  local kept, forgot = {}, false
  for _, plugin in ipairs(list) do
    if plugin.enabled or noctalia.fileExists(Settings.pluginDir(plugin.source, plugin.id) .. "/plugin.toml") then
      table.insert(kept, plugin)
    else
      saved.known[plugin.id] = nil
      forgot = true
    end
  end
  if forgot then
    save()
  end
  pending = { list = kept, next = 1 }
  noctalia.setUpdateInterval(FAST_TICK_MS)
end

-- Reads the next plugin's files, or publishes the list once all are read.
local function readNext()
  if pending == nil or reading then
    return
  end
  local plugin = pending.list[pending.next]
  if plugin == nil then
    local list = pending.list
    pending = nil
    discovering = false
    noctalia.setUpdateInterval(TICK_MS)
    table.sort(list, function(a, b)
      return (a.name or a.id):lower() < (b.name or b.id):lower()
    end)
    plugins = list
    publish()
    return
  end
  pending.next += 1
  reading = true
  local dir = Settings.pluginDir(plugin.source, plugin.id)
  noctalia.readFileAsync(dir .. "/plugin.toml", function(manifest)
    noctalia.readFileAsync(dir .. "/README.md", function(readme)
      reading = false
      if manifest then
        readPlugin(plugin, manifest, readme)
      end
    end)
  end)
end

-- The enabled plugins and the ones seen before, then what each can do.
local function refresh()
  if discovering then
    return
  end
  discovering = true
  noctalia.runAsync({ "noctalia", "msg", "plugins", "list" }, function(result)
    local list, changed = {}, false
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      local id, source, state = line:match("^(%S+) %[([^%]]+)%] %S+ (%a+)")
      if id and source ~= "dev" and (state == "enabled" or saved.known[id]) then
        if state == "enabled" and saved.known[id] ~= source then
          saved.known[id] = source
          changed = true
        end
        table.insert(list, { id = id, source = source, enabled = state == "enabled", panels = {}, commands = {}, seen = {} })
      end
    end
    if changed then
      save()
    end
    discover(list)
  end, 10000)
end

-- The open settings page: { id, sections, errors = { ["<section>/<key>"] = text } }.
local page = nil

local function publishSettings()
  noctalia.state.set("hub.settings", page and {
    id = page.id,
    loading = page.loading,
    error = page.error,
    sections = page.sections,
    errors = page.errors,
    n = noctalia.nowMs(),
  } or nil)
end

local function findPlugin(id)
  for _, plugin in ipairs(plugins) do
    if plugin.id == id then
      return plugin
    end
  end
  return nil
end

local function loadSettings(id)
  local plugin = findPlugin(id)
  if plugin == nil then
    return
  end
  -- Opening the same page again keeps what it shows while it reads again.
  local same = page ~= nil and page.id == id
  page = {
    id = id,
    loading = not same or page.loading,
    sections = same and page.sections or {},
    errors = same and page.errors or {},
  }
  publishSettings()
  Settings.load(plugin, function(sections, err)
    if page == nil or page.id ~= id then
      return
    end
    page.loading = false
    page.sections = sections or {}
    page.error = err
    publishSettings()
  end)
end

-- <text>, as the panel sends it, as a value of <field>; or nil and why not.
local function valueFor(field, text)
  text = tostring(text or "")
  local kind = field.type
  if kind == "bool" then
    return text == "true"
  elseif kind == "int" or kind == "double" then
    local number = tonumber(noctalia.string.trim(text))
    local inRange = number ~= nil
      and (kind == "double" or number == math.floor(number))
      and (field.min == nil or number >= field.min)
      and (field.max == nil or number <= field.max)
    if not inRange then
      if field.min ~= nil and field.max ~= nil then
        return nil, noctalia.tr("page.range", { min = field.min, max = field.max })
      end
      return nil, noctalia.tr(kind == "int" and "page.whole_number" or "page.number")
    end
    return number
  elseif kind == "select" then
    for _, option in ipairs(field.options) do
      if option.value == text then
        return text
      end
    end
    return nil, noctalia.tr("page.not_an_option")
  elseif kind == "string" or kind == "file" or kind == "folder" or kind == "glyph" or kind == "color" then
    return text
  end
  return nil, noctalia.tr("page.not_here")
end

local function saveSetting(command)
  local section = page and page.id == command.id and page.sections[tonumber(command.section) or 0]
  if not section then
    return
  end
  local field
  for _, item in ipairs(section.fields) do
    if item.key == command.key then
      field = item
    end
  end
  if field == nil or field.secret then
    return
  end
  local where = `{command.section}/{field.key}`
  local value, problem = valueFor(field, command.value)
  if value == nil then
    page.errors[where] = problem
    publishSettings()
    return
  end
  page.errors[where] = nil
  local before = field.value
  field.value = value
  publishSettings()
  Settings.save(page.id, section, field.key, value, field.type, function(err)
    if err then
      field.value = before
      page.errors[where] = err
    end
    publishSettings()
  end)
end

local function run(command)
  if not safe(command) then
    return
  end
  local argv = { "noctalia", "msg" }
  for word in command:gmatch("%S+") do
    table.insert(argv, word)
  end
  noctalia.runAsync(argv)
end

local function setKey(command, key)
  key = noctalia.string.trim(key or "")
  if not safe(command) then
    return
  end
  if key == "" then
    saved.keys[command] = nil
  else
    -- One key does one thing: it leaves any other action.
    for other, otherKey in pairs(saved.keys) do
      if otherKey == key then
        saved.keys[other] = nil
      end
    end
    saved.keys[command] = key
  end
  save()
  applyKeys()
  publish()
end

noctalia.state.watch("hub.command", function(command)
  if type(command) ~= "table" or not loaded then
    return
  end
  if command.action == "run" then
    run(command.command)
  elseif command.action == "set_key" then
    setKey(command.command, command.key)
  elseif command.action == "add_custom" then
    local text = noctalia.string.trim(command.command or ""):gsub("^noctalia msg ", "")
    if safe(text) and not table.find(saved.custom, text) then
      table.insert(saved.custom, text)
      save()
      publish()
    end
  elseif command.action == "remove_custom" then
    local at = table.find(saved.custom, command.command)
    if at then
      table.remove(saved.custom, at)
      saved.keys[command.command] = nil
      save()
      applyKeys()
      publish()
    end
  elseif command.action == "enable" and type(command.id) == "string" then
    noctalia.runAsync({ "noctalia", "msg", "plugins", command.on and "enable" or "disable", command.id }, function()
      refresh()
    end)
  elseif command.action == "forget" and type(command.id) == "string" then
    saved.known[command.id] = nil
    save()
    refresh()
  elseif command.action == "settings" and type(command.id) == "string" then
    noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", command.id })
  elseif command.action == "load_settings" and type(command.id) == "string" then
    loadSettings(command.id)
  elseif command.action == "close_settings" then
    page = nil
    publishSettings()
  elseif command.action == "save_setting" and type(command.key) == "string" then
    saveSetting(command)
  elseif command.action == "open_widget" and type(command.instance) == "string" then
    noctalia.runAsync({ "noctalia", "msg", "settings-open-widget", tostring(command.bar or ""), command.instance })
  elseif command.action == "open_desktop" then
    noctalia.runAsync({ "noctalia", "msg", command.lockscreen and "lockscreen-widgets-edit" or "desktop-widgets-edit" })
  elseif command.action == "refresh" then
    refresh()
  end
end)

-- noctalia msg plugin omerfuyar/plugin-hub:service all refresh
function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

-- A change to the settings shown, from the hub or from anywhere else.
function onConfigChanged()
  if page ~= nil and not page.loading then
    loadSettings(page.id)
  end
end

function update()
  readNext()
  if loaded and noctalia.nowMs() - lastSyncMs >= SYNC_MS then
    lastSyncMs = noctalia.nowMs()
    Binds.sync()
    refresh()
  end
end

function onExit()
  Binds.release()
end

noctalia.setUpdateInterval(TICK_MS)
noctalia.readFileAsync(dataFile, function(text)
  local value = text and noctalia.json.decode(text)
  if type(value) == "table" then
    saved.keys = type(value.keys) == "table" and value.keys or {}
    saved.custom = type(value.custom) == "table" and value.custom or {}
    saved.known = type(value.known) == "table" and value.known or {}
  end
  loaded = true
  lastSyncMs = noctalia.nowMs()
  applyKeys()
  refresh()
  publish()
end)
