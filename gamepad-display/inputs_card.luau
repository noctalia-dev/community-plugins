--!nonstrict
-- Live gamepad input display for the Noctalia desktop.
--
-- Renders buttons, D-pad, both sticks and both triggers as they are pressed and
-- moved. State comes from the plugin's "listener" service, which reads the
-- kernel evdev node of the pad (see code/ds_inputs_daemon.py).

local STALE_AFTER = 20 -- seconds without a daemon heartbeat
local DEADZONE = 0.08  -- stick jitter below this is drawn as centered

local settings = {
  accent_color = noctalia.getConfig("accent_color") or "primary",
  text_color = noctalia.getConfig("text_color") or "on_surface",
  muted_text_color = noctalia.getConfig("muted_text_color") or "on_surface_variant",
  show_battery = noctalia.getConfig("show_battery"),
  vertical_layout = noctalia.getConfig("vertical_layout"),
  display_mode = noctalia.getConfig("display_mode"),
  illustration_color = noctalia.getConfig("illustration_color") or "#e8ebef",
  controller_body_color = noctalia.getConfig("controller_body_color") or "#2c3035",
  controller_body_opacity = tonumber(noctalia.getConfig("controller_body_opacity")) or 1.0,
  controller_stroke_width = tonumber(noctalia.getConfig("controller_stroke_width")) or 2.8,
}
if settings.accent_color == "" then
  settings.accent_color = "primary"
end
if settings.text_color == "" then
  settings.text_color = "on_surface"
end
if settings.muted_text_color == "" then
  settings.muted_text_color = "on_surface_variant"
end
if settings.show_battery == nil then
  settings.show_battery = true
end
if settings.vertical_layout == nil then
  settings.vertical_layout = false
end
if settings.display_mode == nil then
  settings.display_mode = "full"
end
local display_mode = settings.display_mode
settings.icon_buttons = (display_mode == "compact")
settings.show_inputs = (display_mode == "full")
if settings.icon_buttons == nil then
  settings.icon_buttons = false
end

local SHAPE = {
  triangle = "#6fe3a2",
  circle = "#ff7a90",
  square = "#ff9ad5",
  cross = "#8ab4ff",
}

-- Xbox-style face letters, in the physical positions used by the 8BitDo pad:
-- Y top, B right, A bottom, X left.
local XBOX = {
  y = "#f2c94c",
  b = "#ef5350",
  a = "#66bb6a",
  x = "#4a90e2",
}

local STICK = 52
local CELL = 16
local GAP = 8
local CARD_W = STICK * 4 + GAP * 3
local DOT = 7

local current_state = nil
local render

local function valid_hex(color)
  return type(color) == "string" and (
    string.match(color, "^#%x%x%x$")
    or string.match(color, "^#%x%x%x%x$")
    or string.match(color, "^#%x%x%x%x%x%x$")
    or string.match(color, "^#%x%x%x%x%x%x%x%x$")
  ) ~= nil
end

local function resolve_color(value, fallback)
  if value == nil or value == "" then
    return fallback
  end
  if string.sub(value, 1, 1) == "#" then
    return value
  end
  if type(noctalia.getColor) == "function" then
    return noctalia.getColor(value) or fallback
  end
  return fallback
end

-- Resolve the colour roles once per load. Theme-derived colours can drift
-- while the session runs (the scheme follows the wallpaper), and re-resolving
-- them on every state update would key the art cache on a new colour each time
-- and force a full SVG rebuild inside the callback budget.
local PALETTE = {
  line = resolve_color(settings.illustration_color, "#e8ebef"),
  body = resolve_color(settings.controller_body_color, "#2c3035"),
  lightbar = resolve_color(settings.accent_color, "#4a90e2"),
}
if not valid_hex(PALETTE.line) then PALETTE.line = "#e8ebef" end
if not valid_hex(PALETTE.body) then PALETTE.body = "#2c3035" end
if not valid_hex(PALETTE.lightbar) then PALETTE.lightbar = "#4a90e2" end

-- Palette role tokens take "/alpha", hex colours need an #RRGGBBAA suffix.
local function with_alpha(color, alpha)
  if type(color) ~= "string" then
    return color
  end
  local suffix = string.format("%02x", math.floor(alpha * 255 + 0.5))
  if string.sub(color, 1, 1) == "#" then
    local hex = string.gsub(color, "#", "")
    if #hex == 6 or #hex == 8 then
      return "#" .. string.sub(hex, 1, 6) .. suffix
    end
    return color
  end
  return color .. "/" .. string.format("%.2f", alpha)
end

local function color_key(color)
  return string.gsub(tostring(color), "[^%w]", "")
end

-- ui.image cannot tint, so the controller art is generated from an SVG
-- template per model and written into the plugin data directory. The template
-- changes with the active pad: DualSense/Edge, DualShock 4, or Xbox/8BitDo.
local ART = {
  dualsense = { template = "assets/controller-template.svg", fallback = "assets/controller.svg" },
  edge = { template = "assets/controller-template.svg", fallback = "assets/controller.svg" },
  ds4 = { template = "assets/controller-template.svg", fallback = "assets/controller.svg" },
  ["8bitdo"] = { template = "assets/xbox-template.svg", fallback = "assets/xbox.svg" },
  xinput = { template = "assets/xbox-template.svg", fallback = "assets/xbox.svg" },
}

