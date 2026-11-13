--!nonstrict
-- The three entries, against a fake host.
--
-- The model is tested on its own in shared_test.lua, where it needs nothing from
-- Noctalia. This file tests the wiring: that service.luau reads the key, asks
-- /v1/usage and nothing else, and publishes what came back; that the widget and the
-- panel paint that data with the real model and spawn nothing to do it; and that a
-- refresh is asked for over the shared state channel rather than by running a
-- program.
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

-- ── a fixed clock ───────────────────────────────────────────────────────────

-- The entries read os.time(); every one of them, and the model they load, sees this
-- clock instead, so levels and countdowns are the same on any day the tests run.
local function utc(year, month, day, hour)
  local guess = os.time({ year = year, month = month, day = day, hour = hour or 0 })
  local fields = os.date("!*t", guess)
  fields.isdst = nil
  return guess - (os.time(fields) - guess)
end
local DAY = 86400
local NOW = utc(2027, 1, 20, 12)
local fakeOs = setmetatable({
  time = function(fields)
    if fields ~= nil then
      return os.time(fields)
    end
    return NOW
  end,
}, { __index = os })

-- ── fixtures: /v1/usage answers, in the shape the API returns ───────────────

-- A 31-day period, 19.5 days in, 40% used: a calm pace.
local function usage(credits, rows)
  return {
    object = "usage.report",
    data = rows or {
      { date = "2027-01-05", model = "deepseek-v4-flash", prompt_tokens = 50e6, cached_tokens = 30e6, completion_tokens = 5e5, api_requests = 900, credits = 2784.5 },
      { date = "2027-01-19", model = "glm5.3", prompt_tokens = 2e5, cached_tokens = 0, completion_tokens = 1000, api_requests = 4, credits = 9.9 },
      { date = "2027-01-20", model = "deepseek-v4-flash", prompt_tokens = 1e6, cached_tokens = 6e5, completion_tokens = 2e4, api_requests = 20, credits = 5.6 },
    },
    all_time = { total_tokens = 1.2e9, api_requests = 6000 },
    has_more = false,
    next_cursor = nil,
    credits = credits or {
      period_start = "2027-01-01T00:00:00Z", period_end = "2027-02-01T00:00:00Z",
      allowance = 7000, used = 2800, remaining = 4200, pack_credits = 0, frozen = false,
    },
  }
end
local USAGE = usage()
local CRITICAL = usage({
  period_start = "2027-01-01T00:00:00Z", period_end = "2027-02-01T00:00:00Z",
  allowance = 7000, used = 6500, remaining = 500, pack_credits = 0, frozen = false,
})
local FROZEN = usage({
  period_start = "2027-01-01T00:00:00Z", period_end = "2027-02-01T00:00:00Z",
  allowance = 7000, used = 2800, remaining = 4200, pack_credits = 0, frozen = true,
})
local SPENT = usage({
  period_start = "2027-01-01T00:00:00Z", period_end = "2027-02-01T00:00:00Z",
  allowance = 7000, used = 7000, remaining = 0, pack_credits = 0, frozen = false,
})
-- Two pages: the first says there is more, the second carries the rest of the rows.
local PAGE1 = usage(nil, { USAGE.data[1] })
PAGE1.has_more = true
PAGE1.next_cursor = "c/2+"
local PAGE2 = { object = "usage.report", data = { USAGE.data[2], USAGE.data[3] }, has_more = false }

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

-- ── a fake host ─────────────────────────────────────────────────────────────

local world, journal, env

