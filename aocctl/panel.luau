--!nonstrict
-- The AOC monitor's settings and presets. Opened from the bar widget (for that bar's monitor)
-- or with `noctalia msg panel-toggle manishmodak/aocctl:panel` (the focused output's monitor,
-- else the first AOC monitor). Sliders write when released, choices at once; every write is
-- read back by aocctl, then the panel re-reads all settings because modes (DCR, Eco, HDR,
-- Low Blue) change others.
local lib = require("./lib.luau")

local display = nil -- from `aocctl list`
local settings = {} -- rows of `aocctl get --json`
local presets = {} -- rows of `aocctl preset list --json`
local drafts = {} -- slider values the user is dragging to, by setting id
local status = nil -- { text, error }
local loading = false
local opening = 0 -- counts panel openings, so a slow `aocctl list` from an earlier one is ignored

-- aocctl runs one at a time from here, in the order the user acted; a newer job with the same
-- key drops the queued one
local queue = {}
local running = false
local wrote = false -- a write ran since the last full read

local function runNext()
  if running then
    return
  end
  local job = table.remove(queue, 1)
  if job == nil then
    return
  end
  running = true
  lib.run(job.args, job.timeoutMs, function(data, err)
    running = false
    job.done(data, err)
    runNext()
  end)
end

local function enqueue(job)
  if job.key then
    for i, queued in ipairs(queue) do
      if queued.key == job.key then
        table.remove(queue, i)
        break
      end
    end
  end
  table.insert(queue, job)
  runNext()
end

local render

local function setStatus(text, isError)
  status = text and { text = text, error = isError } or nil
end

local function publishBrightness()
  for _, s in ipairs(settings) do
    if s.id == "brightness" and s.value then
      noctalia.state.set(lib.brightnessKey(display.connector), { value = s.value, max = s.max })
    end
  end
end

-- Re-reads every setting and the presets
local function readAll()
  if display == nil then
    return
  end
  local connector = display.connector
  enqueue({
    key = "get",
    args = { "get", "--display", connector },
    timeoutMs = 20000,
    done = function(data, err)
      if display == nil or display.connector ~= connector then
        return
      end
      loading = false
      if data then
        settings = data.settings or {}
        publishBrightness()
      else
        setStatus(err, true)
      end
      render()
    end,
  })
  enqueue({
    key = "presets",
    args = { "preset", "list", "--display", connector },
    timeoutMs = 10000,
    done = function(data, err)
      if data then
        presets = data.presets or {}
      elseif display and display.connector == connector then
        setStatus(err, true)
      end
      render()
    end,
  })
end

local function valueText(s, value)
  local options = s.domain and s.domain.options
  if options then
    return options[value + 1] or tostring(value)
  end
  return tostring(value)
end

-- Writes one setting, reports the read-back, then re-reads everything once the queue is empty
local function write(s, value)
  local connector = display.connector
  s.value = value
  wrote = true
  setStatus(`Setting {s.name} to {valueText(s, value)}…`, false)
  render()
  enqueue({
    key = "set:" .. s.id,
    args = { "set", s.id, tostring(value), "--display", connector },
    timeoutMs = 15000,
    done = function(data, err)
      if err then
        setStatus(`{s.name}: {err}`, true)
      elseif data.status == "verified" then
        setStatus(`{s.name} set to {valueText(s, value)}`, false)
      elseif data.status == "mismatch" then
        setStatus(`{s.name} reads back {valueText(s, data.read_back)}: the monitor didn't take it`, true)
      else
        setStatus(`{s.name}: sent, but couldn't read it back ({data.error or data.status})`, true)
      end
      if #queue == 0 and wrote then
        wrote = false
        readAll()
      end
      render()
    end,
  })
end

local function applyPreset(p)
  local connector = display.connector
  setStatus(`Applying {p.name}…`, false)
  render()
  enqueue({
    key = "apply",
    args = { "preset", "apply", p.name, "--display", connector },
    timeoutMs = 60000,
    done = function(data, err)
      if err then
        setStatus(`{p.name}: {err}`, true)
      else
        local failed = {}
        for _, r in ipairs(data.settings or {}) do
          if r.status ~= "verified" and r.status ~= "unchanged" then
            table.insert(failed, `{r.id} {r.status}`)
          end
        end
        if #failed == 0 then
          setStatus(`Applied {p.name}`, false)
        else
          setStatus(`{p.name}: {table.concat(failed, ", ")}`, true)
        end
      end
      readAll()
      render()
    end,
  })
end

-- ---------- rendering

local function sliderRow(s)
  local min = s.domain.min or 0
  local max = math.min(s.domain.max or s.max, s.max or s.domain.max)
  local shown = drafts[s.id] or s.value
  return ui.column({ key = s.id, gap = 4 }, {
    ui.row({ align = "center" }, {
      ui.label({ text = s.name, flexGrow = 1 }),
      ui.label({ text = tostring(shown), color = "on_surface_variant" }),
    }),
    ui.slider({
      min = min,
      max = max,
      step = 1,
      value = shown,
      controlSize = "sm",
      -- Also fires when a new reading moves the slider, with that reading: no draft then
      onChange = function(v)
        local n = math.floor(tonumber(v) or shown)
        drafts[s.id] = n ~= s.value and n or nil
        render()
      end,
      onDragEnd = function()
        local v = drafts[s.id]
        drafts[s.id] = nil
        if v ~= nil and v ~= s.value then
          write(s, v)
        else
          render()
        end
      end,
    }),
  })
