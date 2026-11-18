--!nonstrict

local SERVICE = "oldirtty/color_picker:service"
local color = require("./color.luau")
local SWATCH_SIZE = 32

local showCloseBtn = true
local waitingForPanelPick = false
local initialSessionColor = nil
local initialSessionOpacity = 1
local initialChanged = false

local render
local colorspaces

local function tr(key, subst)
  if subst then
    return noctalia.tr(key, subst)
  end
  return noctalia.tr(key)
end

local function customNotify(title: string, body: string?)
  if noctalia.getConfig("notify-on-copy") == false then
    return
  end
  noctalia.notify(title, body)
end

local function sendToService(event, payload)
  local cmd = "noctalia msg plugin " .. SERVICE .. " all " .. event
  if payload ~= nil then
    cmd = cmd .. " '" .. payload .. "'"
  end
  noctalia.runAsync(cmd, function() end)
end

local function commitInitialColorIfFirstChange(newHex)
  if initialChanged then
    return
  end
  if initialSessionColor == nil then
    return
  end
  if newHex == nil or newHex == initialSessionColor then
    return
  end

  initialChanged = true
  local payload = initialSessionColor .. ":" .. tostring(initialSessionOpacity)
  sendToService("push-to-history", payload)
end

local function getSelectedColor()
  return noctalia.state.get("selectedColor")
end

local function getSelectedOpacity()
  return tonumber(noctalia.state.get("selectedOpacity")) or 1
end

local function setSelected(hex, opacity)
  commitInitialColorIfFirstChange(hex)
  noctalia.state.set("selectedColor", hex)
  noctalia.state.set("selectedOpacity", tonumber(opacity) or 1)
  render()
end

--==============================================
-- BASE UI COMPONENTS
--==============================================

local function getSystemRadius(): number
  local setting = noctalia.getSetting("shell.corner_radius_scale")
  local factor = (setting ~= nil) and tonumber(setting) or 1.0
  return math.floor(8 * factor + 0.5)
end

local function renderTitlebar()
  local header = {
    ui.label({ text = tr("color_picker"), fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
  }
  if showCloseBtn then
    table.insert(header, ui.button({ glyph = "close", onClick = "onCloseClicked" }))
  end
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, header)
end

local function renderRecentItem(colorHex: string, index: number)
  local is_circular = noctalia.getConfig("circular-swatch")
  local radius: number = is_circular and 9999 or getSystemRadius()

  return ui.box({
    width = SWATCH_SIZE,
    height = SWATCH_SIZE,
    fill = colorHex,
    radius = radius,
    border = "outline_variant",
    onClick = function()
      handleHistoryClick(index)
    end,
  })
end

function renderRecent()
  local recent = noctalia.state.get("colorHistory") or {}
  if #recent == 0 then
    return ui.label({ text = tr("no_history"), fontSize = 12, color = "muted" })
  end

  local items = {}
  for i = 1, #recent do
    table.insert(items, renderRecentItem(recent[i].hex, i))
  end
  return ui.row({ gap = 6, align = "center" }, items)
end

local function renderParamPart(labelStr, valStr, keyStr, submitFunc, flexRatio)
  return ui.row({ gap = 4, align = "center", flexGrow = flexRatio or 1 }, {
    ui.label({ text = labelStr, fontSize = 12, color = "on_surface_variant" }),
    ui.input({
      key = keyStr,
      value = valStr,
      flexGrow = 1,
      onSubmit = submitFunc,
    }),
  })
end

local function renderColorspaceColumn(name: string, value, onSubmit, onCopy, keySuffix)
  return ui.column({ gap = 4, flexGrow = 1 }, {
    ui.label({ text = name, fontSize = 14, color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = name .. "-input-" .. keySuffix,
        value = value:match("%((.-)%)") or value,
        flexGrow = 1,
        onSubmit = onSubmit,
      }),
      ui.button({ glyph = "copy", variant = "ghost", controlSize = "md", onClick = onCopy }),
    }),
  })
end

local function buildColorspaceRow(inputs, copyAction, isPrimary)
  local children = {}
  for _, input in ipairs(inputs) do
    table.insert(children, input)
  end

  if isPrimary then
    table.insert(
      children,
      ui.button({ glyph = "color-picker", variant = "default", controlSize = "md", onClick = "onPickClickedFromPanel" })
    )
    table.insert(children, ui.button({ glyph = "copy", variant = "primary", controlSize = "md", onClick = copyAction }))
  else
    table.insert(children, ui.button({ glyph = "copy", variant = "ghost", onClick = copyAction }))
  end

  return ui.row({ gap = 8, align = "center", flexGrow = 1 }, children)
end

local function previewSwatch(current, opacity)
  local radius = getSystemRadius()

  -- ui.* has no layering: solid color underneath, checkerboard on top fading with (1 - alpha),
  -- which blends to alpha * color + (1 - alpha) * checker, same as the picker's alpha strip.
  return ui.row({
    width = 42,
    height = 42,
    padding = 1,
    radius = radius,
    fill = current,
    border = "outline_variant",
  }, {
    ui.image({
      path = "assets/checker.svg",
      width = 40,
      height = 40,
      radius = math.max(radius - 1, 0),
      opacity = 1 - opacity,
    }),
  })