local art_cache = {}

-- Families that share a template also share the static art file: edge and ds4
-- are drawn with the DualSense artwork (as live mode already does), and 8bitdo
-- with the Xbox artwork.
local function static_key(key)
  if key == "edge" or key == "ds4" then
    return "dualsense"
  elseif key == "8bitdo" then
    return "xinput"
  end
  return key
end

local function controller_art(model)
  local key = type(model) == "string" and model or "dualsense"
  local entry = ART[key] or ART.dualsense
  key = static_key(ART[key] and key or "dualsense")
  -- Once warmed at load, the art path is stable for the session. Returning it
  -- from memory keeps every render and state callback off the file system.
  local cached = art_cache[key]
  if cached then
    return cached
  end
  local line = PALETTE.line
  local body = PALETTE.body
  local lightbar = PALETTE.lightbar
  local stroke = settings.controller_stroke_width
  if type(stroke) ~= "number" or stroke <= 0 then
    stroke = 2.8
  end
  local opacity = settings.controller_body_opacity
  if type(opacity) ~= "number" then
    opacity = 1.0
  end
  opacity = math.max(0, math.min(1, opacity))
  local stroke_text = string.format("%.2f", stroke)
  local grip_text = string.format("%.2f", stroke * 0.625)
  local opacity_text = string.format("%.2f", opacity)

  local dir = noctalia.pluginDataDir()
  if not dir then
    return nil
  end
  local path = dir .. "/controller-" .. color_key(key)
    .. "-" .. color_key(line) .. "-" .. color_key(body)
    .. "-" .. color_key(lightbar) .. "-" .. color_key(stroke_text)
    .. "-" .. color_key(opacity_text) .. "-v2.svg"
  -- Reuse art generated by an earlier run. Regenerating it inside a state
  -- callback is expensive enough to exceed the callback CPU budget on a cold
  -- shell start.
  if noctalia.fileExists(path) then
    art_cache[key] = path
    return path
  end
  local template = noctalia.readFile(entry.template)
  if not template then
    return entry.fallback
  end
  local values = {
    BODY = body,
    BODY_OPACITY = opacity_text,
    COLOR = line,
    LIGHTBAR = lightbar,
    STROKE_BODY = stroke_text,
    STROKE_GRIP = grip_text,
    -- Static art keeps the normal face-button colours. The live (icon) variant
    -- swaps these per state; digital-button overlays stay invisible ("none").
    BTN_Y = XBOX.y,
    BTN_X = XBOX.x,
    BTN_B = XBOX.b,
    BTN_A = XBOX.a,
    BTN_TRIANGLE = SHAPE.triangle,
    BTN_SQUARE = SHAPE.square,
    BTN_CIRCLE = SHAPE.circle,
    BTN_CROSS = SHAPE.cross,
    BTN_UP = "none",
    BTN_DOWN = "none",
    BTN_LEFT = "none",
    BTN_RIGHT = "none",
    BTN_L1 = "none",
    BTN_R1 = "none",
    BTN_L3 = "none",
    BTN_R3 = "none",
    STICK_COLOR = lightbar,
    TRIG_COLOR = lightbar,
    TRIG_L2_PATH = "",
    TRIG_R2_PATH = "",
  }
  local svg = string.gsub(template, "{{([A-Z0-9_]+)}}", function(name)
    return values[name] or ("{{" .. name .. "}}")
  end)
  -- Static art: center the stick dots (no live input).
  if key == "8bitdo" or key == "xinput" then
    svg = string.gsub(svg, "{{STICK_LX}}", "35")
    svg = string.gsub(svg, "{{STICK_LY}}", "33")
    svg = string.gsub(svg, "{{STICK_RX}}", "85")
    svg = string.gsub(svg, "{{STICK_RY}}", "52")
  elseif key == "ds4" then
    svg = string.gsub(svg, "{{STICK_LX}}", "45")
    svg = string.gsub(svg, "{{STICK_LY}}", "57")
    svg = string.gsub(svg, "{{STICK_RX}}", "75")
    svg = string.gsub(svg, "{{STICK_RY}}", "57")
  else
    svg = string.gsub(svg, "{{STICK_LX}}", "45.5")
    svg = string.gsub(svg, "{{STICK_LY}}", "64.46")
    svg = string.gsub(svg, "{{STICK_RX}}", "82.5")
    svg = string.gsub(svg, "{{STICK_RY}}", "64.46")
  end
  if not noctalia.writeFile(path, svg) then
    return entry.fallback
  end
  art_cache[key] = path
  return path
end

-- Generate the static art for every template family while the load budget is
-- available, so a state callback never has to build a new SVG. The files are
-- reused on later loads, and the palette is fixed for the session.
local function warm_static()
  for _, key in ipairs({ "dualsense", "xinput" }) do
    controller_art(key)
  end
end

local function fresh()
  if type(current_state) ~= "table" then
    return false
  end
  local ts = tonumber(current_state.ts)
  if not ts then
    return false
  end
  return os.time() - ts <= STALE_AFTER
end

