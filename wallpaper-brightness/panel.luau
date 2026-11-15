--!nonstrict
-- Wallpaper Brightness interactive control panel

local i18n = require("./i18n.luau")

local MIN_BRIGHTNESS = 10
local MAX_BRIGHTNESS = 150
local STEP_BRIGHTNESS = 5

local function clampBrightness(val)
  local n = tonumber(val) or 100
  n = math.floor((n + (STEP_BRIGHTNESS / 2)) / STEP_BRIGHTNESS) * STEP_BRIGHTNESS
  if n < MIN_BRIGHTNESS then
    return MIN_BRIGHTNESS
  end
  if n > MAX_BRIGHTNESS then
    return MAX_BRIGHTNESS
  end
  return n
end

local brightness = clampBrightness(noctalia.state.get("brightness") or noctalia.getConfig("brightness") or 100)
local isBusy = (noctalia.state.get("busy") == "true")

local render

local function sendBrightness(val)
  local clamped = clampBrightness(val)
  brightness = clamped
  noctalia.state.set("brightness", tostring(clamped))
  noctalia.state.set("cmd", "SET:" .. tostring(clamped))
  render()
end

function onSliderChange(val)
  sendBrightness(val)
end

function onKey(key)
  if key == "Escape" or key == "escape" then
    panel.close()
  end
end

local function presetButton(pct)
  local active = (brightness == pct)
  return ui.button({
    key = "preset_" .. tostring(pct),
    text = tostring(pct) .. "%",
    variant = active and "primary" or "outline",
    controlSize = "sm",
    flexGrow = 1,
    onClick = function()
      sendBrightness(pct)
    end,
  })
end

render = function()
  panel.render(
    ui.column({
      key = "root_col",
      padding = 12,
      gap = 8,
      align = "stretch",
      justify = "start",
    }, {
      -- Header row: Title on the left, percentage badge on the right
      ui.row({
        key = "header_row",
        gap = 8,
        padding = 0,
        align = "center",
        justify = "space_between",
      }, {
        ui.row({
          key = "title_group",
          gap = 8,
          padding = 0,
          align = "center",
        }, {
          ui.glyph({
            name = "sun",
            size = 18,
            color = "primary",
          }),
          ui.label({
            key = "title_label",
            text = i18n.tr("panel.title"),
            fontSize = 15,
            fontWeight = "bold",
            color = "on_surface",
          }),
        }),
        ui.label({
          key = "value_badge",
          text = tostring(brightness) .. "%",
          fontSize = 13,
          fontWeight = "bold",
          color = "primary",
        }),
      }),

      -- Subtitle / Status row: spans full available horizontal width
      -- Replaces the description while applying changes so nothing overlaps or clips
      ui.row({
        key = "subtitle_row",
        gap = 6,
        padding = 0,
        align = "center",
      }, isBusy and {
        ui.glyph({
          name = "arrow-path",
          size = 12,
          color = "primary",
        }),
        ui.label({
          key = "status_busy_label",
          text = i18n.tr("panel.applying"),
          fontSize = 12,
          fontWeight = "bold",
          color = "primary",
        }),
      } or {
        ui.label({
          key = "subtitle_label",
          text = i18n.tr("panel.subtitle"),
          fontSize = 12,
          color = "on_surface_variant",
        }),
      }),

      -- Slider control
      ui.slider({
        key = "brightness_slider",
        min = MIN_BRIGHTNESS,
        max = MAX_BRIGHTNESS,
        step = STEP_BRIGHTNESS,
        value = brightness,
        onChange = "onSliderChange",
      }),

      -- Presets label
      ui.label({
        key = "presets_label",
        text = i18n.tr("panel.presets"),
        fontSize = 11,
        fontWeight = "bold",
        color = "on_surface_variant",
      }),

      -- Quick preset buttons: flexGrow = 1 divides the row evenly without overflowing
      ui.row({
        key = "presets_row",
        gap = 6,
        padding = 0,
        align = "center",
      }, {
        presetButton(25),
        presetButton(50),
        presetButton(75),
        presetButton(100),
        presetButton(125),
      }),
    })
  )
end

noctalia.state.watch("brightness", function(val)
  if val and val ~= "" then
    local parsed = clampBrightness(val)
    if parsed ~= brightness then
      brightness = parsed
      render()
    end
  end
end)

noctalia.state.watch("busy", function(val)
  local nextBusy = (val == "true")
  if nextBusy ~= isBusy then
    isBusy = nextBusy
    render()
  end
end)

function onConfigChanged()
  brightness = clampBrightness(noctalia.getConfig("brightness") or brightness or 100)
  render()
end

function onOpen(_ctx)
  brightness = clampBrightness(noctalia.state.get("brightness") or noctalia.getConfig("brightness") or 100)
  isBusy = (noctalia.state.get("busy") == "true")
  render()
end

function update()
  render()
end

render()
