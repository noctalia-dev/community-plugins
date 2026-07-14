
-- [[panel]] entry:
-- shows the last/current picked color with a button to
-- pick a new one, a history of the last colors, and
-- color fields with real-time editing.
--
-- No hyprpicker, no disk, no history mutation here -- that all lives in
-- service.luau. This script only reads noctalia.state and dispatches IPC
-- events to the service for anything that touches picking or persistence.
--!nocheck
--!nolint UnknownGlobal

--==============================================
-- CONSTANTS
--==============================================
local SERVICE = "oldirtty/color_picker:service"
local swatch_radius = noctalia.getConfig("swatch-radius")
local tr_color_picker = noctalia.tr("color_picker")

--==============================================
-- TRANSLATION HELPER
--==============================================
local function tr(key: string, subst: table?): string
  if subst then
    return noctalia.tr(key, subst)
  end
  return noctalia.tr(key)
end

--==============================================
-- COLOR CONVERSION
--==============================================

local function hexToRgb(hex: string)
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  return r, g, b
end

local function rgbToHsl(r: number, g: number, b: number)
  r, g, b = r / 255, g / 255, b / 255
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local h, s, l = 0, 0, (max + min) / 2

  if max ~= min then
    local d = max - min
    s = if l > 0.5 then d / (2 - max - min) else d / (max + min)
    if max == r then
      h = (g - b) / d + (if g < b then 6 else 0)
    elseif max == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end

  return math.floor(h * 360 + 0.5), math.floor(s * 100 + 0.5), math.floor(l * 100 + 0.5)
end

local function formatHex(hex: string, alpha: number): string
  if alpha < 1 then
    return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
  end
  return hex
end

local function formatRgb(hex: string, alpha: number): string
  local r, g, b = hexToRgb(hex)
  if alpha < 1 then
    return string.format("rgba(%d, %d, %d, %.2f)", r, g, b, alpha)
  end
  return string.format("rgb(%d, %d, %d)", r, g, b)
end

local function formatHsl(hex: string, alpha: number): string
  local r, g, b = hexToRgb(hex)
  local h, s, l = rgbToHsl(r, g, b)
  if alpha < 1 then
    return string.format("hsla(%d, %d%%, %d%%, %.2f)", h, s, l, alpha)
  end
  return string.format("hsl(%d, %d%%, %d%%)", h, s, l)
end

local function hexWithAlpha(hex: string, alpha: number): string
  if alpha >= 1 then
    return hex
  end
  return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
end

--==============================================
-- COLOR TEXT PARSING (field input -> hex)
--==============================================

local function parseRgbText(text: string): string?
  local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
  if r == nil then
    return nil
  end
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if r > 255 or g > 255 or b > 255 then
    return nil
  end
  return string.format("#%02x%02x%02x", r, g, b)
end

local function parseHslText(text: string): string?
  local h, s, l = text:match("^%s*(%d+)%s*,%s*(%d+)%%?%s*,%s*(%d+)%%?")
  if h == nil then
    return nil
  end
  h, s, l = tonumber(h), tonumber(s) / 100, tonumber(l) / 100

  local function hueToRgb(p: number, q: number, t: number): number
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1 / 6 then return p + (q - p) * 6 * t end
    if t < 1 / 2 then return q end
    if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
    return p
  end

  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = if l < 0.5 then l * (1 + s) else l + s - l * s
    local p = 2 * l - q
    local hn = h / 360
    r = hueToRgb(p, q, hn + 1 / 3)
    g = hueToRgb(p, q, hn)
    b = hueToRgb(p, q, hn - 1 / 3)
  end

  return string.format(
    "#%02x%02x%02x",
    math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5)
  )
end

local function parseHexText(text: string): string?
  local clean = text:match("^#?(%x%x%x%x%x%x)$")
  if clean == nil then
    return nil
  end
  return "#" .. clean
end

--==============================================
-- STATE (read-only view + pure-UI selection)
--
-- selectedColor / selectedOpacity / colorHistory all live in noctalia.state,
-- owned and mutated by service.luau. This panel only reads them for
-- rendering, except for pure-UI interactions (history swatch click, field
-- edit, opacity drag) that change the *selection* without picking or
-- persisting -- those are cheap enough to set directly here.
--==============================================

local function getSelectedColor(): string?
  return noctalia.state.get("selectedColor")
end

local function getSelectedOpacity(): number
  return tonumber(noctalia.state.get("selectedOpacity")) or 1
end

local function setSelected(hex: string, opacity: number)
  noctalia.state.set("selectedColor", hex)
  noctalia.state.set("selectedOpacity", opacity)
end

--==============================================
-- SERVICE DISPATCH
--==============================================

local function sendToService(event: string, payload: string?)
  local cmd = "noctalia msg plugin " .. SERVICE .. " all " .. event
  if payload ~= nil then
    cmd = cmd .. " " .. payload
  end
  noctalia.runAsync(cmd, function() end)
end

--==============================================
-- RENDERING
--==============================================

local function renderRecentItem(color: string, index: number)
  return ui.box({
    width = 32,
    height = 32,
    fill = color,
    radius = swatch_radius / 2.5,
    border = "outline",
    onClick = "onHistoryColorClicked" .. index,
  })
end