local function full_state()
  if not fresh() or current_state.connected ~= true then
    return nil
  end
  return current_state
end

local function button(name)
  local s = full_state()
  if type(s) ~= "table" or type(s.buttons) ~= "table" then
    return false
  end
  return s.buttons[name] == true
end

local function axis(table_name, key)
  local s = full_state()
  if type(s) ~= "table" or type(s[table_name]) ~= "table" then
    return 0
  end
  return tonumber(s[table_name][key]) or 0
end

local function dpad(key)
  local s = full_state()
  if type(s) ~= "table" or type(s.dpad) ~= "table" then
    return 0
  end
  return tonumber(s.dpad[key]) or 0
end

-- Live controller artwork (compact "icon" mode).
--
-- Regenerating a full SVG on every button press is what made earlier attempts
-- hit Noctalia's 25 ms per-callback CPU budget. The static parts are built once
-- per model/colour set and only the four face-button tokens are swapped per
-- state. Each replacement is a single scan: eight whole-file gsubs cost
-- 12-24 ms in Luau, which is most of the budget.
local art_live_cache = {}
local art_live_base = {}

local DIM_BTN = "#3a3f45"

local function quantize(v, step)
  return math.floor((v or 0) / step + 0.5) * step
end

local function live_base(model, line, body, lightbar, stroke_text, grip_text, opacity_text)
  local key = type(model) == "string" and model or "dualsense"
  local entry = ART[key] or ART.dualsense
  -- xinput shares the Xbox template and edge shares the DualSense template, so
  -- cache the prepared base per template family instead of per model name.
  local family = key
  if key == "xinput" then
    family = "8bitdo"
  elseif key == "edge" then
    family = "dualsense"
  end
  local cache_key = family .. "|" .. color_key(line) .. "|" .. color_key(body)
    .. "|" .. color_key(lightbar) .. "|" .. color_key(stroke_text)
    .. "|" .. color_key(grip_text) .. "|" .. color_key(opacity_text)
  local base = art_live_base[cache_key]
  if base then
    return base
  end

  local template = noctalia.readFile(entry.template)
  if not template then
    return nil
  end

  -- Templates now carry their BTN_* tokens directly, so no
  -- per-family placeholder injection is needed here.

  local static = {
    BODY = body,
    BODY_OPACITY = opacity_text,
    COLOR = line,
    LIGHTBAR = lightbar,
    STROKE_BODY = stroke_text,
    STROKE_GRIP = grip_text,
    STICK_COLOR = lightbar,
    TRIG_COLOR = lightbar,
  }
  local svg = string.gsub(template, "{{([A-Z0-9_]+)}}", function(name)
    return static[name] or ("{{" .. name .. "}}")
  end)
  art_live_base[cache_key] = svg
  return svg
end

local function live_colors(model)
  local line = PALETTE.line
  local body = PALETTE.body
  local lightbar = PALETTE.lightbar
  local stroke = settings.controller_stroke_width
  if type(stroke) ~= "number" or stroke <= 0 then stroke = 2.8 end
  local opacity = settings.controller_body_opacity
  if type(opacity) ~= "number" then opacity = 1.0 end
  opacity = math.max(0, math.min(1, opacity))
  local stroke_text = string.format("%.2f", stroke)
  local grip_text = string.format("%.2f", stroke * 0.625)
  local opacity_text = string.format("%.2f", opacity)
  return line, body, lightbar, stroke_text, grip_text, opacity_text
end

-- sig = triangle, square, circle, cross ("1" pressed).
-- Trigger bar path: flat-bottomed bar with rounded top corners.
-- Outline: bottom-left -> across bottom -> up right side -> rounded top ->
-- across top -> rounded top -> down left side -> close.
local function trig_bar(x0, x1, top, bottom, r, rounded)
  if not rounded or (bottom - top) < 2 * r then
    return string.format("M%.1f %.1f L%.1f %.1f L%.1f %.1f L%.1f %.1f Z", x0, bottom, x1, bottom, x1, top, x0, top)
  end
  return string.format("M%.1f %.1f L%.1f %.1f L%.1f %.1f Q%.1f %.1f %.1f %.1f L%.1f %.1f Q%.1f %.1f %.1f %.1f L%.1f %.1f Z",
    x0, bottom, x1, bottom, x1, top + r, x1, top, x1 - r, top, x0 + r, top, x0, top, x0, top + r, x0, bottom)
end