end

--==============================================
-- COLORSPACES (OBJECTS)
--==============================================

local function processCopy(formatFunc)
  local current = getSelectedColor()
  if current == nil then
    return
  end
  local text = formatFunc(current, getSelectedOpacity())
  noctalia.copyToClipboard(text, "text/plain;charset=utf-8")
  customNotify(tr("color_picker"), tr("color_copied", { color = text }))
end

colorspaces = {
  hex = {
    submit = function(text: string)
      local hex_val, alpha_val = color.parseHexText(text)
      if hex_val then
        setSelected(hex_val, alpha_val or 1)
        render()
      end
    end,
    copy = function()
      processCopy(color.formatHex)
    end,
    render = function(current, opacity, keySuffix, isPrimary)
      if isPrimary then
        local inputs = {
          ui.input({
            key = "HEX-input-" .. keySuffix,
            value = color.formatHex(current, opacity),
            flexGrow = 2,
            onSubmit = "onSubmitHex",
          }),
          renderParamPart(
            "A",
            tostring(math.floor(opacity * 100 + 0.5)) .. "%",
            "A-hex-" .. keySuffix,
            "onOpacityInputSubmit",
            1.25
          ),
        }
        local row = buildColorspaceRow(inputs, "onCopyHex", true)

        return ui.row({ gap = 8, align = "center" }, {
          previewSwatch(current, opacity),
          row,
        })
      else
        return renderColorspaceColumn("HEX", color.formatHex(current, opacity), "onSubmitHex", "onCopyHex", keySuffix)
      end
    end,
  },
  rgb = {
    submit = function(text: string)
      local hex_val, alpha_val = color.parseRgbText(text)
      if hex_val then
        setSelected(hex_val, alpha_val or 1)
        render()
      end
    end,
    submitParts = function(part, newValue)
      local current = getSelectedColor()
      if not current then
        return
      end
      local r, g, b = color.hexToRgb(current)

      local num = tonumber(newValue)
      if not num or num > 255 or num < 0 then
        return
      end

      if part == "R" then
        r = num
      elseif part == "G" then
        g = num
      elseif part == "B" then
        b = num
      end

      local newHex = string.format("#%02X%02X%02X", r, g, b)
      setSelected(newHex, getSelectedOpacity())
    end,
    copy = function()
      processCopy(color.formatRgb)
    end,
    render = function(current, opacity, keySuffix, isPrimary)
      if isPrimary then
        local r, g, b = color.hexToRgb(current)
        local a = tostring(math.floor(opacity * 100 + 0.5)) .. "%"
        local inputs = {
          renderParamPart("R", tostring(r), "R-" .. keySuffix, "onSubmitRgbR"),
          renderParamPart("G", tostring(g), "G-" .. keySuffix, "onSubmitRgbG"),
          renderParamPart("B", tostring(b), "B-" .. keySuffix, "onSubmitRgbB"),
          renderParamPart("A", a, "A-rgb-" .. keySuffix, "onOpacityInputSubmit", 1.25),
        }
        local row = buildColorspaceRow(inputs, "onCopyRgb", true)

        return ui.row({ gap = 8, align = "center" }, {
          previewSwatch(current, opacity),
          row,
        })
      else
        return renderColorspaceColumn(
          "RGB(A)",
          color.formatRgb(current, opacity),
          "onSubmitRgb",
          "onCopyRgb",
          keySuffix
        )
      end
    end,
  },
  hsl = {
    submit = function(text: string)
      local hex_val, alpha_val = color.parseHslText(text)
      if hex_val then
        setSelected(hex_val, alpha_val or 1)
        render()
      end
    end,
    submitParts = function(part, newValue)
      local current = getSelectedColor()
      if not current then
        return
      end
      local r, g, b = color.hexToRgb(current)
      local h, s, l = color.rgbToHsl(r, g, b)

      local num = tonumber(newValue:match("%d+"))
      if not num or num < 0 then
        return
      end

      if part == "H" then
        h = math.min(num, 360)
      elseif part == "S" then
        s = math.min(num, 100)
      elseif part == "L" then
        l = math.min(num, 100)
      end

      local combined = string.format("%d,%d,%d", h, s, l)
      colorspaces.hsl.submit(combined)
    end,
    copy = function()
      processCopy(color.formatHsl)
    end,
    render = function(current, opacity, keySuffix, isPrimary)
      if isPrimary then
        local r, g, b = color.hexToRgb(current)
        local h, s, l = color.rgbToHsl(r, g, b)
        local a = tostring(math.floor(opacity * 100 + 0.5)) .. "%"
        local inputs = {
          renderParamPart("H", tostring(h), "H-" .. keySuffix, "onSubmitHslH"),
          renderParamPart("S", tostring(s), "S-" .. keySuffix, "onSubmitHslS"),
          renderParamPart("L", tostring(l), "L-" .. keySuffix, "onSubmitHslL"),
          renderParamPart("A", a, "A-hsl-" .. keySuffix, "onOpacityInputSubmit", 1.25),
        }
        local row = buildColorspaceRow(inputs, "onCopyHsl", true)

        return ui.row({ gap = 8, align = "center" }, {
          previewSwatch(current, opacity),
          row,
        })
      else
        return renderColorspaceColumn(
          "HSL(A)",
          color.formatHsl(current, opacity),
          "onSubmitHsl",
          "onCopyHsl",
          keySuffix
        )
      end
    end,
  },
}

