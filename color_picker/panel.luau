
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
-- CONTROL VARIABLES
--==============================================
local waitingForPanelPick = false
local initialSessionColor = nil
local initialSessionOpacity = 1
local initialChanged = false

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
-- SERVICE DISPATCH
--==============================================

local function sendToService(event: string, payload: string?)
  local cmd = "noctalia msg plugin " .. SERVICE .. " all " .. event
  if payload ~= nil then
    cmd = cmd .. " '" .. payload .. "'"
  end
  noctalia.runAsync(cmd, function() end)
end

local function commitInitialColorIfFirstChange(newHex: string?)
    if initialChanged then return end
    if initialSessionColor == nil then return end
    if newHex == nil or newHex == initialSessionColor then return end

    initialChanged = true
    local payload = initialSessionColor .. ":" .. tostring(initialSessionOpacity)
    -- noctalia.notify("DEBUG", "Push initial color = ".. initialSessionColor .. "\nOpacity = " .. initialSessionOpacity)
    sendToService("push-to-history", payload)
end

--==============================================
-- STATE (read-only view + pure-UI selection)
-- These states are synced and persisted to disk by the service on close.
--==============================================

local function getSelectedColor(): string?
    return noctalia.state.get("selectedColor")
end

local function getSelectedOpacity(): number
    return tonumber(noctalia.state.get("selectedOpacity")) or 1
end

local function setSelected(hex: string, opacity: number)
    commitInitialColorIfFirstChange(hex)
    noctalia.state.set("selectedColor", hex)
    noctalia.state.set("selectedOpacity", opacity)
end

--==============================================
-- RENDERING
--==============================================

local function renderTitlebar()
    return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.label({ text = tr("color_picker"), fontSize = 18, fontWeight = "bold", color = "primary", flexGrow = 1 }),
        ui.button({ glyph = "color-picker", onClick = "onPickClickedFromPanel" }),
        ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    })
end

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

-- Recent-colors row
function renderRecent()
    local recent = noctalia.state.get("colorHistory") or {}

    if #recent == 0 then
        return ui.label({ text = tr("no_history"), fontSize = 12, color = "muted" })
    end

    local items = {}
    for i = #recent, 1, -1 do
        table.insert(items, renderRecentItem(recent[i].hex, i))
    end

    return ui.row({ gap = 8, align = "center" }, items)
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
        ui.slider({ min = 0, max = 1, step = 0.01, value = opacity, onChange = "onOpacityChange", onDragEnd = "onOpacityDragEnd" }),
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

function onHistoryColorClicked1() handleHistoryClick(1) end
function onHistoryColorClicked2() handleHistoryClick(2) end
function onHistoryColorClicked3() handleHistoryClick(3) end
function onHistoryColorClicked4() handleHistoryClick(4) end
function onHistoryColorClicked5() handleHistoryClick(5) end
function onHistoryColorClicked6() handleHistoryClick(6) end

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

function onOpacityDragEnd(value)
    local parsed = tonumber(value)
    if parsed == nil then return end

    local currentHex = getSelectedColor()
    if currentHex then
        setSelected(currentHex, parsed)
    end
end

--==============================================
-- CALLBACKS: picking (delegates to the service)
--==============================================

-- Panel's own pick button: just closes the panel (so it doesn't cover the
-- area being sampled). The actual pick is triggered from onClose(), which
-- only fires once the close animation has actually finished -- firing the
-- pick here instead would race the animation and hyprpicker would freeze
-- mid-transition.
function onPickClickedFromPanel()
	waitingForPanelPick = true
	panel.close()
end

function onNativePickerClicked()
  sendToService("picker-dialog")
end

function onCloseClicked()
  panel.close()
end

-- Panel closed. Two cases:
-- - Technical close to hand off to hyprpicker (waitingForPanelPick): ask
--   the service to pick now that the close animation is done, then wait
--   for the selectedColor watch to reopen the panel.
--
-- - Real close (close button, Esc, click outside): save whatever is
--   currently selected to the service's SELECTED_FILE.
function onClose()
	if waitingForPanelPick then
		sendToService("pick-panel")
		return
	end
	sendToService("save-selected")
end

function onOpen(context)
    initialChanged = false
    initialSessionColor = getSelectedColor()
    initialSessionOpacity = getSelectedOpacity()

    noctalia.state.watch("selectedColor", function(newHex: string?)
        if waitingForPanelPick then
        waitingForPanelPick = false
        noctalia.togglePanel("oldirtty/color_picker:panel")
        return
        end

        -- Covers changes the service made directly (panel pick button, native
        -- picker dialog), which bypass this panel's setSelected().
        commitInitialColorIfFirstChange(newHex)

        render()
    end)

    noctalia.state.watch("colorHistory", function()
        render()
    end)

    render()
end