local function build_live_svg(model, sig)
  local key = type(model) == "string" and model or "dualsense"
  -- A DualShock 4 plugged in renders with the DualSense artwork + buttons
  -- (the DS4 template is the ugly one); edge already shares the DualSense set.
  if key == "ds4" or key == "edge" then
    key = "dualsense"
  end
  local line, body, lightbar, stroke_text, grip_text, opacity_text = live_colors(key)
  local base = live_base(key, line, body, lightbar, stroke_text, grip_text, opacity_text)
  if not base then
    return nil
  end
  local function on(i)
    return string.sub(sig, i, i) == "1"
  end
  local xbox = key == "8bitdo" or key == "xinput"
  local dualsense = key == "dualsense" or key == "edge"
  -- Face buttons: solid circles on Xbox, strokes on DS4, fills on DualSense.
  local face_unlit = dualsense and "none" or DIM_BTN
  local c_tri = on(1) and (xbox and XBOX.y or SHAPE.triangle) or face_unlit
  local c_sqr = on(2) and (xbox and XBOX.x or SHAPE.square) or face_unlit
  local c_cir = on(3) and (xbox and XBOX.b or SHAPE.circle) or face_unlit
  local c_crs = on(4) and (xbox and XBOX.a or SHAPE.cross) or face_unlit

  -- Digital buttons (D-pad, shoulders, stick clicks) are overlays.
  local lit = lightbar
  local c_up = on(5) and lit or "none"
  local c_down = on(6) and lit or "none"
  local c_left = on(7) and lit or "none"
  local c_right = on(8) and lit or "none"
  local c_l1 = on(9) and lit or "none"
  local c_r1 = on(10) and lit or "none"
  local c_l3 = on(11) and lit or "none"
  local c_r3 = on(12) and lit or "none"

  -- Analog values from the current state.
  local s = full_state()
  local function axis_val(t, k)
    if type(s) ~= "table" or type(s[t]) ~= "table" then return 0 end
    return tonumber(s[t][k]) or 0
  end
  local lx = axis_val("sticks", "lx")
  local ly = axis_val("sticks", "ly")
  local rx = axis_val("sticks", "rx")
  local ry = axis_val("sticks", "ry")
  -- Quantize stick values so the dot position matches the cache key bucket.
  lx = quantize(lx, 0.05)
  ly = quantize(ly, 0.05)
  rx = quantize(rx, 0.05)
  ry = quantize(ry, 0.05)

  -- Compute trigger bar widths and stick dot positions per family.
  local l2 = math.max(0, math.min(1, axis_val("triggers", "l2")))
  local r2 = math.max(0, math.min(1, axis_val("triggers", "r2")))
  local trig_l2_h, trig_l2_y = "0", "0"
  local trig_r2_h, trig_r2_y = "0", "0"
  local stick_lx, stick_ly, stick_rx, stick_ry = "0", "0", "0", "0"
  if xbox then
    local mh = 10
    trig_l2_h = string.format("%.1f", l2 * mh)
    trig_l2_y = string.format("%.1f", 2 + (mh - l2 * mh))
    trig_r2_h = string.format("%.1f", r2 * mh)
    trig_r2_y = string.format("%.1f", 2 + (mh - r2 * mh))
    -- Generate SVG path for L2 trigger (flat-bottomed, rounded-top shape sitting behind bumper)
    local fill_h = l2 * mh
    local top = 2 + (mh - fill_h)
    local bottom = 2 + mh
    local x0, x1, r = 31, 39, 4
    trig_l2_path = trig_bar(x0, x1, top, bottom, r, fill_h >= 2 * r)
    -- Generate SVG path for R2 trigger
    fill_h = r2 * mh
    top = 2 + (mh - fill_h)
    bottom = 2 + mh
    x0, x1, r = 81, 89, 4
    trig_r2_path = trig_bar(x0, x1, top, bottom, r, fill_h >= 2 * r)
    stick_lx = string.format("%.1f", 35 + lx * 6)
    stick_ly = string.format("%.1f", 33 + ly * 6)
    stick_rx = string.format("%.1f", 85 + rx * 6)
    stick_ry = string.format("%.1f", 52 + ry * 6)
  elseif key == "ds4" then
    local mh = 10
    trig_l2_h = string.format("%.1f", l2 * mh)
    trig_l2_y = string.format("%.1f", 4 + (mh - l2 * mh))
    trig_r2_h = string.format("%.1f", r2 * mh)
    trig_r2_y = string.format("%.1f", 4 + (mh - r2 * mh))
    -- Generate SVG path for L2 trigger
    local fill_h = l2 * mh
    local top = 4 + (mh - fill_h)
    local bottom = 4 + mh
    local x0, x1, r = 23, 31, 3
    trig_l2_path = trig_bar(x0, x1, top, bottom, r, fill_h >= 2 * r)
    -- Generate SVG path for R2 trigger
    fill_h = r2 * mh
    top = 4 + (mh - fill_h)
    bottom = 4 + mh
    x0, x1, r = 85, 93, 3
    trig_r2_path = trig_bar(x0, x1, top, bottom, r, fill_h >= 2 * r)
    stick_lx = string.format("%.1f", 45 + lx * 6)
    stick_ly = string.format("%.1f", 57 + ly * 6)
    stick_rx = string.format("%.1f", 75 + rx * 6)
    stick_ry = string.format("%.1f", 57 + ry * 6)
  else
    local mh = 10
    trig_l2_h = string.format("%.1f", l2 * mh)
    trig_l2_y = string.format("%.1f", 12 + (mh - l2 * mh))
    trig_r2_h = string.format("%.1f", r2 * mh)
    trig_r2_y = string.format("%.1f", 12 + (mh - r2 * mh))
    -- Generate SVG path for L2 trigger
    local fill_h = l2 * mh
    local top = 12 + (mh - fill_h)
    local bottom = 12 + mh
    local x0, x1, r = 25, 33, 3
    trig_l2_path = trig_bar(x0, x1, top, bottom, r, fill_h >= 2 * r)
    -- Generate SVG path for R2 trigger
    fill_h = r2 * mh
    top = 12 + (mh - fill_h)
    bottom = 12 + mh
    x0, x1, r = 95, 103, 3
    trig_r2_path = trig_bar(x0, x1, top, bottom, r, fill_h >= 2 * r)
    stick_lx = string.format("%.1f", 45.5 + lx * 3)
    stick_ly = string.format("%.1f", 64.46 + ly * 3)
    stick_rx = string.format("%.1f", 82.5 + rx * 3)
    stick_ry = string.format("%.1f", 64.46 + ry * 3)
  end

  -- One scan instead of many: a single gsub over the whole template.
  local btn = {
    ["BTN_Y"] = c_tri, ["BTN_X"] = c_sqr, ["BTN_B"] = c_cir, ["BTN_A"] = c_crs,
    ["BTN_TRIANGLE"] = c_tri, ["BTN_SQUARE"] = c_sqr, ["BTN_CIRCLE"] = c_cir, ["BTN_CROSS"] = c_crs,
    ["BTN_UP"] = c_up, ["BTN_DOWN"] = c_down, ["BTN_LEFT"] = c_left, ["BTN_RIGHT"] = c_right,
    ["BTN_L1"] = c_l1, ["BTN_R1"] = c_r1, ["BTN_L3"] = c_l3, ["BTN_R3"] = c_r3,
    STICK_LX = stick_lx, STICK_LY = stick_ly,
    STICK_RX = stick_rx, STICK_RY = stick_ry,
    STICK_COLOR = lightbar,
    TRIG_L2_PATH = trig_l2_path,
    TRIG_R2_PATH = trig_r2_path,
    TRIG_COLOR = lightbar,
  }
  local svg = string.gsub(base, "{{([A-Z0-9_]+)}}", function(name)
    return btn[name] or ""
  end)
  return svg
