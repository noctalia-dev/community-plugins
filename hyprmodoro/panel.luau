local util = require("./lib/util.luau")

local transport = "UNKNOWN"
local controllable = false
local state = "STOPPED"
local phase = "IDLE"
local paused = false
local time = "--:--"
local progress = 0
local round = 0
local work, rest = 25, 5

local presets = {}
local inputWork, inputRest = "25", "5"
local inputKey = 0
local notice = ""
local isOpen = false

local PHASE_COLOR = { IDLE = "on_surface_variant", WORK = "primary", REST = "tertiary", WAITING = "warning" }

local function isLive() return state == "WORKING" or state == "RESTING" end
local function isWaiting() return state == "WAITING_FOR_REST" or state == "WAITING_FOR_WORK" end
local function isIdle() return state == "STOPPED" or state == "FINISHED" end
local function send(cmd)
  if not controllable then return end
  noctalia.state.set("hm.cmd", cmd)
end

local render

local function header()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({
      text = noctalia.tr("title"),
      fontSize = 15,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", onClick = "onOpenSettings" }),
    ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
  })
end

local function readout()
  local color = paused and "on_surface/0.5" or (PHASE_COLOR[phase] or PHASE_COLOR.IDLE)

  local caption = noctalia.tr("phase." .. phase:lower())
  if paused then
    caption = caption .. " · " .. noctalia.tr("ui.paused")
  elseif round > 0 and isLive() then
    caption = caption .. " · " .. noctalia.tr("ui.round", { n = round })
  end

  return ui.column({ gap = 6, align = "center" }, {
    ui.label({
      text = isIdle() and string.format("%d:00", work) or time,
      fontSize = 38,
      fontWeight = "bold",
      color = color,
    }),
    ui.label({ text = caption, fontSize = 12, color = "on_surface_variant" }),
    ui.progress({
      progress = isIdle() and 0 or math.max(0, math.min(1, 1 - progress)),
      fill = color,
      width = 280,
      height = 6,
      radius = 3,
    }),
  })
end

local function transportRow()
  local primaryText, primaryVariant
  if isLive() and not paused then
    primaryText, primaryVariant = noctalia.tr("ui.pause"), "secondary"
  elseif paused then
    primaryText, primaryVariant = noctalia.tr("ui.resume"), "primary"
  else
    primaryText, primaryVariant = noctalia.tr("ui.start"), "primary"
  end

  return ui.row({ gap = 8, justify = "center" }, {
    ui.button({ text = primaryText, variant = primaryVariant, onClick = "onPrimary" }),
    ui.button({
      text = noctalia.tr("ui.reset"),
      variant = "outline",
      onClick = "onReset",
    }),
    ui.button({
      text = noctalia.tr("ui.stop"),
      variant = "destructive",
      onClick = "onStop",
      enabled = not isIdle(),
    }),
  })
end

local function phaseRow()
  local canSwitch = isLive() or isWaiting()
  return ui.row({ gap = 8, justify = "center" }, {
    ui.button({
      text = noctalia.tr("ui.work"),
      variant = phase == "WORK" and "primary" or "ghost",
      controlSize = "sm",
      onClick = "onToWork",
      enabled = canSwitch and phase ~= "WORK",
    }),
    ui.button({
      text = noctalia.tr("ui.rest"),
      variant = phase == "REST" and "primary" or "ghost",
      controlSize = "sm",
      onClick = "onToRest",
      enabled = canSwitch and phase ~= "REST",
    }),
  })
end

local function presetRow()
  if #presets == 0 then
    return ui.label({ text = noctalia.tr("ui.no_presets"), fontSize = 12, color = "on_surface_variant" })
  end

  local buttons = {}
  for index, preset in ipairs(presets) do
    local active = preset.work == work and preset.rest == rest
    table.insert(buttons, ui.button({
      text = string.format("%d/%d", preset.work, preset.rest),
      variant = active and "primary" or "outline",
      controlSize = "sm",
      onClick = function()
        send(string.format("PRESET:%d/%d", preset.work, preset.rest))
      end,
    }))
    if index >= 6 then break end
  end

  return ui.row({ gap = 6, justify = "center" }, buttons)
end

local function customRow()
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({ text = noctalia.tr("ui.work"), fontSize = 12, color = "on_surface_variant" }),
    ui.input({
      key = "w-" .. inputKey,
      value = inputWork,
      fontSize = 13,
      onChange = "onWorkChange",
      onSubmit = "onCustomSubmit",
    }),
    ui.label({ text = noctalia.tr("ui.rest"), fontSize = 12, color = "on_surface_variant" }),
    ui.input({
      key = "r-" .. inputKey,
      value = inputRest,
      fontSize = 13,
      onChange = "onRestChange",
      onSubmit = "onCustomSubmit",
    }),
    ui.button({ text = noctalia.tr("ui.set"), variant = "primary", controlSize = "sm", onClick = "onCustomSubmit" }),
  })
end

local function configRow()
  return ui.row({ gap = 6, justify = "center" }, {
    ui.button({
      text = noctalia.tr("ui.link_config"),
      variant = "ghost",
      controlSize = "sm",
      onClick = "onLink",
    }),
    ui.button({
      text = noctalia.tr("ui.save_now"),
      variant = "ghost",
      controlSize = "sm",
      onClick = "onSaveNow",
    }),
  })
end

local function section(title, control)
  return ui.column({ gap = 6, align = "stretch" }, {
    ui.label({ text = title, fontSize = 11, fontWeight = "medium", color = "on_surface_variant" }),
    control,
  })