end

local function isOnOff(options)
  return #options == 2 and options[1] == "Off" and options[2] == "On"
end

local function choiceRow(s)
  local options = s.domain.options
  local control
  if isOnOff(options) then
    control = ui.toggle({
      checked = s.value == 1,
      onChange = function(v)
        -- Fires for new readings too: write only what differs from the monitor
        local n = v == "true" and 1 or 0
        if n ~= s.value then
          write(s, n)
        end
      end,
    })
  else
    -- Only the names the monitor accepts (its reported maximum can be lower than the model's)
    local names = {}
    for i, name in ipairs(options) do
      if s.max == nil or i - 1 <= s.max then
        table.insert(names, name)
      end
    end
    control = ui.select({
      options = names,
      selectedIndex = s.value,
      controlSize = "sm",
      width = 170,
      onChange = function(index)
        local v = tonumber(index)
        if v ~= nil and v ~= s.value then
          write(s, v)
        end
      end,
    })
  end
  return ui.row({ key = s.id, align = "center", gap = 12, minHeight = 32 }, {
    ui.label({ text = s.name, flexGrow = 1 }),
    control,
  })
end

local function readOnlyRow(s)
  local text = s.error and "can't read" or valueText(s, s.value)
  return ui.row({ key = s.id, align = "center", gap = 12, minHeight = 28 }, {
    ui.label({ text = s.name, flexGrow = 1 }),
    ui.label({ text = text, color = "on_surface_variant" }),
  })
end

local function heading(text)
  return ui.label({ text = text, fontWeight = "bold", color = "primary" })
end

local function presetSummary(p)
  if p.error then
    return `Can't apply: {p.error}`
  end
  local parts = {}
  for _, v in ipairs(p.settings or {}) do
    table.insert(parts, `{v.id} {v.label or v.value}`)
  end
  return table.concat(parts, ", ")
end

local function body()
  if display == nil then
    return { ui.label({ text = loading and "Looking for the monitor…" or "No AOC monitor found", color = "on_surface_variant" }) }
  end
  if #settings == 0 then
    return { ui.label({ text = "Reading the monitor…", color = "on_surface_variant" }) }
  end
  local ranges, choices = {}, {}
  for _, s in ipairs(settings) do
    if s.error or not s.writable or s.domain == nil then
      table.insert(choices, readOnlyRow(s))
    elseif s.domain.options then
      table.insert(choices, choiceRow(s))
    else
      table.insert(ranges, sliderRow(s))
    end
  end
  local presetRows = {}
  for _, p in ipairs(presets) do
    table.insert(presetRows, ui.button({
      key = "preset:" .. p.name,
      text = p.name,
      glyph = "player-play",
      contentAlign = "start",
      controlSize = "sm",
      variant = "secondary",
      enabled = p.error == nil,
      tooltip = presetSummary(p),
      onClick = function()
        applyPreset(p)
      end,
    }))
  end
  if #presetRows == 0 then
    presetRows = { ui.label({ text = "None yet. Save one with: aocctl preset save <name>", color = "on_surface_variant" }) }
  end
  return {
    ui.column({ gap = 10 }, ranges),
    ui.separator({}),
    ui.column({ gap = 6 }, choices),
    ui.separator({}),
    heading("Presets"),
    ui.column({ gap = 6 }, presetRows),
  }
end

render = function()
  local title = display and lib.modelName(display) or "AOC monitor"
  local sub = display and display.connector or ""
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "device-desktop-cog", size = 20, color = "primary" }),
      ui.label({ text = title, fontSize = 15, fontWeight = "bold" }),
      ui.label({ text = sub, color = "on_surface_variant", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = "Read the monitor again", onClick = function()
        setStatus(nil)
        readAll()
      end }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = function()
        panel.close()
      end }),
    }),
    ui.column({ gap = 12 }, body()),
  }
  if status then
    table.insert(children, ui.label({ text = status.text, color = status.error and "error" or "on_surface_variant", maxLines = 3 }))
  end
  panel.render(ui.column({ gap = 12 }, children))
end

function onOpen(_context)
  -- The bar widget names its monitor just before it opens the panel
  local asked = noctalia.state.get("panelDisplay")
  local wanted = (asked and noctalia.nowMs() - asked.at < 3000) and asked.connector or noctalia.focusedOutputName()
  setStatus(nil)
  if not noctalia.commandExists("aocctl") then
    setStatus("aocctl isn't installed or isn't on PATH", true)
    render()
    return
  end
  loading = true
  render()
  opening += 1
  local this = opening
  lib.run({ "list" }, 15000, function(list, err)
    if this ~= opening then
      return
    end
    if list == nil then
      loading = false
      setStatus(`aocctl: {err}`, true)
      render()
      return
    end
    local found = lib.pickDisplay(list, wanted, true)
    if found == nil or (display and found.connector ~= display.connector) then
      settings, presets = {}, {}
    end
    display = found
    if found == nil then
      loading = false
      setStatus("No AOC monitor is connected", true)
    elseif not lib.reachable(found) then
      loading = false
      setStatus(`{lib.modelName(found)}: {found.status}`, true)
    else
      readAll()
    end
    render()
  end)
end

function onClose()
  drafts = {}
end