end

local function current_sig()
  local s = full_state()
  local function isbtn(name)
    return type(s) == "table" and type(s.buttons) == "table" and s.buttons[name] == true
  end
  local d = (type(s) == "table" and type(s.dpad) == "table") and s.dpad or {}
  local dx = tonumber(d.x) or 0
  local dy = tonumber(d.y) or 0
  return (isbtn("triangle") and "1" or "0")
    .. (isbtn("square") and "1" or "0")
    .. (isbtn("circle") and "1" or "0")
    .. (isbtn("cross") and "1" or "0")
    .. (dy < 0 and "1" or "0")   -- up
    .. (dy > 0 and "1" or "0")   -- down
    .. (dx < 0 and "1" or "0")   -- left
    .. (dx > 0 and "1" or "0")   -- right
    .. (isbtn("l1") and "1" or "0")
    .. (isbtn("r1") and "1" or "0")
    .. (isbtn("l3") and "1" or "0")
    .. (isbtn("r3") and "1" or "0")
end

local live_slot = 0
local last_live_qkey = nil
local last_live_path = nil

local function controller_art_live(model)
  local sig = current_sig()
  local key = type(model) == "string" and model or "dualsense"
  local st = full_state()
  local function axis_val(t, k)
    if type(st) ~= "table" or type(st[t]) ~= "table" then return 0 end
    return tonumber(st[t][k]) or 0
  end
  local lx = quantize(axis_val("sticks", "lx"), 0.05)
  local ly = quantize(axis_val("sticks", "ly"), 0.05)
  local rx = quantize(axis_val("sticks", "rx"), 0.05)
  local ry = quantize(axis_val("sticks", "ry"), 0.05)
  local l2q = quantize(axis_val("triggers", "l2"), 0.05)
  local r2q = quantize(axis_val("triggers", "r2"), 0.05)
  local qkey = key .. "|" .. sig .. "|" .. l2q .. "|" .. r2q .. "|" .. lx .. "|" .. ly .. "|" .. rx .. "|" .. ry .. "|" .. live_slot
  -- If nothing changed, reuse the last path (no regeneration).
  if qkey == last_live_qkey and last_live_path and noctalia.fileExists(last_live_path) then
    return last_live_path
  end
  local dir = noctalia.pluginDataDir()
  if not dir then
    return controller_art(model)
  end
  live_slot = (live_slot + 1) % 4
  local path = dir .. "/controller-live-" .. color_key(key) .. "-" .. live_slot .. "-v3.svg"
  local svg = build_live_svg(key, sig)
  if not svg or not noctalia.writeFile(path, svg) then
    return controller_art(model)
  end
  last_live_qkey = qkey
  last_live_path = path
  return path
end

-- Warm the shared base template for each family at load (100 ms budget). A model
-- change at runtime then only swaps the four button tokens; if the base were
-- still cold, that first render could exceed 25 ms.
local function warm_live()
  local families = { "8bitdo", "dualsense", "ds4" }
  for _, key in ipairs(families) do
    -- Warm the in-memory base template for each family (100 ms budget).
    local line, body, lightbar, stroke_text, grip_text, opacity_text = live_colors(key)
    live_base(key, line, body, lightbar, stroke_text, grip_text, opacity_text)
  end
end

local function weight(value)
  if not value or value < 0 then
    return 0.001
  end
  return math.max(0.001, value)