end

local function blockedBody()
  local title, body, action
  if transport == "UNKNOWN" then
    title, body = noctalia.tr("ui.checking"), noctalia.tr("ui.checking_body")
    action = ui.button({ text = noctalia.tr("ui.recheck"), variant = "outline", onClick = "onProbe" })
    return ui.column({ gap = 10, align = "stretch" }, {
      ui.label({ text = title, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = body, fontSize = 12, color = "on_surface_variant" }),
      action,
    })
  elseif transport == "ABSENT" then
    title, body = noctalia.tr("err.absent_title"), noctalia.tr("err.absent_body")
    action = ui.button({ text = noctalia.tr("ui.recheck"), variant = "primary", onClick = "onProbe" })
  else
    title, body = noctalia.tr("err.readonly_title"), noctalia.tr("err.readonly_body")
    action = ui.button({ text = noctalia.tr("ui.copy_patch"), variant = "outline", onClick = "onCopyPatch" })
  end

  return ui.column({ gap = 10, align = "stretch" }, {
    ui.label({ text = title, fontWeight = "bold", color = "error" }),
    ui.label({ text = body, fontSize = 12, color = "on_surface_variant" }),
    action,
  })
end

render = function()

  if not isOpen then return end

  local rows = { header() }

  if not controllable then
    if transport ~= "ABSENT" then table.insert(rows, readout()) end
    table.insert(rows, blockedBody())
  else
    table.insert(rows, readout())
    table.insert(rows, transportRow())
    table.insert(rows, phaseRow())
    table.insert(rows, ui.separator({}))
    table.insert(rows, section(noctalia.tr("ui.presets"), presetRow()))
    table.insert(rows, section(noctalia.tr("ui.custom"), customRow()))
  end

  table.insert(rows, ui.separator({}))
  table.insert(rows, configRow())

  if notice ~= "" then
    table.insert(rows, ui.label({ text = notice, fontSize = 11, color = "on_surface_variant" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, rows))
end

local function seed()
  transport = noctalia.state.get("hm.transport") or "UNKNOWN"
  controllable = noctalia.state.get("hm.controllable") == true
  state = noctalia.state.get("hm.state") or "STOPPED"
  phase = noctalia.state.get("hm.phase") or "IDLE"
  paused = noctalia.state.get("hm.paused") == true
  time = noctalia.state.get("hm.time") or "--:--"
  progress = tonumber(noctalia.state.get("hm.progress")) or 0
  round = tonumber(noctalia.state.get("hm.round")) or 0
  work = tonumber(noctalia.state.get("hm.work")) or 25
  rest = tonumber(noctalia.state.get("hm.rest")) or 5
end

function onOpen(_context)
  isOpen = true
  seed()
  presets = util.parsePresets(noctalia.getConfig("presets"), 6)
  inputWork, inputRest = tostring(work), tostring(rest)
  inputKey = inputKey + 1
  notice = ""
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
end

noctalia.state.watch("hm.transport", function(v) transport = v or "UNKNOWN"; render() end)
noctalia.state.watch("hm.controllable", function(v) controllable = v == true; render() end)
noctalia.state.watch("hm.state", function(v) state = v or "STOPPED"; render() end)
noctalia.state.watch("hm.phase", function(v) phase = v or "IDLE"; render() end)
noctalia.state.watch("hm.paused", function(v) paused = v == true; render() end)
noctalia.state.watch("hm.time", function(v) time = v or "--:--"; render() end)
noctalia.state.watch("hm.progress", function(v) progress = tonumber(v) or 0; render() end)
noctalia.state.watch("hm.round", function(v) round = tonumber(v) or 0; render() end)
noctalia.state.watch("hm.work", function(v) work = tonumber(v) or work; render() end)
noctalia.state.watch("hm.rest", function(v) rest = tonumber(v) or rest; render() end)
noctalia.state.watch("hm.link_result", function(v)
  if type(v) == "string" and v ~= "" then
    notice = v
    render()
  end
end)
noctalia.state.watch("hm.error", function(v)
  notice = (type(v) == "string" and v ~= "") and v or ""
  render()
end)

function onPrimary()
  send((isLive() and not paused) and "PAUSE" or "START")
end

function onReset() send("RESET") end
function onStop() send("STOP") end
function onToWork() send("TO_WORK") end
function onToRest() send("TO_REST") end
function onProbe() noctalia.state.set("hm.cmd", "PROBE") end
function onOpenSettings() noctalia.openSettings() end
function onCloseClicked() panel.close() end

function onWorkChange(value) inputWork = value end
function onRestChange(value) inputRest = value end

function onCustomSubmit()
  local w = tonumber((inputWork or ""):match("%d+"))
  local r = tonumber((inputRest or ""):match("%d+"))
  if w == nil or r == nil or w < 1 or w > 180 or r < 1 or r > 60 then
    notice = noctalia.tr("err.bad_duration")
    render()
    return
  end
  notice = ""
  send(string.format("PRESET:%d/%d", w, r))
end

function onLink()
  noctalia.state.set("hm.link_request", true)
end

function onSaveNow()
  noctalia.state.set("hm.save_request", true)
  notice = noctalia.tr("ui.saving")
  render()
end

function onCopyPatch()
  noctalia.copyToClipboard(noctalia.tr("ui.patch_hint"), "text/plain")
  notice = noctalia.tr("ui.copied")
  render()
end
