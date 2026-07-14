--!nonstrict
--!nocheck
--!nolint UnknownGlobal
local tr = noctalia.tr("ds4_color")
local SERVICE = "hy4ri/ds4-color:service"

-- Validate a color is exactly 6 hex chars (no metachars / quote-breakers can
-- survive this, so it is safe to interpolate into the runAsync shell string).
local function isHex6(s)
  return type(s) == "string" and s:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") ~= nil
end

local function sendToService(event, payload)
  local cmd = "noctalia msg plugin " .. SERVICE .. " all " .. event
  if payload ~= nil then cmd = cmd .. " '" .. payload .. "'" end
  noctalia.runAsync(cmd, function() end)
end

local function currentColor()
  return noctalia.state.get("lastColor") or "990000"
end

local applyPreset

local function render()
  local color = currentColor()
  local presets = noctalia.state.get("presets") or {}

  local presetRow = {}
  for i, p in ipairs(presets) do
    local presetIndex = i
    local selected = (p.hex:lower() == color:lower())
    table.insert(presetRow, ui.box({
      width = 34,
      height = 34,
      fill = "#" .. p.hex,
      radius = 8,
      border = "outline",
      borderWidth = selected and 3 or 1,
      onClick = function() applyPreset(presetIndex) end,
    }))
  end

  panel.render(ui.column({ gap = 10, padding = 12 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr, fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    }),

    -- Live swatch preview
    ui.box({
      width = 200,
      height = 72,
      fill = "#" .. color,
      radius = 12,
      border = "outline",
      borderWidth = 2,
      onClick = "onNativePicker",
    }),

    -- Hex field + native picker button
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "hex-input",
        value = "#" .. color,
        flexGrow = 1,
        onSubmit = "onSubmitHex",
      }),
      ui.button({ glyph = "color-picker", variant = "ghost", onClick = "onNativePicker" }),
    }),

    ui.label({ text = noctalia.tr("presets"), fontSize = 13, color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, presetRow),

    ui.row({ gap = 8 }, {
      ui.button({
        text = noctalia.tr("save"),
        variant = "ghost",
        onClick = "onSave",
        flexGrow = 1,
      }),
      ui.button({
        text = noctalia.tr("apply"),
        variant = "primary",
        onClick = "onApply",
        flexGrow = 1,
      }),
    }),
  }))
end

--==== callbacks ====
function onApply()
  local c = currentColor()
  if isHex6(c) then sendToService("apply", c) end
end

function onSave()
  local c = currentColor()
  if isHex6(c) then sendToService("save", c) end
end

function onSubmitHex(text)
  local hex = text:match("^#?([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
    or text:match("^0x([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])$")
  if hex == nil or not isHex6(hex) then
    noctalia.notifyError(tr, noctalia.tr("bad_color"))
    return
  end
  noctalia.state.set("lastColor", hex:upper())
  render()
end

function onNativePicker()
  noctalia.openColorPicker("#" .. currentColor(), function(color)
    if color == nil then return end
    local hex = color:match("#?(%x%x%x%x%x%x)")
    if hex ~= nil then
      noctalia.state.set("lastColor", hex:upper())
      render()
    end
  end)
end

function onCloseClicked()
  panel.close()
end

function onClose()
end

applyPreset = function(i)
  local presets = noctalia.state.get("presets") or {}
  local p = presets[i]
  if p == nil then return end
  noctalia.state.set("lastColor", p.hex:upper())
  render()
end

function onOpen(context)
  noctalia.state.watch("lastColor", function() render() end)
  render()
end