end

local function stick_position(value)
  if math.abs(value) < DEADZONE then
    return 0.5
  end
  return math.max(0, math.min(1, (value + 1) / 2))
end

-- A round stick well with a dot offset by the live axis values. `ui.*` has no
-- absolute positioning, so the offset comes from weighted spacers around the
-- dot: flexGrow x : (1 - x) puts it at the right fraction of the well.
local function stick_node(key, x_value, y_value, pressed)
  local fx = stick_position(x_value)
  local fy = stick_position(y_value)
  local border = pressed and settings.accent_color or with_alpha(resolve_color(settings.muted_text_color, "#8b9096"), 0.55)
  return ui.column({
    key = key,
    width = STICK,
    height = STICK,
    radius = STICK / 2,
    fill = "surface/0.55",
    border = border,
    borderWidth = pressed and 2 or 1,
    padding = 7,
    align = "stretch",
  }, {
    ui.spacer({ key = key .. "-up", flexGrow = weight(fy) }),
    ui.row({ key = key .. "-row", height = DOT, align = "center", justify = "start" }, {
      ui.spacer({ key = key .. "-left", flexGrow = weight(fx) }),
      ui.column({
        key = key .. "-dot",
        width = DOT,
        height = DOT,
        radius = DOT / 2,
        fill = settings.accent_color,
        opacity = pressed and 1 or 0.9,
      }),
      ui.spacer({ key = key .. "-right", flexGrow = weight(1 - fx) }),
    }),
    ui.spacer({ key = key .. "-down", flexGrow = weight(1 - fy) }),
  })
end

local function shape_button(key, glyph, color, lit)
  return ui.column({
    key = key,
    width = CELL,
    height = CELL,
    radius = 5,
    align = "center",
    justify = "center",
    fill = lit and with_alpha(color, 0.3) or "surface/0.55",
    border = lit and color or with_alpha(settings.muted_text_color, 0.55),
    borderWidth = lit and 2 or 1,
  }, {
    ui.glyph({ key = key .. "-glyph", name = glyph, size = 10, color = color, opacity = lit and 1 or 0.55 }),
  })
end

local function letter_button(key, letter, color, lit)
  return ui.column({
    key = key,
    width = CELL,
    height = CELL,
    radius = 5,
    align = "center",
    justify = "center",
    fill = lit and with_alpha(color, 0.3) or "surface/0.55",
    border = lit and color or with_alpha(settings.muted_text_color, 0.55),
    borderWidth = lit and 2 or 1,
  }, {
    ui.label({
      key = key .. "-letter",
      text = letter,
      fontSize = 10,
      fontWeight = "bold",
      color = lit and "#ffffff" or color,
      opacity = lit and 1 or 0.7,
    }),
  })
end

local function mini_button(key, glyph, lit)
  return ui.column({
    key = key,
    width = CELL,
    height = CELL,
    radius = 5,
    align = "center",
    justify = "center",
    fill = lit and with_alpha(settings.accent_color, 0.35) or "surface/0.55",
    border = lit and settings.accent_color or with_alpha(settings.muted_text_color, 0.55),
    borderWidth = lit and 2 or 1,
  }, {
    ui.glyph({
      key = key .. "-glyph",
      name = glyph,
      size = 9,
      color = lit and settings.accent_color or settings.muted_text_color,
      opacity = lit and 1 or 0.75,
    }),
  })
end

local function dpad_cell(key, glyph, lit)
  return ui.column({
    key = key,
    width = CELL,
    height = CELL,
    radius = 4,
    align = "center",
    justify = "center",
    fill = lit and with_alpha(settings.accent_color, 0.35) or "surface/0.55",
    border = lit and settings.accent_color or with_alpha(settings.muted_text_color, 0.55),
    borderWidth = lit and 2 or 1,
  }, {
    ui.glyph({
      key = key .. "-glyph",
      name = glyph,
      size = 10,
      color = lit and settings.accent_color or settings.muted_text_color,
      opacity = lit and 1 or 0.7,
    }),
  })
end

local function dpad_node()
  local x = dpad("x")
  local y = dpad("y")
  local function row(key, children)
    return ui.row({ key = key, gap = 2, align = "center", justify = "center" }, children)
  end
  local function empty(key)
    return ui.column({ key = key, width = CELL, height = CELL })
  end
  return ui.column({ key = "dpad", gap = 2, align = "center", justify = "center", width = STICK, height = STICK }, {
    row("dpad-up-row", {
      empty("dpad-empty-tl"),
      dpad_cell("dpad-up", "chevron-up", y < 0),
      empty("dpad-empty-tr"),
    }),
    row("dpad-mid-row", {
      dpad_cell("dpad-left", "chevron-left", x < 0),
      ui.column({ key = "dpad-center", width = CELL, height = CELL, align = "center", justify = "center" }, {
        ui.column({ key = "dpad-center-dot", width = 6, height = 6, radius = 3, fill = with_alpha(settings.muted_text_color, 0.5) }),
      }),
      dpad_cell("dpad-right", "chevron-right", x > 0),
    }),
    row("dpad-down-row", {
      empty("dpad-empty-bl"),
      dpad_cell("dpad-down", "chevron-down", y > 0),
      empty("dpad-empty-br"),
    }),
  })