local function reset(overrides)
  world = overrides or {}
  journal = { requests = {}, renders = {}, commands = {}, notifications = {}, state = {}, watchers = {}, logs = {} }
  local settings = {
    api_key = "~/.config/nan/api-key", interval = 300, bar_value = "percent", panel_gauge = "bar",
    show_reset = true, show_cache = false, show_icon = true, icon_style = "ghost",
    show_glyph = false, glyph = "chart-pie", show_tooltip = true, left_click = "panel",
    site_action = "open",
  }
  for key, value in pairs(world.settings or {}) do
    settings[key] = value
  end

  -- The bodies the fake API answers with, by name: json.decode looks them up.
  local bodies = { usage = USAGE, page1 = PAGE1, page2 = PAGE2 }
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

  local modules = {}
  env = setmetatable({
    os = fakeOs,
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
      local file = ({ ["./shared.luau"] = "shared.luau", ["./prices.luau"] = "prices.luau" })[path]
      if file == nil then
        error("unexpected require: " .. tostring(path))
      end
      if modules[file] == nil then
        modules[file] = assert(loadfile(PLUGIN .. "/" .. file, "t", env))()
      end
      return modules[file]
    end,
    noctalia = {
      log = function(message) table.insert(journal.logs, message) end,
      getConfig = function(key) return settings[key] end,
      tr = function(key, subst)
        local text = TRANSLATIONS[key] or key
        for name, value in pairs(subst or {}) do
          text = text:gsub("{" .. name .. "}", (tostring(value):gsub("%%", "%%%%")))
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
      -- Answers by page: world.replies is a list, one reply per request in order,
      -- and the last one repeats. A reply's body names an entry of `bodies`.
      http = function(request, onResponse)
        table.insert(journal.requests, request)
        if world.httpStarts == false then
          return false
        end
        local replies = world.replies or { {} }
        local reply = replies[math.min(#journal.requests, #replies)]
        onResponse({ ok = reply.ok ~= false, status = reply.status or 200, body = reply.body or "usage" })
        return true
      end,
      json = {
        decode = function(text)
          local value = bodies[text]
          if value == nil then
            return nil, "not JSON"
          end
          -- A copy, so appending a second page never changes the fixture.
          local copy = {}
          for key, entry in pairs(value) do
            copy[key] = entry
          end
          if type(value.data) == "table" then
            copy.data = { table.unpack(value.data) }
          end
          return copy
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
local function labelWith(row, text)
  for _, node in ipairs(collect(row, "label")) do
    if node.props.text == text then
      return node
    end
  end
  return nil
end
local function tooltipValue(key)
  for _, row in ipairs(type(journal.tooltip) == "table" and journal.tooltip or {}) do
    if row.key == key then
      return row.value
    end
  end
  return nil
end

-- ── the poller ──────────────────────────────────────────────────────────────
print("-- service.luau")

reset()
check(load("service.luau"), "the poller loads")
eq(#journal.requests, 1, "one request per poll")
eq(journal.requests[1].url, "https://api.nan.builders/v1/usage?start_date=2026-12-20&limit=500",
  "to /v1/usage, 31 days back while the period is not known")
local onlyUsage = true
for _, request in ipairs(journal.requests) do
  if not request.url:find("^https://api%.nan%.builders/v1/usage%?") then
    onlyUsage = false
  end
end
check(onlyUsage, "and to nothing else")
local authorised = false
for _, header in ipairs(journal.requests[1].headers) do
  if header == "Authorization: Bearer secret-key" then
    authorised = true
  end
end
check(authorised, "the key from the file is sent as a bearer token")
check(journal.requests[1].headers[2] == "Accept: application/json", "and it answers in JSON")
eq(journal.state.data.usage.credits.used, 2800, "the answer is published")
eq(journal.state.data.error, "", "with no error")
eq(journal.state.data.fetchedAt, NOW, "and the time it was fetched")

env.noctalia.state.set("refresh", NOW)
eq(journal.requests[2].url, "https://api.nan.builders/v1/usage?start_date=2027-01-01&limit=500",
  "once the period is known, the next poll asks from its first day")

reset({ replies = { { body = "page1" }, { body = "page2" } } })
load("service.luau")
eq(#journal.requests, 2, "a second page is fetched when the first says there is more")
check(journal.requests[2].url:find("&cursor=c%2F2%2B", 1, true) ~= nil, "with the cursor, encoded")
eq(#journal.state.data.usage.data, 3, "and its rows join the first page's")
eq(journal.state.data.usage.credits.used, 2800, "which keeps the credits and totals")

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

reset({ keyReadable = false })
load("service.luau")
check(journal.state.data.error:find("Could not read", 1, true) ~= nil, "an unreadable key is reported as such")

reset({ keyContents = "   \n" })
load("service.luau")
check(journal.state.data.error:find("is empty", 1, true) ~= nil, "an empty key file is reported as such")

reset({ replies = { { status = 401 } } })
load("service.luau")
check(journal.state.data.error:find("rejected the API key", 1, true) ~= nil, "a 401 says the key was rejected")
eq(journal.state.data.usage, nil, "and there is nothing to paint")

reset({ replies = { { body = "junk" } } })
load("service.luau")
check(journal.state.data.error:find("Unreadable answer", 1, true) ~= nil, "an unreadable answer is reported")

reset({ httpStarts = false })
load("service.luau")
check(journal.state.data.error:find("Could not start", 1, true) ~= nil, "a request that cannot start is reported")

reset({ settings = { interval = 900 } })
load("service.luau")
env.update()
eq(journal.updateInterval, 900000, "the tick is the poll interval")
eq(#journal.requests, 1, "and a tick that comes straight after load does not fetch twice")

reset()
load("service.luau")
journal.requests = {}
env.update()
eq(#journal.requests, 0, "a second tick inside the interval is skipped")
env.noctalia.state.set("refresh", NOW)
eq(#journal.requests, 1, "but a refresh asked for by a surface goes now")

reset()
load("service.luau")
world.replies = { { status = 500 } }
env.noctalia.state.set("refresh", NOW)
eq(journal.state.data.usage.credits.used, 2800, "a failure after good data keeps the numbers")
check(journal.state.data.error:find("500", 1, true) ~= nil, "and records why they are old")

reset({ replies = { { status = 429 } } })
load("service.luau")
check(journal.state.data.error:find("slow down", 1, true) ~= nil, "a 429 is said plainly")
env.noctalia.state.set("refresh", NOW)
eq(#journal.requests, 1, "and the poller stays quiet for a minute, even when asked")

-- ── the bar widget ──────────────────────────────────────────────────────────
print("-- bar.luau")

reset()
check(load("bar.luau"), "the widget loads")
eq(#journal.commands, 0, "and spawns nothing")
check(anyLabelMentions(journal.tree, "—"), "with no data it shows a dash")
eq(#collect(journal.tree, "progress"), 0, "and draws no gauge next to a dash")
check(journal.tooltip == "waiting for the first poll", "and says it is waiting")

local published = { usage = USAGE, fetchedAt = NOW, error = "" }

reset()
journal.state.data = published
check(load("bar.luau"), "the widget loads with data already published")
local figure = labelWith(journal.tree, "40%")
local countdown = labelWith(journal.tree, "11d")
check(figure ~= nil, "the bar carries the share of the allowance used")
check(countdown ~= nil, "and the countdown to the renewal")
check(figure ~= nil and figure.props.fontSize == 11 and figure.props.fontWeight == "semibold",
  "the figure reads at the bar's size, in semibold")
check(figure ~= nil and figure.props.color == "on_surface", "in the theme's ink while the pace is calm")
check(countdown ~= nil and countdown.props.fontSize == 10 and countdown.props.color == "on_surface_variant",
  "the countdown is a point smaller, and muted")
eq(#collect(journal.tree, "progress"), 1, "with one gauge")
check(not anyLabelMentions(journal.tree, "cached"), "and no cache share unless asked for")

eq(tooltipValue("Used"), "2,800 · 40%", "the tooltip has the credits used and their share")
eq(tooltipValue("Allowance"), "7,000", "the allowance")
eq(tooltipValue("Left"), "4,200", "what is left")
eq(tooltipValue("Resets in"), "11d 12h", "how long until the renewal")
check((tooltipValue("Renews") or ""):find("^1 Feb %d%d:%d%d$") ~= nil, "and when it is")
eq(tooltipValue("Pace at reset"), "~4,451 · 64%", "where the pace lands")
eq(tooltipValue("Today"), "5.6", "today's credits")
eq(tooltipValue("Cached"), "60% of input", "the period's cache share")
eq(tooltipValue("New input"), "20.6M", "new input")
eq(tooltipValue("Cached input"), "30.6M", "cached input")
eq(tooltipValue("Output"), "521K", "output")
check(tooltipValue("Cache saved") ~= nil, "what the cache saved")
eq(tooltipValue("deepseek-v4-flash"), "2,790.1 · 100%", "and one line per model")
local longest = 0
for _, row in ipairs(journal.tooltip) do
  if row.key ~= "error" then
    longest = math.max(longest, utf8.len(row.value))
  end
end
check(longest <= 14, "no value is longer than the tooltip shows before cutting it off: " .. longest)
eq(tooltipValue("Packs"), nil, "no packs row without packs")

reset({ settings = { bar_value = "remaining", show_cache = true } })
journal.state.data = published
load("bar.luau")
check(labelWith(journal.tree, "4,200") ~= nil, "bar_value can show the credits left")
local cacheLabel = labelWith(journal.tree, "60% cached")
check(cacheLabel ~= nil, "show_cache adds the cache share")
check(cacheLabel ~= nil and cacheLabel.props.color == "#3fb8a8", "in the colour the panel gives cached input")

reset({ settings = { bar_value = "used", show_reset = false } })
journal.state.data = published
load("bar.luau")
check(labelWith(journal.tree, "2,800") ~= nil, "bar_value can show the credits used")
check(labelWith(journal.tree, "11d") == nil, "and the countdown goes when show_reset is off")

reset({ settings = { panel_gauge = "none" } })
journal.state.data = published
load("bar.luau")
eq(#collect(journal.tree, "progress"), 0, "the gauge setting is honoured")

-- Every gauge the setting offers, at 40% of the allowance used.
local function gaugeWith(gauge, data, dark)
  reset({ settings = { panel_gauge = gauge }, darkMode = dark })
  journal.state.data = data or published
  load("bar.luau")
  return journal.tree
end
local function gaugeImage(tree)
  local images = collect(tree, "image")
  return images[2] and images[2].props.path
end

eq(gaugeImage(gaugeWith("segments10")), "gauges/seg10-dark-ok-4.png", "segments10 lights four of ten cells at 40%")
eq(gaugeImage(gaugeWith("segments5")), "gauges/seg5-dark-ok-2.png", "segments5 lights two of five")
eq(gaugeImage(gaugeWith("ring")), "gauges/ring-dark-ok-40.png", "the ring fills to the 40% step in the theme's ink")
eq(gaugeImage(gaugeWith("ring", { usage = CRITICAL, fetchedAt = NOW, error = "" }, false)), "gauges/ring-light-crit-90.png",
  "and in red on a light theme when critical")
local missing = {}
local function expect(name)
  local file = io.open(PLUGIN .. "/gauges/" .. name, "rb")
  if file == nil then
    missing[#missing + 1] = name
  else
    file:close()
  end
end
for _, theme in ipairs({ "dark", "light" }) do
  for _, level in ipairs({ "ok", "warn", "crit" }) do
    for step = 0, 100, 10 do
      expect("ring-" .. theme .. "-" .. level .. "-" .. step .. ".png")
    end
    for lit = 0, 10 do
      expect("seg10-" .. theme .. "-" .. level .. "-" .. lit .. ".png")
    end
    for lit = 0, 5 do
      expect("seg5-" .. theme .. "-" .. level .. "-" .. lit .. ".png")
    end
  end
end
eq(#missing, 0, "every gauge raster the bar can ask for exists: " .. table.concat(missing, ", "))

local battery = collect(gaugeWith("battery"), "glyph")
eq(battery[1] and battery[1].props.name, "battery-2", "the battery keeps two of four bars with 60% left")

local graph = collect(gaugeWith("sparkline"), "graph")
eq(#graph, 1, "the sparkline is a graph")
eq(graph[1] and #graph[1].props.values, 20, "with one point per day so far")
local peak = 0
for _, value in ipairs(graph[1] and graph[1].props.values or {}) do
  peak = math.max(peak, value)
end
eq(peak, 1, "scaled to the busiest day")

eq(#collect(gaugeWith("none"), "progress"), 0, "and none draws nothing")

reset({ settings = { show_icon = false, show_glyph = true, glyph = "brain" } })
journal.state.data = published
load("bar.luau")
local glyphs = collect(journal.tree, "glyph")
eq(#glyphs, 1, "the glyph stands in for the logo when asked")
eq(glyphs[1].props.name, "brain", "and it is the configured one")

reset()
journal.state.data = { usage = CRITICAL, fetchedAt = NOW, error = "" }
load("bar.luau")
eq(collect(journal.tree, "progress")[1].props.fill, "#e01b24", "a critical level draws in the alarm colour")
eq(labelWith(journal.tree, "93%").props.color, "#e01b24", "the figure too")

reset()
journal.state.data = { usage = FROZEN, fetchedAt = NOW, error = "" }
load("bar.luau")
check(labelWith(journal.tree, "paused") ~= nil, "a paused subscription says so in the bar")
eq(#collect(journal.tree, "progress"), 0, "with no gauge")

reset()
journal.state.data = { usage = { data = {} }, fetchedAt = NOW, error = "" }
load("bar.luau")
check(anyLabelMentions(journal.tree, "—"), "an account not billed in credits shows a dash")
eq(journal.tooltip, "This account isn't billed in credits", "and says why")

reset()
journal.state.data = { error = "NaN rejected the API key in ~/.config/nan/api-key" }
load("bar.luau")
check(anyLabelMentions(journal.tree, "—"), "an error with nothing to paint still shows a dash")
check(type(journal.tooltip) == "string" and journal.tooltip:find("rejected the API key", 1, true) ~= nil,
  "and the reason in the tooltip")

reset()
journal.state.data = { usage = USAGE, fetchedAt = NOW - 60, error = "Could not reach https://api.nan.builders/v1/usage" }
load("bar.luau")
check(labelWith(journal.tree, "40%") ~= nil, "with data and an error, the numbers stay")
check((tooltipValue("error") or ""):find("showing the last data", 1, true) ~= nil,
  "and the tooltip says the data is the last one")

reset()
journal.state.data = published
load("bar.luau")
env.onClick()
eq(journal.toggledPanel, "cmoro-deusto/nan-usage:panel", "a click toggles this plugin's panel")
env.onRightClick()
eq(journal.settingsOpened, true, "a right click opens the settings page")

reset({ settings = { left_click = "nothing" } })
journal.state.data = published
load("bar.luau")
env.onClick()
eq(journal.toggledPanel, nil, "and a click does nothing when it is told to")

-- The service publishing after the widget is up repaints it at once.
reset()
journal.state.data = published
load("bar.luau")
journal.tree = nil
env.noctalia.state.set("data", { usage = CRITICAL, fetchedAt = NOW, error = "" })
check(labelWith(journal.tree, "93%") ~= nil, "a publish repaints the bar without waiting for a tick")

-- ── the panel ───────────────────────────────────────────────────────────────
print("-- panel.luau")

reset()
journal.state.data = published
check(load("panel.luau"), "the panel loads")
eq(#journal.commands, 0, "and spawns nothing")
env.onOpen({})
local last = journal.renders[#journal.renders]
check(last ~= nil, "opening it renders")
check(anyLabelMentions(last, "Overall"), "the period overall is the first entry")
check(anyLabelMentions(last, "This period"), "and what it opens on")
check(anyLabelMentions(last, "Credits"), "with the credits card")
check(labelWith(last, "2,800") ~= nil and labelWith(last, "4,200") ~= nil, "used and left")
check(anyLabelMentions(last, "at this pace ~4,451"), "the pace")
check(anyLabelMentions(last, "60% CACHED"), "the cache share")
check(anyLabelMentions(last, "Cached input") and anyLabelMentions(last, "Output"), "the token split")
check(anyLabelMentions(last, "Daily credit usage"), "the per-day chart")
check(anyLabelMentions(last, "Credit breakdown by model"), "and each model's share")
check(anyLabelMentions(last, "All time: 1.2B tokens"), "and the lifetime line")
local dayBoxes = 0
for _, node in ipairs(collect(last, "box")) do
  if tostring(node.props.key):find("^day%-") then
    dayBoxes = dayBoxes + 1
  end
end
eq(dayBoxes, 31, "one box per day of the period, 1 Jan to 31 Jan")
local chart = nil
walk(last, function(node)
  if node.props.key == "days" then
    chart = node
  end
end)
check(chart ~= nil and labelWith(chart, "5.6") ~= nil, "today's column is labelled with its credits")
check(chart ~= nil and labelWith(chart, "2.8k") ~= nil, "a busy day in thousands")
check(chart ~= nil and labelWith(chart, "31") ~= nil, "and every column with its day of the month")

reset()
check(load("panel.luau"), "the panel loads with no data")
env.onOpen({})
last = journal.renders[#journal.renders]
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

reset()
journal.state.data = published
journal.state.selected = "deepseek-v4-flash"
load("panel.luau")
env.onOpen({})
last = journal.renders[#journal.renders]
check(anyLabelMentions(last, "100% OF CREDITS"), "a selected model's header has its share")
check(not anyLabelMentions(last, "per million"), "and no blended per-million figure, which would mix three prices into one")
check(anyLabelMentions(last, "Credits by token type"), "the estimated split by token type")
check(not anyLabelMentions(last, "ESTIMATE"), "with no estimate pill")
check(anyLabelMentions(last, "Estimated from NaN's prices of"), "a footer saying where the split comes from")
check(labelWith(last, "Total") ~= nil, "and a total the rows add up to")
check(anyLabelMentions(last, "920 requests"), "and its requests")

reset()
journal.state.data = published
load("panel.luau")
env.onOpen({})
last = journal.renders[#journal.renders]
check(anyLabelMentions(last, "qwen3.8-max"), "the list has every model on NaN's price list")
check(anyLabelMentions(last, "No usage this period"), "saying which ones have no usage")

reset()
journal.state.data = published
journal.state.selected = "qwen3.8-max"
load("panel.luau")
env.onOpen({})
last = journal.renders[#journal.renders]
check(anyLabelMentions(last, "Prices per 1M tokens"), "an unused model shows its prices")
check(labelWith(last, "300") ~= nil, "output among them")
check(not anyLabelMentions(last, "Daily credit usage"), "and no empty charts")

reset()
journal.state.data = published
load("bar.luau")
eq(tooltipValue("qwen3.8-max"), nil, "the tooltip lists only the models used")

reset()
journal.state.data = published
journal.state.selected = "glm5.3"
load("panel.luau")
env.onOpen({})
last = journal.renders[#journal.renders]
check(anyLabelMentions(last, "glm5.3"), "a model with no cached input opens too")

reset()
journal.state.data = published
journal.state.selected = "gone-model"
load("panel.luau")
env.onOpen({})
check(anyLabelMentions(journal.renders[#journal.renders], "This period"), "a model that left the period falls back to the overall view")

reset({ openers = { ["xdg-open"] = true } })
journal.state.data = { usage = SPENT, fetchedAt = NOW, error = "" }
load("panel.luau")
env.onOpen({})
last = journal.renders[#journal.renders]
check(anyLabelMentions(last, "used this period's credits"), "out of credits, the panel says so first")
local buy = nil
for _, node in ipairs(collect(last, "button")) do
  if node.props.text == "Buy a credit pack" then
    buy = node
  end
end
check(buy ~= nil and buy.props.onClick == "onBuyCredits", "with a button to buy a pack")
env.onBuyCredits()
eq(journal.commands[1], "xdg-open https://cloud.nan.builders/dashboard?buy=credits", "which opens NaN's own page for it")

reset()
journal.state.data = { usage = FROZEN, fetchedAt = NOW, error = "" }
load("panel.luau")
env.onOpen({})
check(anyLabelMentions(journal.renders[#journal.renders], "subscription is paused"), "a paused subscription is said first")

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