-- Recent-colors row: history positions 2..N. Position 1 is the selected
-- color, already shown by its own preview swatch.
local function renderRecent()
  local recent = noctalia.state.get("colorHistory") or {}

  if #recent <= 1 then
    return ui.label({ text = tr("no_history"), fontSize = 12, color = "muted" })
  end

  local items = {}
  for i = #recent, 2, -1 do
    table.insert(items, renderRecentItem(recent[i].hex, i))
  end

  return ui.row({ gap = 8, align = "center" }, items)
end

local function renderTitlebar()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({ text = tr("color_picker"), fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
    ui.button({ glyph = "color-picker", onClick = "onPickClickedFromPanel" }),
    ui.button({ glyph = "close", onClick = "onCloseClicked" }),
  })
end

local function renderColorspaceColumn(name: string, value: string, onSubmit: string, onCopy: string, keySuffix: string)
  local text_align = "left"
  if name ~= "HEX" then
    value = value:match("%((.-)%)")
    text_align = "center"
  end

  return ui.column({ gap = 4, flexGrow = 1 }, {
    ui.label({ text = name, fontSize = 14, color = "on_surface_variant" }),
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = name .. "-input-" .. keySuffix,
        value = value,
        textAlign = text_align,
        flexGrow = 1,
        onSubmit = onSubmit,
      }),
      ui.button({ glyph = "copy", variant = "ghost", onClick = onCopy }),
    }),
  })
end

local function render()
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

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    renderTitlebar(),

    ui.row({ gap = 12, align = "stretch" }, {
      ui.column({ gap = 8, flexGrow = 2 }, {
        ui.label({ text = tr("recent_colors"), fontSize = 14, color = "on_surface_variant" }),
        renderRecent(),
      }),
      ui.column({ gap = 8, flexGrow = 2 }, {
        ui.label({ text = tr("opacity"), fontSize = 14, color = "on_surface_variant" }),
        ui.slider({ min = 0, max = 1, step = 0.01, value = opacity, onChange = "onOpacityChange", onDragEnd = "onOpacityChange" }),
      }),
      -- Render current swatch
      ui.box({
        width = 128,
        height = 64,
        fill =  hexWithAlpha(current, opacity),
        radius = swatch_radius,
        border = "outline",
        borderWidth = 2,
        flexGrow = 1,
        onClick = "onNativePickerClicked"
      }),
    }),

    ui.row({ gap = 12 }, {
      renderColorspaceColumn("HEX", formatHex(current, opacity), "onSubmitHex", "onCopyHex", current .. "-" .. opacity),
      renderColorspaceColumn("RGB", formatRgb(current, opacity), "onSubmitRgb", "onCopyRgb", current .. "-" .. opacity),
      renderColorspaceColumn("HSL", formatHsl(current, opacity), "onSubmitHsl", "onCopyHsl", current .. "-" .. opacity),
    }),
  }))
end

--==============================================
-- CALLBACKS: history interaction (pure UI, no service call)
--==============================================

function handleHistoryClick(index: number)
  local history = noctalia.state.get("colorHistory") or {}
  local entry = history[index]
  if entry then
    setSelected(entry.hex, entry.opacity or 1)
    render()
  end
end

function onHistoryColorClicked2() handleHistoryClick(2) end
function onHistoryColorClicked3() handleHistoryClick(3) end
function onHistoryColorClicked4() handleHistoryClick(4) end
function onHistoryColorClicked5() handleHistoryClick(5) end
function onHistoryColorClicked6() handleHistoryClick(6) end
function onHistoryColorClicked7() handleHistoryClick(7) end

--==============================================
-- CALLBACKS: colorspace fields (pure UI, no service call)
--==============================================

local function processSubmit(parseText: (string) -> string?, text: string)
  local color_value = parseText(text)
  if color_value == nil then return end

  setSelected(color_value, getSelectedOpacity())
  render()
end

function onSubmitHex(text: string) processSubmit(parseHexText, text) end
function onSubmitRgb(text: string) processSubmit(parseRgbText, text) end
function onSubmitHsl(text: string) processSubmit(parseHslText, text) end

local function processCopy(format: (string, number) -> string)
  local current = getSelectedColor()
  if current == nil then return end

  local text = format(current, getSelectedOpacity())
  noctalia.copyToClipboard(text, "text/plain")
  noctalia.notify(tr_color_picker, tr("color_copied", { color = text }))
end

function onCopyHex() processCopy(formatHex) end
function onCopyRgb() processCopy(formatRgb) end
function onCopyHsl() processCopy(formatHsl) end

function onOpacityChange(value)
  local parsed = tonumber(value)
  if parsed == nil then return end

  noctalia.state.set("selectedOpacity", parsed)
  render()
end

--==============================================
-- CALLBACKS: picking (delegates to the service)
--==============================================

-- Panel's own pick button: asks the service to pick and update the
-- selection only. No history commit until the panel closes.
function onPickClickedFromPanel()
  sendToService("pick-panel")
end

function onNativePickerClicked()
  sendToService("picker-dialog")
end

function onCloseClicked()
  panel.close()
end

-- Panel closed (any path: close button, Esc, click outside). Commits
-- whatever is currently selected to the service's history.
function onClose()
  local hex = getSelectedColor()
  if hex == nil then return end

  local payload = hex .. ":" .. tostring(getSelectedOpacity())
  sendToService("commit", payload)
end

function onOpen(context)
  noctalia.state.watch("selectedColor", function() render() end)
  noctalia.state.watch("colorHistory", function() render() end)
  render()
end