end

local function face_node()
  local s = full_state()
  local xbox = type(s) == "table" and (s.model == "8bitdo" or s.model == "xinput")
  local function face(key, glyph, color, lit, letter, xbox_color)
    if xbox then
      return letter_button(key, letter, xbox_color or color, lit)
    end
    return shape_button(key, glyph, color, lit)
  end
  local function row(key, children)
    return ui.row({ key = key, gap = 2, align = "center", justify = "center" }, children)
  end
  local function empty(key)
    return ui.column({ key = key, width = CELL, height = CELL })
  end
  return ui.column({ key = "face", gap = 2, align = "center", justify = "center", width = STICK, height = STICK }, {
    row("face-top-row", {
      empty("face-empty-tl"),
      face("face-triangle", "triangle", SHAPE.triangle, button("triangle"), "Y", XBOX.y),
      empty("face-empty-tr"),
    }),
    row("face-mid-row", {
      face("face-square", "square", SHAPE.square, button("square"), "X", XBOX.x),
      ui.column({ key = "face-center", width = CELL, height = CELL }),
      face("face-circle", "circle", SHAPE.circle, button("circle"), "B", XBOX.b),
    }),
    row("face-bottom-row", {
      empty("face-empty-bl"),
      face("face-cross", "x", SHAPE.cross, button("cross"), "A", XBOX.a),
      empty("face-empty-br"),
    }),
  })
end

local function pill(key, text, lit)
  return ui.column({
    key = key,
    width = 26,
    height = CELL,
    radius = 5,
    align = "center",
    justify = "center",
    fill = lit and with_alpha(settings.accent_color, 0.35) or "surface/0.55",
    border = lit and settings.accent_color or with_alpha(settings.muted_text_color, 0.55),
    borderWidth = lit and 2 or 1,
  }, {
    ui.label({
      key = key .. "-label",
      text = text,
      fontSize = 8,
      fontWeight = "medium",
      color = lit and settings.accent_color or settings.muted_text_color,
    }),
  })
end

local function trigger_column(key, text, value, align_end)
  return ui.column({
    key = key,
    width = 44,
    gap = 3,
    align = align_end and "end" or "start",
  }, {
    ui.label({
      key = key .. "-label",
      text = text,
      fontSize = 8,
      color = settings.muted_text_color,
      opacity = value > 0.02 and 1 or 0.7,
    }),
    ui.progress({
      key = key .. "-bar",
      progress = value,
      width = 44,
      height = 4,
      radius = 2,
      fill = settings.accent_color,
      track = with_alpha(settings.muted_text_color, 0.35),
    }),
  })
end

local function battery_label(s)
  if not settings.show_battery then
    return nil
  end
  local pct = tonumber(s.battery_pct) or -1
  if pct < 0 then
    return nil
  end
  return ui.row({ key = "battery", gap = 3, align = "center" }, {
    ui.glyph({
      key = "battery-glyph",
      name = s.charging and "battery-charging" or "battery",
      size = 11,
      color = s.charging and settings.accent_color or settings.muted_text_color,
    }),
    ui.label({
      key = "battery-text",
      text = tostring(math.floor(pct + 0.5)) .. "%",
      fontSize = 10,
      color = settings.muted_text_color,
    }),
  })
end

local function header(s)
  local title = "DualSense"
  if s.model == "edge" then
    title = "DualSense Edge"
  elseif s.model == "ds4" then
    title = "DualShock 4"
  elseif s.model == "8bitdo" then
    title = "8BitDo"
  elseif s.model == "xinput" then
    title = "Xbox Controller"
  end

  local children = {}
  local art = settings.icon_buttons and controller_art_live(s.model) or controller_art(s.model)
  if settings.icon_buttons then
    -- Compact mode: trigger bars always above the artwork, regardless of
    -- vertical_layout.
    local art_w = 120
    local art_h = 90
    local art_node = nil
    if art then
      art_node = ui.image({
        key = "controller-art",
        path = art,
        width = art_w,
        height = art_h,
        fit = "contain",
      })
    end
    local compact_children = {}
    if art_node then
      table.insert(compact_children, art_node)
    end
    table.insert(children, ui.column({ key = "compact-art-block", gap = 4, align = "center" }, compact_children))
  elseif art then
    -- Icon mode is the whole point of the artwork, so give it more room.
    local art_w = 76
    local art_h = 57
    table.insert(children, ui.image({
      key = "controller-art",
      path = art,
      width = art_w,
      height = art_h,
      fit = "contain",
    }))
  end

  local status = {}
  local battery = battery_label(s)
  if battery then
    table.insert(status, battery)
  end
  if s.connection == "usb" then
    table.insert(status, ui.glyph({ key = "header-link", name = "usb", size = 11, color = settings.muted_text_color }))
  elseif s.connection == "bluetooth" then
    table.insert(status, ui.glyph({ key = "header-link", name = "bluetooth", size = 11, color = settings.muted_text_color }))
  end

  table.insert(children, ui.column({
    key = "header-info",
    gap = 4,
    align = "center",
  }, {
    ui.row({ key = "header-title-row", gap = 5, align = "center", justify = "center" }, {
      ui.label({
        key = "header-title",
        text = title,
        fontSize = 10,
        fontWeight = "semibold",
        color = settings.text_color,
      }),
    }),
    ui.row({ key = "header-status-row", gap = 6, align = "center", justify = "center" }, status),
  }))

  if settings.vertical_layout then
    return ui.column({ key = "header", gap = 6, width = CARD_W, align = "center", justify = "center" }, children)
  end
  return ui.row({ key = "header", gap = 8, width = CARD_W, align = "center", justify = "center" }, children)
