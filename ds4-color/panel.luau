--!nonstrict
--!nocheck
--!nolint UnknownGlobal
local tr = noctalia.tr("ds4_color")
local SERVICE = "Hy4ri/ds4-color:service"

local function sendToService(event, payload)
  local cmd = "noctalia msg plugin " .. SERVICE .. " all " .. event
  if payload ~= nil then cmd = cmd .. " '" .. payload .. "'" end
  noctalia.runAsync(cmd, function() end)
end

local function currentColor()
  return noctalia.state.get("lastColor") or "990000"
end

local function render()
  local color = currentColor()
  local presets = noctalia.state.get("presets") or {}

  local presetRow = {}
  for i, p in ipairs(presets) do
    local selected = (p.hex:lower() == color:lower())
    table.insert(presetRow, ui.box({
      width = 34,
      height = 34,
      fill = "#" .. p.hex,
      radius = 8,
      border = "outline",
      borderWidth = selected and 3 or 1,
      onClick = "onPreset" .. i,
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
  sendToService("apply", "#" .. currentColor())
end

function onSave()
  sendToService("save", "#" .. currentColor())
end

function onSubmitHex(text)
  local hex = text:match("^#?(%x%x%x%x%x%x)$") or text:match("^0x(%x%x%x%x%x%x)$")
  if hex == nil then
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

-- Presets are a fixed list, so define one global handler per index at module
-- load (Noctalia's _G is read-only at runtime — no dynamic _G["onPreset"..i]
-- assignment, which throws "attempt to modify a readonly table" in onOpen).
local function applyPreset(i)
  local presets = noctalia.state.get("presets") or {}
  local p = presets[i]
  if p == nil then return end
  noctalia.state.set("lastColor", p.hex:upper())
  render()
end

function onPreset1() applyPreset(1) end
function onPreset2() applyPreset(2) end
function onPreset3() applyPreset(3) end
function onPreset4() applyPreset(4) end
function onPreset5() applyPreset(5) end
function onPreset6() applyPreset(6) end
function onPreset7() applyPreset(7) end
function onPreset8() applyPreset(8) end
function onPreset9() applyPreset(9) end

function onOpen(context)
  noctalia.state.watch("lastColor", function() render() end)
  render()
end
