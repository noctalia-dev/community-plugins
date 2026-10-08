--!nonstrict
-- The three entries, against a fake host.
--
-- The model is tested on its own in shared_test.lua, where it needs nothing from
-- Noctalia. This file tests the wiring: that service.luau reads the key, asks the
-- three endpoints and publishes what came back; that the widget and the panel paint
-- that data with the real model and spawn nothing at all; and that a refresh is
-- asked for over the shared state channel rather than by running a program.
--
--   lua tests/plugin_test.lua

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN = here .. "/.."

local checks, failures = 0, {}
local function check(ok, what)
  checks = checks + 1
  if not ok then
    failures[#failures + 1] = what
  end
end
local function eq(got, want, what)
  check(got == want, string.format("%s: got %s, want %s", what, tostring(got), tostring(want)))
end

-- ── fixtures: raw API responses, in the shapes the API returns ──────────────

local DAY = 86400
local NOW = os.time()

local function quota(models)
  return { periodStart = os.date("%Y-%m-%d", NOW - 10 * DAY), models = models }
end

local QUOTA = quota({
  { model = "deepseek-v4-flash", tokensUsed = 2.4e9, cap = 3e9, periodEnd = NOW + 4 * DAY },
  { model = "glm5.3-flash", tokensUsed = 0, cap = 3e9, periodEnd = NOW + 4 * DAY },
})
local ME = { handle = "carlos-3", region = "EU", tier = "inference" }
local METRICS = { last24h = { totalTokens = 5e6 }, monthToDate = { totalTokens = 4e7 }, last30d = { totalTokens = 44e6 } }

-- ── a fake host ─────────────────────────────────────────────────────────────

-- The plugin's own translations, flattened to dotted keys the way the host looks
-- them up, so the assertions below can talk about the text a user actually sees.
local TRANSLATIONS = (function()
  local flat = {}
  local function walk(prefix, value)
    for key, entry in pairs(value) do
      local path = prefix == "" and key or (prefix .. "." .. key)
      if type(entry) == "table" then
        walk(path, entry)
      else
        flat[path] = entry
      end
    end
  end
  local contents = assert(io.open(PLUGIN .. "/translations/en.json", "r"), "translations/en.json")
  local text = contents:read("a")
  contents:close()
  -- JSON is nearly Lua: a quoted key before a colon is the only difference, so
  -- rewrite that into ["key"] = and leave every other colon alone (descriptions
  -- contain them).
  local luaText = text:gsub('"([%w_.%-]+)"%s*:', function(key)
    return '["' .. key .. '"]='
  end)
  local decoded = assert(load("return " .. luaText, "translations"))()
  walk("", decoded)
  return flat
end)()

local world, journal, env

local function reset(overrides)
  world = overrides or {}
  journal = { requests = {}, renders = {}, commands = {}, notifications = {}, state = {}, watchers = {}, logs = {} }
  local settings = {
    api_key = "~/.config/nan/api-key", interval = 300, panel_model = "worst",
    panel_model_id = "deepseek-v4-flash", panel_gauge = "bar", hide_unused = false,
    show_metrics = true, show_percentage = true, show_reset = true, show_model = true,
    show_icon = true, icon_style = "ghost", show_glyph = false, glyph = "chart-pie",
    show_tooltip = true, left_click = "panel",
  }
  for key, value in pairs(world.settings or {}) do
    settings[key] = value
  end

  local defaultBodies = { quota = QUOTA, me = ME, metrics = METRICS }
  local function bodies()
    return world.bodies or defaultBodies
  end
  local function node(kind)
    return function(props, children)
      return { type = kind, props = props or {}, children = children or {} }
    end
  end
  local ui = {}
  for _, kind in ipairs({
    "column", "row", "scroll", "box", "label", "markdown", "glyph", "image", "separator",
    "spacer", "progress", "button", "graph", "input", "select", "slider", "toggle",
    "dragSource", "dropZone",
  }) do
    ui[kind] = node(kind)
  end

  env = setmetatable({
    ui = ui,
    panel = {
      render = function(tree) table.insert(journal.renders, tree) end,
      close = function() end,
      openContextMenu = function() return false end,
      setWantsSecondTicks = function() end,
      setNeedsFrameTick = function() end,
    },
    barWidget = {
      render = function(tree) journal.tree = tree end,
      setText = function(text) journal.text = text end,
      setTooltip = function(tooltip) journal.tooltip = tooltip end,
      clearTooltip = function() journal.tooltip = nil; journal.clearedTooltip = true end,
      setGlyph = function(name) journal.glyph = name end,
      setImage = function(path) journal.image = path end,
      isVertical = function() return false end,
      outputName = function() return "eDP-1" end,
    },
    require = function(path)
      if path ~= "./shared.luau" then
        error("unexpected require: " .. tostring(path))
      end
      return assert(loadfile(PLUGIN .. "/shared.luau", "t", env))()
    end,
    noctalia = {
      log = function(message) table.insert(journal.logs, message) end,
      getConfig = function(key) return settings[key] end,
      tr = function(key, subst)
        local text = TRANSLATIONS[key] or key
        for name, value in pairs(subst or {}) do
          text = text:gsub("{" .. name .. "}", tostring(value))
        end
        return text
      end,
      notify = function() end,
      notifyError = function(title, body) table.insert(journal.notifications, body) end,
      openSettings = function() journal.settingsOpened = true end,
      togglePanel = function(id) journal.toggledPanel = id end,
      setUpdateInterval = function(ms) journal.updateInterval = ms end,
      isDarkMode = function() return world.darkMode ~= false end,
      commandExists = function(name) return (world.openers or {})[name] == true end,
      expandPath = function(path) return (path:gsub("^~", os.getenv("HOME") or "~")) end,
      -- Defined even though nothing should call them: a check that nothing is
      -- spawned only means something if spawning would be recorded, and if the
      -- entry under test never sees a nil function.
      runAsync = function(command, callback)
        table.insert(journal.commands, command)
        if callback then
          callback(world.commandResult or { exitCode = 0, stdout = "", stderr = "" })
        end
        return true
      end,
      runStream = function(command, onLine)
        table.insert(journal.commands, command)
        journal.stream = onLine
        return true
      end,
      copyToClipboard = function(text)
        journal.copied = text
        return world.clipboardWorks ~= false
      end,
      fileExists = function() return world.keyExists ~= false end,
      readFile = function()
        if world.keyReadable == false then
          return nil, "permission denied"
        end
        return world.keyContents or "secret-key\n"
      end,
      http = function(request, onResponse)
        table.insert(journal.requests, request)
        if world.httpStarts == false then
          return false
        end
        local path = tostring(request.url):match("/api/[%w/]+$")
        local byPath = { ["/api/usage/quota"] = "quota", ["/api/auth/me"] = "me", ["/api/metrics/usage"] = "metrics" }
        local reply = (world.replies or {})[path] or { ok = true, status = 200, body = byPath[path] }
        onResponse({ ok = reply.ok ~= false, status = reply.status or 200, body = reply.body or "" })
        return true
      end,
      json = {
        decode = function(text)
          local value = bodies()[text]
          if value == nil then
            return nil, "not JSON"
          end
          return value
        end,
      },
      string = { trim = function(t) return (t:gsub("^%s+", ""):gsub("%s+$", "")) end },
      state = {
        set = function(key, value)
          journal.state[key] = value
          local watcher = journal.watchers[key]
          if watcher ~= nil then
            watcher(value)
          end
        end,
        get = function(key) return journal.state[key] end,
        watch = function(key, callback) journal.watchers[key] = callback end,
      },
    },
  }, { __index = _G })
end

local function load(entry)
  local chunk, err = loadfile(PLUGIN .. "/" .. entry, "t", env)
  if chunk == nil then
    failures[#failures + 1] = entry .. ": " .. tostring(err)
    print("FAIL " .. entry .. " does not load: " .. tostring(err))
    return false
  end
  local ok, err2 = pcall(chunk)
  if not ok then
    failures[#failures + 1] = entry .. ": " .. tostring(err2)
    print("FAIL " .. entry .. " errors on load: " .. tostring(err2))
    return false
  end
  return true
end

-- Helpers over the painted tree: the tools the assertions below need.
local function walk(node, visit)
  if type(node) ~= "table" then
    return
  end
  if node.type ~= nil then
    visit(node)
  end
  for _, child in ipairs(node.children or {}) do
    walk(child, visit)
  end
end
local function collect(row, kind)
  local out = {}
  walk(row, function(node)
    if node.type == kind then
      out[#out + 1] = node
    end
  end)
  return out
end
local function labels(row)
  local out = {}
  for _, node in ipairs(collect(row, "label")) do
    out[#out + 1] = tostring(node.props.text)
  end
  return out
end
local function anyLabelMentions(row, needle)
  for _, text in ipairs(labels(row)) do
    if text:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- ── the poller ──────────────────────────────────────────────────────────────
print("-- service.luau")

reset()
check(load("service.luau"), "the poller loads")
eq(#journal.requests, 3, "one request per endpoint")
eq(journal.requests[1].url, "https://cloud-api.nan.builders/api/usage/quota", "the quota endpoint")
eq(journal.requests[2].url, "https://cloud-api.nan.builders/api/auth/me", "the account endpoint")
eq(journal.requests[3].url, "https://cloud-api.nan.builders/api/metrics/usage", "the aggregate endpoint")
local authorised = false
for _, header in ipairs(journal.requests[1].headers) do
  if header == "Authorization: Bearer secret-key" then
    authorised = true
  end
end
check(authorised, "the key from the file is sent as a bearer token")
check(journal.requests[1].headers[2] == "Accept: application/json", "and it answers in JSON")
eq(journal.state.data.quota, QUOTA, "the quota it read is published")
eq(journal.state.data.me, ME, "with the account")
eq(journal.state.data.metrics, METRICS, "and the aggregates")
eq(journal.state.data.error, "", "and no error")
eq(journal.state.data.fetchedAt ~= nil, true, "and the time it was fetched")

reset({ keyContents = "  padded-key\n" })
load("service.luau")
local padded = false
for _, header in ipairs(journal.requests[1].headers) do
  if header == "Authorization: Bearer padded-key" then
    padded = true
  end
end
check(padded, "whitespace around the key is trimmed")

reset({ keyExists = false })
check(load("service.luau"), "the poller loads without a key file")
eq(#journal.requests, 0, "and asks the API nothing")
eq(journal.state.data.error, "No API key at ~/.config/nan/api-key", "it says which file is missing")

reset({ keyContents = "secret-key\n# a comment someone added\n" })
load("service.luau")
local firstLine = false
for _, header in ipairs(journal.requests[1].headers) do
  if header == "Authorization: Bearer secret-key" then
    firstLine = true
  end
end
check(firstLine, "only the first line of the key file is sent, so a stray comment cannot corrupt the header")
eq(journal.state.data.error, "", "and a multi-line key file is not an error")

reset({ keyReadable = false })
load("service.luau")
check(journal.state.data.error:find("Could not read", 1, true) ~= nil, "an unreadable key is reported as such")

reset({ keyContents = "   \n" })
load("service.luau")
check(journal.state.data.error:find("is empty", 1, true) ~= nil, "an empty key file is reported as such")

reset({ replies = { ["/api/usage/quota"] = { status = 401 } } })
load("service.luau")
check(journal.state.data.error:find("rejected the API key", 1, true) ~= nil, "a 401 says the key was rejected")
eq(journal.state.data.quota, nil, "and there is nothing to paint")

reset({ replies = { ["/api/auth/me"] = { status = 500 } }, bodies = { quota = QUOTA, metrics = METRICS } })
load("service.luau")
eq(journal.state.data.error, "", "a failing endpoint that only decorates the quota is not an error")
eq(journal.state.data.quota, QUOTA, "the quota still arrives")

reset({ replies = { ["/api/usage/quota"] = { body = "junk" } } })
load("service.luau")
check(journal.state.data.error:find("Unreadable answer", 1, true) ~= nil, "an unreadable answer is reported")

reset({ httpStarts = false })
load("service.luau")
check(journal.state.data.error:find("Could not start", 1, true) ~= nil, "a request that cannot start is reported")

reset({ settings = { show_metrics = false } })
load("service.luau")
eq(#journal.requests, 2, "turning the aggregates off saves their request")

reset({ settings = { interval = 900 } })
load("service.luau")
env.update()
eq(journal.updateInterval, 900000, "the tick is the poll interval")
eq(#journal.requests, 3, "and a tick that comes straight after load does not fetch twice")

reset()
load("service.luau")
journal.requests = {}
envy = env
env.update()
eq(#journal.requests, 0, "a second tick inside the interval is skipped")
env.noctalia.state.set("refresh", os.time())
eq(#journal.requests, 3, "but a refresh asked for by a surface goes now")

reset({ replies = { ["/api/usage/quota"] = { status = 500 } } })
load("service.luau")
check(journal.state.data.quota == nil, "a failed first poll leaves nothing to paint")

reset()
load("service.luau")
world.replies = { ["/api/usage/quota"] = { status = 500 } }
env.noctalia.state.set("refresh", os.time())
eq(journal.state.data.quota, QUOTA, "a failure after good data keeps the numbers")
check(journal.state.data.error ~= "", "and records why they are old")
check(journal.state.data.fetchedAt ~= nil, "and when they were read")

-- ── the bar widget ──────────────────────────────────────────────────────────
print("-- bar.luau")

reset()
check(load("bar.luau"), "the widget loads")
eq(#journal.commands, 0, "and spawns nothing")
check(anyLabelMentions(journal.tree, "—"), "with no data it shows a dash")
eq(#collect(journal.tree, "progress"), 0, "and draws no gauge next to a dash")
check(journal.tooltip == "waiting for the first poll", "and says it is waiting")

reset()
load("service.luau")
local published = journal.state.data
reset()
journal.state.data = published
check(load("bar.luau"), "the widget loads with data already published")
check(anyLabelMentions(journal.tree, "80%"), "the bar carries the percentage")
check(anyLabelMentions(journal.tree, "4d"), "and the countdown")
check(anyLabelMentions(journal.tree, "ds4f"), "and the model")
eq(#collect(journal.tree, "progress"), 1, "and one gauge")

reset({ settings = { panel_gauge = "none" }, })
journal.state.data = published
load("bar.luau")
eq(#collect(journal.tree, "progress"), 0, "the gauge setting is honoured")

reset({ settings = { show_icon = false, show_glyph = true, glyph = "brain" } })
journal.state.data = published
load("bar.luau")
local glyphs = collect(journal.tree, "glyph")
eq(#glyphs, 1, "the glyph stands in for the logo when asked")
eq(glyphs[1].props.name, "brain", "and it is the configured one")

reset()
journal.state.data = { quota = quota({ { model = "x", tokensUsed = 95, cap = 100 } }), me = ME, metrics = METRICS, fetchedAt = NOW }
load("bar.luau")
local progress = collect(journal.tree, "progress")[1]
eq(progress.props.fill, "#e01b24", "a critical level draws in the alarm colour")

reset()
journal.state.data = published
load("bar.luau")
-- The figure, the countdown and the model are three labels at two sizes, which is how
-- the widget that sits beside this one on a real bar does it: the reading at full size
-- carrying the colour, the context a couple of points smaller and muted.
local function labelWith(text)
  for _, node in ipairs(collect(journal.tree, "label")) do
    if node.props.text == text then
      return node
    end
  end
  return nil
end
local figure = labelWith("80%")
local countdown = labelWith("4d")
local modelLabel = labelWith("ds4f")
check(figure ~= nil and countdown ~= nil and modelLabel ~= nil,
  "the bar paints the figure, the countdown and the model as separate labels")
check(figure ~= nil and figure.props.fontSize == 11 and figure.props.fontWeight == "semibold",
  "the figure reads at the bar's size, in semibold")
check(countdown ~= nil and countdown.props.fontSize == 10, "the countdown is two points smaller")
check(countdown ~= nil and countdown.props.color == "on_surface_variant", "and muted")
check(modelLabel ~= nil and modelLabel.props.color == "on_surface_variant", "as is the model")
check(countdown ~= nil and countdown.props.baseline == nil,
  "with no baseline override: the row's own centring is what places it")

-- The three toggles used to be the record's job, since the record composed one string.
-- Now the widget composes them, so they are the widget's to honour.
reset({ settings = { show_reset = false, show_model = false } })
journal.state.data = published
load("bar.luau")
check(labelWith("80%") ~= nil, "the figure still shows with only it enabled")
check(labelWith("4d") == nil, "the countdown is dropped when show_reset is off")
check(labelWith("ds4f") == nil, "and the model when show_model is off")

reset({ settings = { show_percentage = false } })
journal.state.data = published
load("bar.luau")
check(labelWith("80%") == nil, "the figure is dropped when show_percentage is off")
check(labelWith("4d") ~= nil, "and the countdown stays")

reset()
journal.state.data = published
load("bar.luau")
eq(#journal.commands, 0, "nothing is spawned to paint")
env.onClick()
eq(journal.toggledPanel, "cmoro-deusto/nan-usage:panel", "a click toggles this plugin's panel")

reset({ settings = { left_click = "nothing" } })
journal.state.data = published
load("bar.luau")
env.onClick()
eq(journal.toggledPanel, nil, "and does nothing when it is told to")
env.onRightClick()
eq(journal.settingsOpened, true, "a right click opens the settings page")

reset()
journal.state.data = published
load("bar.luau")
local tooltipRows = journal.tooltip
check(type(tooltipRows) == "table" and #tooltipRows >= 3, "the tooltip lists the models")
local hasValues = false
for _, row in ipairs(tooltipRows or {}) do
  if row.value == "2.4B / 3B·4d" then
    hasValues = true
  end
end
check(hasValues, "with tokens against the cap and the countdown, and no sentence")

reset()
journal.state.data = { quota = nil, error = "NaN rejected the API key in ~/.config/nan/api-key", fetchedAt = NOW - 60 }
load("bar.luau")
check(anyLabelMentions(journal.tree, "—"), "an error with nothing to paint still shows a dash")
check(type(journal.tooltip) == "string" and journal.tooltip:find("rejected the API key", 1, true) ~= nil,
  "and the reason in the tooltip")

reset()
journal.state.data = { quota = QUOTA, error = "Could not reach https://cloud-api.nan.builders", fetchedAt = NOW - 60 }
load("bar.luau")
check(anyLabelMentions(journal.tree, "80%"), "with data and an error, the numbers stay")
local stale = false
for _, row in ipairs(journal.tooltip or {}) do
  if row.key == "error" and row.value:find("showing the last data", 1, true) then
    stale = true
  end
end
check(stale, "and the tooltip says the data is the last one")

-- The service publishing after the widget is up repaints it at once.
reset()
journal.state.data = published
load("bar.luau")
journal.tree = nil
env.noctalia.state.set("data", { quota = QUOTA, me = ME, metrics = METRICS, fetchedAt = NOW })
check(journal.tree ~= nil, "a publish repaints the bar without waiting for a tick")

-- ── the panel ───────────────────────────────────────────────────────────────
print("-- panel.luau")

reset()
journal.state.data = published
check(load("panel.luau"), "the panel loads")
eq(#journal.commands, 0, "and spawns nothing")
check(env.onOpen ~= nil, "the panel has an open handler")
env.onOpen({})
local renders = #journal.renders
check(renders > 0, "opening it renders")
check(anyLabelMentions(journal.renders[renders], "Overall"), "the account-wide entry is there")
check(anyLabelMentions(journal.renders[renders], "Where it went"), "with the per-model shares")
check(anyLabelMentions(journal.renders[renders], "2.4B"), "and the tokens used")

reset()
check(load("panel.luau"), "the panel loads with no data")
env.onOpen({})
local last = journal.renders[#journal.renders]
check(anyLabelMentions(last, "Waiting for the first poll"), "with no data it says it is waiting")
check(journal.state.refresh ~= nil, "and asks the poller to go now")

reset()
journal.state.data = published
load("panel.luau")
env.onOpen({})
journal.state.refresh = nil
env.onRefresh()
check(journal.state.refresh ~= nil, "the refresh button asks over the shared state channel")
eq(#journal.commands, 0, "and not by running anything")

-- Opening on a model, not on the overall entry: the header of a model's detail has
-- to carry the tier pill too, and it used to reference an undefined global there.
reset()
journal.state.data = published
journal.state.selected = "glm5.3-flash"
load("panel.luau")
env.onOpen({})
local modelRender = journal.renders[#journal.renders]
check(anyLabelMentions(modelRender, "glm5.3-flash"), "the panel opens on the selected model")
check(anyLabelMentions(modelRender, "INFERENCE"), "and its header carries the tier pill, not a nil row")

reset({ openers = { ["xdg-open"] = true } })
journal.state.data = published
load("panel.luau")
env.onOpen({})
journal.copied = nil
env.onOpenSite()
check(journal.commands[1] ~= nil and journal.commands[1]:find("xdg-open", 1, true) ~= nil,
  "the link button opens NaN's dashboard through the opener that exists")
eq(journal.copied, nil, "and does not bother copying")

reset({ openers = { ["gio"] = true } })
journal.state.data = published
load("panel.luau")
env.onOpen({})
env.onOpenSite()
check(journal.commands[1]:find("^gio open", 1) ~= nil, "preferring gio when both are there")

reset({ settings = { site_action = "copy" } })
journal.state.data = published
load("panel.luau")
env.onOpen({})
journal.copied = nil
env.onOpenSite()
eq(journal.copied, "https://cloud.nan.builders", "and it can copy the address instead, when asked to")
eq(#journal.commands, 0, "without starting anything")

reset()
journal.state.data = published
load("panel.luau")
env.onOpen({})
journal.copied = nil
env.onOpenSite()
eq(journal.copied, "https://cloud.nan.builders", "with no opener installed the address is copied")
eq(#journal.commands, 0, "so the button is never dead")

reset()
journal.state.data = published
load("panel.luau")
env.onOpen({})
env.onOpenSettings()
eq(journal.settingsOpened, true, "the cog opens the plugin's settings")

-- ── report ──────────────────────────────────────────────────────────────────

if #failures > 0 then
  io.stderr:write(("%d of %d checks failed:\n"):format(#failures, checks))
  for _, failure in ipairs(failures) do
    io.stderr:write("  " .. failure .. "\n")
  end
  os.exit(1)
end
print(("%d checks pass (plugin)"):format(checks))