--==============================================
-- GLOBAL ACTION ROUTERS
--==============================================

function onSubmitHex(text: string)
  colorspaces.hex.submit(text)
end
function onSubmitRgb(text: string)
  colorspaces.rgb.submit(text)
end
function onSubmitHsl(text: string)
  colorspaces.hsl.submit(text)
end

function onSubmitRgbR(val)
  colorspaces.rgb.submitParts("R", val)
end
function onSubmitRgbG(val)
  colorspaces.rgb.submitParts("G", val)
end
function onSubmitRgbB(val)
  colorspaces.rgb.submitParts("B", val)
end

function onSubmitHslH(val)
  colorspaces.hsl.submitParts("H", val)
end
function onSubmitHslS(val)
  colorspaces.hsl.submitParts("S", val)
end
function onSubmitHslL(val)
  colorspaces.hsl.submitParts("L", val)
end

function onCopyHex()
  colorspaces.hex.copy()
end
function onCopyRgb()
  colorspaces.rgb.copy()
end
function onCopyHsl()
  colorspaces.hsl.copy()
end

function onOpacityInputSubmit(opacityStr)
  local val = tonumber(opacityStr:match("%d+"))
  if not val then
    return
  end
  local opacity = math.min(math.max(val / 100, 0), 1)
  noctalia.state.set("selectedOpacity", opacity)
  render()
end

--==============================================
-- MAIN PANEL LOGIC
--==============================================

function render()
  local current = getSelectedColor()
  local opacity = getSelectedOpacity()

  if current == nil then
    panel.render(ui.column({ gap = 12, padding = 16 }, {
      renderTitlebar(),
      ui.label({ text = tr("no_color_picked"), padding = { top = 8 } }),
      renderRecent(),
    }))
    return
  end

  local function applyPickerColor(colorStr, commit)
    local hex = colorStr:sub(1, 7)
    local alpha = 1
    if #colorStr == 9 then
      alpha = (tonumber(colorStr:sub(8, 9), 16) or 255) / 255
    end

    if commit then
      setSelected(hex, alpha)
    else
      noctalia.state.set("selectedOpacity", alpha)
      noctalia.state.set("selectedColor", hex)
    end
    render()
  end

  local keySuffix = current .. "-" .. opacity
  local primaryKey = noctalia.getConfig("main-colorspace") or "hex"
  local primaryObj = colorspaces[primaryKey] or colorspaces.hex

  local secondaryKeys = {}
  for _, k in ipairs({ "hex", "rgb", "hsl" }) do
    if k ~= primaryKey then
      table.insert(secondaryKeys, k)
    end
  end

  panel.render(ui.column({ gap = 12 }, {
    renderTitlebar(),

    ui.colorPicker({
      width = 380,
      value = color.formatHex(current, opacity),
      alpha = true,
      inputs = "none",
      onChange = function(c)
        applyPickerColor(c, false)
      end,
      onChangeEnd = function(c)
        applyPickerColor(c, true)
      end,
    }),

    primaryObj.render(current, opacity, keySuffix, true),

    renderRecent(),

    ui.row({ gap = 12 }, {
      colorspaces[secondaryKeys[1]].render(current, opacity, keySuffix, false),
      colorspaces[secondaryKeys[2]].render(current, opacity, keySuffix, false),
    }),
  }))
end

function handleHistoryClick(index: number)
  local history = noctalia.state.get("colorHistory") or {}
  local entry = history[index]
  if entry then
    setSelected(entry.hex, entry.opacity or 1)
  end
end

function onPickClickedFromPanel()
  waitingForPanelPick = true
  panel.close()
end

function onCloseClicked()
  panel.close()
end

function onClose()
  if waitingForPanelPick then
    sendToService("pick-panel")
    return
  end
  sendToService("save-selected")
end

function onOpen(context)
  showCloseBtn = noctalia.getSetting("shell.show_close_buttons")
  initialChanged = false
  initialSessionColor = getSelectedColor()
  initialSessionOpacity = getSelectedOpacity()

  noctalia.state.watch("selectedColor", function(newHex)
    if waitingForPanelPick then
      waitingForPanelPick = false
      noctalia.togglePanel("oldirtty/color_picker:panel")
      return
    end
    commitInitialColorIfFirstChange(newHex)
    render()
  end)

  noctalia.state.watch("colorHistory", function()
    render()
  end)
  render()
end