end

local function shoulders(s)
  return ui.row({ key = "shoulders", width = CARD_W, gap = 6, align = "center" }, {
    trigger_column("l2", "L2", axis("triggers", "l2"), false),
    pill("l1", "L1", button("l1")),
    ui.spacer({ key = "shoulder-gap-l", flexGrow = 1 }),
    mini_button("create", "menu-2", button("create")),
    mini_button("ps", "circle-dot", button("ps")),
    mini_button("options", "player-play-filled", button("options")),
    ui.spacer({ key = "shoulder-gap-r", flexGrow = 1 }),
    pill("r1", "R1", button("r1")),
    trigger_column("r2", "R2", axis("triggers", "r2"), true),
  })
end

local function shoulders_vertical(s)
  return ui.row({ key = "shoulders-vertical", width = CARD_W, gap = 6, align = "center", justify = "center" }, {
    ui.column({ key = "shoulder-left", gap = 4, align = "center" }, {
      trigger_column("l2", "L2", axis("triggers", "l2"), false),
      pill("l1", "L1", button("l1")),
    }),
    ui.column({ key = "shoulder-mid", gap = 4, align = "center", justify = "center" }, {
      mini_button("create", "menu-2", button("create")),
      mini_button("ps", "circle-dot", button("ps")),
      mini_button("options", "player-play-filled", button("options")),
    }),
    ui.column({ key = "shoulder-right", gap = 4, align = "center" }, {
      trigger_column("r2", "R2", axis("triggers", "r2"), true),
      pill("r1", "R1", button("r1")),
    }),
  })
end

local function body()
  return ui.row({ key = "body", width = CARD_W, gap = GAP, align = "center", justify = "center" }, {
    stick_node("stick-l", axis("sticks", "lx"), axis("sticks", "ly"), button("l3")),
    dpad_node(),
    face_node(),
    stick_node("stick-r", axis("sticks", "rx"), axis("sticks", "ry"), button("r3")),
  })
end

local function body_vertical()
  return ui.column({ key = "body-vertical", width = CARD_W, gap = GAP, align = "center", justify = "center" }, {
    ui.row({ key = "vertical-dpad-face", gap = GAP, align = "center", justify = "center" }, {
      dpad_node(),
      face_node(),
    }),
    ui.row({ key = "vertical-sticks", gap = GAP, align = "center", justify = "center" }, {
      stick_node("stick-l", axis("sticks", "lx"), axis("sticks", "ly"), button("l3")),
      stick_node("stick-r", axis("sticks", "rx"), axis("sticks", "ry"), button("r3")),
    }),
  })
end

local function placeholder()
  local s = type(current_state) == "table" and current_state or {}
  local children = {
    ui.glyph({
      key = "placeholder-glyph",
      name = "device-gamepad-2",
      size = 22,
      color = settings.muted_text_color,
      opacity = 0.5,
    }),
  }
  -- No controller is a quiet idle state: show only the dim glyph. Keep the
  -- message for a genuinely broken install so the missing dependency is
  -- still discoverable.
  if s.error == "python3" then
    table.insert(children, ui.label({
      key = "placeholder-text",
      text = noctalia.tr("status.no_python"),
      fontSize = 10,
      color = settings.muted_text_color,
    }))
  end
  return ui.column({ key = "placeholder", gap = 4, align = "center", padding = 10 }, children)
end

render = function()
  local s = full_state()

  local children
  if s then
    children = { header(s) }
    -- Icon mode is the compact view: the buttons live on the artwork, so the
    -- separate input grid stays hidden.
    if settings.show_inputs ~= false and not settings.icon_buttons then
      local shoulders_node = settings.vertical_layout and shoulders_vertical(s) or shoulders(s)
      local body_node = settings.vertical_layout and body_vertical() or body()
      table.insert(children, shoulders_node)
      table.insert(children, body_node)
    end
  else
    children = { placeholder() }
  end
  desktopWidget.render(ui.column({
    key = "inputs-card",
    gap = 6,
    align = "center",
    padding = 2,
  }, children))
end

current_state = noctalia.state.get("inputs")
-- Prepare the artwork while the load budget (100 ms) is available, so a later
-- render only has to pick a cached path.
local t0 = os.clock()
if settings.icon_buttons then
  warm_live()
else
  warm_static()
end
noctalia.log(string.format("[gamepad] warmed %s art in %.1f ms",
  settings.icon_buttons and "icon" or "static", (os.clock() - t0) * 1000))
noctalia.setUpdateInterval(1000)
noctalia.state.watch("inputs", function(value)
  current_state = value
  render()
end)

function update()
  render()
end

render()
