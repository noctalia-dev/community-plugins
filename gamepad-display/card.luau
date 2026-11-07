--!nonstrict
-- Declarative desktop card for DualSense & DualSense Edge controllers (ds4u).
--
-- By default the card mirrors the controller's ds4u lightbar color (or its
-- connection link color: PlayStation blue on Bluetooth, green on USB-C, red
-- when low). The controller line/body, lightbar accents and battery fill are
-- configurable. Charging pulses. The profile selector switches directly among
-- saved ds4u profiles; clicking the controller art rumbles the controller.

local STALE_AFTER = 20 -- seconds without a daemon heartbeat

local settings = {
  illustration_color = noctalia.getConfig("illustration_color") or "#e8ebef",
  controller_body_color = noctalia.getConfig("controller_body_color") or "#2c3035",
  controller_body_opacity = tonumber(noctalia.getConfig("controller_body_opacity")) or 1.0,
  controller_stroke_width = tonumber(noctalia.getConfig("controller_stroke_width")) or 2.8,
  profile_settings_opacity = tonumber(noctalia.getConfig("profile_settings_opacity")) or 0.65,
  battery_color_mode = noctalia.getConfig("battery_color_mode") or "lightbar",
  battery_fill_color = noctalia.getConfig("battery_fill_color") or "#0080ff",
  battery_fill_opacity = tonumber(noctalia.getConfig("battery_fill_opacity")) or 1.0,
  battery_low_color = noctalia.getConfig("battery_low_color") or "#ed4c4c",
  text_color = noctalia.getConfig("text_color") or "on_surface",
  muted_text_color = noctalia.getConfig("muted_text_color") or "on_surface_variant",
  show_profile = noctalia.getConfig("show_profile"),
  show_player_leds = noctalia.getConfig("show_player_leds"),
  show_model_badge = noctalia.getConfig("show_model_badge"),
}
if settings.battery_color_mode ~= "custom" and settings.battery_color_mode ~= "connection" then
  settings.battery_color_mode = "lightbar"
end
if settings.battery_fill_color == "" then
  settings.battery_fill_color = "#0080ff"
end
if settings.battery_low_color == "" then
  settings.battery_low_color = "#ed4c4c"
end
if settings.battery_fill_opacity < 0 then
  settings.battery_fill_opacity = 0
elseif settings.battery_fill_opacity > 1 then
  settings.battery_fill_opacity = 1
end
if settings.controller_body_opacity < 0 then
  settings.controller_body_opacity = 0
elseif settings.controller_body_opacity > 1 then
  settings.controller_body_opacity = 1
end
if settings.profile_settings_opacity < 0 then
  settings.profile_settings_opacity = 0
elseif settings.profile_settings_opacity > 1 then
  settings.profile_settings_opacity = 1
end
if settings.text_color == "" then
  settings.text_color = "on_surface"
end
if settings.muted_text_color == "" then
  settings.muted_text_color = "on_surface_variant"
end
if settings.controller_stroke_width < 0.5 then
  settings.controller_stroke_width = 0.5
elseif settings.controller_stroke_width > 8 then
  settings.controller_stroke_width = 8
end
if settings.show_profile == nil then
  settings.show_profile = true
end
if settings.show_player_leds == nil then
  settings.show_player_leds = true
end
if settings.show_model_badge == nil then
  settings.show_model_badge = true
end

local low_threshold = tonumber(noctalia.getConfig("low_threshold")) or 20

local LED = {
  default_lightbar = "#0080ff",
  bluetooth = "#3daee9",
  cable = "#3ec47a",
  charging = "#ff9a3c",
}

-- DualSense 5-LED player indicator patterns from ds4u (src/dualsense.rs)
local PLAYER_LED_PATTERNS = {
  [0] = { false, false, false, false, false },
  [1] = { false, false, true,  false, false },
  [2] = { false, true,  false, true,  false },
  [3] = { true,  false, true,  false, true  },
  [4] = { true,  true,  false, true,  true  },
  [5] = { true,  true,  true,  true,  true  },
  [6] = { true,  false, false, false, true  },
  [7] = { false, true,  true,  true,  false },
}

local BODY_W = 58
local BODY_H = 150
local INNER_H = BODY_H - 10

local current_state = nil
local pulse = 1
local pulse_phase = 0
local frame_accum = 0
local action_seq = 0
local profile_menu_open = false
local render

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

local function valid_hex(color)
  return type(color) == "string" and (
    string.match(color, "^#%x%x%x$")
    or string.match(color, "^#%x%x%x%x$")
    or string.match(color, "^#%x%x%x%x%x%x$")
    or string.match(color, "^#%x%x%x%x%x%x%x%x$")
  ) ~= nil
end

-- Append an alpha suffix to either a hex colour or a theme colour role.
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

local function active_lightbar_hex()
  local s = type(current_state) == "table" and current_state or {}
  if type(s.lightbar_color) == "string" and valid_hex(s.lightbar_color) then
    return s.lightbar_color
  end
  return LED.default_lightbar
end

-- Draw the DualSense line art, body and lightbar accents in the configured
-- colours. A generated SVG is used because ui.image cannot tint; fall back to
-- the bundled one.
local art_path = nil

local function controller_art()
  local fallback = "assets/controller.svg"
  local line = resolve_color(settings.illustration_color, "#e8ebef")
  local body = resolve_color(settings.controller_body_color, "#2c3035")
  local lb = active_lightbar_hex()
  if not valid_hex(line) then
    line = "#e8ebef"
  end
  if not valid_hex(body) then
    body = "#2c3035"
  end
  if not valid_hex(lb) then
    lb = LED.default_lightbar
  end
  local stroke = settings.controller_stroke_width
  local stroke_text = string.format("%.2f", stroke)
  local grip_text = string.format("%.2f", stroke * 0.625)
  local body_opacity_text = string.format("%.2f", settings.controller_body_opacity)

  local dir = noctalia.pluginDataDir()
  if not dir then
    return fallback
  end
  local path = dir .. "/dualsense-v1-" .. color_key(line) .. "-" .. color_key(body)
    .. "-" .. color_key(lb) .. "-" .. color_key(stroke_text)
    .. "-" .. color_key(body_opacity_text) .. ".svg"
  if path == art_path then
    return path
  end
  local template = noctalia.readFile("assets/controller-template.svg")
  if not template then
    return fallback
  end

  local svg = string.gsub(template, "{{BODY}}", body)
  svg = string.gsub(svg, "{{BODY_OPACITY}}", body_opacity_text)
  svg = string.gsub(svg, "{{COLOR}}", line)
  svg = string.gsub(svg, "{{LIGHTBAR}}", lb)
  svg = string.gsub(svg, "{{STROKE_BODY}}", stroke_text)
  svg = string.gsub(svg, "{{STROKE_GRIP}}", grip_text)
  local written = noctalia.writeFile(path, svg)
  if not written then
    return fallback
  end
  return path
end

art_path = controller_art()

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

local function mode_of()
  local s = type(current_state) == "table" and current_state or {}
  local is_fresh = fresh()
  local connected = is_fresh and s.connected == true
  local charging = is_fresh and s.charging == true
  local full = is_fresh and s.full == true
  local pct = is_fresh and tonumber(s.battery_pct) or -1
  if not pct then
    pct = -1
  end
  local known = pct >= 0
  local low = connected and not charging and known and pct <= low_threshold

  local mode = "disconnected"
  if charging and not full then
    mode = "charging"
  elseif connected then
    mode = low and "low" or "ok"
  end

  return mode, connected, charging and not full, pct, known, is_fresh
end

local function state_color(mode, connected, s)
  if mode == "low" then
    return settings.battery_low_color
  end
  if mode == "disconnected" then
    return "on_surface_variant/0.55"
  end
  if settings.battery_color_mode == "custom" then
    return settings.battery_fill_color
  end
  if settings.battery_color_mode == "lightbar" then
    return active_lightbar_hex()
  end
  if mode == "charging" and not connected then
    return LED.charging
  end
  local connection = s.connection or ""
  if connection == "usb" then
    return LED.cable
  end
  if connection == "bluetooth" then
    return LED.bluetooth
  end
  return active_lightbar_hex()
end

local function status_text(mode, s, is_fresh)
  if not is_fresh then
    return noctalia.tr("status.waiting")
  end
  if type(s) == "table" and s.error == "python3" then
    return noctalia.tr("status.no_python")
  end
  if mode == "charging" then
    if s.connection == "usb" then
      return noctalia.tr("status.charging_usb")
    end
    return noctalia.tr("status.charging_cable")
  end
  if mode == "low" then
    return noctalia.tr("status.low")
  end
  if mode == "ok" then
    if s.full then
      return noctalia.tr("status.full")
    end
    return noctalia.tr("status.connected")
  end
  return noctalia.tr("status.disconnected")
end

local function link_glyph(mode, connected, s)
  if mode == "charging" then
    return "bolt"
  end
  if not connected then
    return nil
  end
  local connection = s.connection or ""
  if connection == "bluetooth" then
    return "bluetooth"
  end
  if connection == "usb" then
    return "usb"
  end
  return "device-gamepad-2"
end

local function marker_color(mode, connected, s)
  if mode == "low" then
    return settings.battery_low_color
  end
  if mode == "charging" then
    if s.connection == "usb" then
      return LED.cable
    end
    if s.connection == "bluetooth" then
      return LED.bluetooth
    end
    return LED.charging
  end
  if not connected then
    return settings.muted_text_color
  end
  if s.connection == "bluetooth" then
    return LED.bluetooth
  end
  if s.connection == "usb" then
    return LED.cable
  end
  return settings.text_color
end

local function pct_row(pct, known, shown, provisional, mode)
  local children = {}

  if shown and known then
    local opacity = provisional and 0.55 or 1
    table.insert(children, ui.label({
      key = "pct-value",
      text = tostring(math.floor(pct + 0.5)),
      fontSize = 30,
      fontWeight = "semibold",
      color = mode == "low" and settings.battery_low_color or settings.text_color,
      opacity = opacity,
    }))
    table.insert(children, ui.label({
      key = "pct-sign",
      text = "%",
      fontSize = 16,
      fontWeight = "medium",
      color = mode == "low" and settings.battery_low_color or settings.muted_text_color,
      opacity = opacity,
    }))
    if provisional then
      table.insert(children, ui.glyph({
        key = "pct-clock",
        name = "clock",
        size = 12,
        color = settings.muted_text_color,
        opacity = 0.7,
      }))
    end
  else
    table.insert(children, ui.label({
      key = "pct-value",
      text = "—",
      fontSize = 30,
      fontWeight = "semibold",
      color = settings.muted_text_color,
    }))
  end

  return ui.row({ key = "pct-row", gap = 2, align = "end", justify = "center" }, children)
end

local function status_row(mode, connected, charging, s, is_fresh)
  local children = {}
  local glyph = link_glyph(mode, connected, s)

  if glyph then
    table.insert(children, ui.glyph({
      key = "status-glyph",
      name = glyph,
      size = 13,
      color = marker_color(mode, connected, s),
      opacity = charging and pulse or 1,
    }))
  end

  local text_color = mode == "low" and settings.battery_low_color
    or (is_fresh and settings.text_color or settings.muted_text_color)

  table.insert(children, ui.label({
    key = "status-text",
    text = status_text(mode, s, is_fresh),
    fontSize = 12,
    color = text_color,
  }))

  return ui.row({ key = "status-row", gap = 5, align = "center", justify = "center" }, children)
end

local function player_leds_node(connected, s)
  if not connected or not settings.show_player_leds then
    return nil
  end
  local idx = tonumber(s.player_leds) or 1
  local pattern = PLAYER_LED_PATTERNS[idx] or PLAYER_LED_PATTERNS[1]
  local dots = {}
  for i = 1, 5 do
    local lit = pattern[i] == true
    table.insert(dots, ui.box({
      key = "player-led-" .. i,
      width = lit and 8 or 5,
      height = 3,
      radius = 1.5,
      fill = lit and settings.text_color or settings.muted_text_color,
      opacity = lit and 0.95 or 0.3,
    }))
  end
  return ui.row({
    key = "player-leds-row",
    gap = 4,
    align = "center",
    justify = "center",
  }, dots)
end

local function profile_row(s, is_fresh)
  if not is_fresh or not settings.show_profile then
    return nil
  end
  local prof = type(s.profile) == "string" and s.profile ~= "" and s.profile or "Default"
  local profiles = type(s.profiles) == "table" and s.profiles or { prof }
  local options = {}
  local selected_index = 0
  for _, name in ipairs(profiles) do
    if type(name) == "string" and name ~= "" then
      if name == prof then
        selected_index = #options
      end
      table.insert(options, name)
    end
  end
  if #options == 0 then
    options = { prof }
    selected_index = 0
  end
  local lb = active_lightbar_hex()
  local header_children = {
    ui.row({
      key = "profile-select",
      width = 104,
      height = 24,
      padding = 6,
      gap = 4,
      align = "center",
      radius = 5,
      fill = "surface/0.9",
      border = with_alpha(settings.muted_text_color, 0.6),
      borderWidth = 1,
      onClick = "onToggleProfileMenu",
    }, {
      ui.box({
        key = "lightbar-dot",
        width = 7,
        height = 7,
        radius = 3.5,
        fill = lb,
      }),
      ui.label({
        key = "profile-name",
        text = options[selected_index + 1] or prof,
        fontSize = 11,
        color = settings.text_color,
        flexGrow = 1,
      }),
      ui.glyph({
        key = "profile-chevron",
        name = profile_menu_open and "chevron-up" or "chevron-down",
        size = 11,
        color = settings.muted_text_color,
      }),
    }),
    ui.row({
      key = "profile-settings",
      tooltip = noctalia.tr("actions.open_ds4u"),
      width = 28,
      height = 28,
      radius = 6,
      fill = "surface/" .. string.format("%.2f", settings.profile_settings_opacity),
      border = with_alpha(settings.muted_text_color, settings.profile_settings_opacity),
      borderWidth = 1,
      align = "center",
      justify = "center",
      onClick = "onOpenDs4u",
    }, {
      ui.glyph({
        key = "profile-settings-icon",
        name = "settings",
        size = 15,
        color = settings.text_color,
        opacity = 1.0,
      }),
    }),
  }
  local header = ui.row({
    key = "profile-row",
    gap = 5,
    align = "center",
    justify = "center",
  }, header_children)

  local children = { header }
  if profile_menu_open then
    local option_nodes = {}
    for i, name in ipairs(options) do
      local option_name = name
      table.insert(option_nodes, ui.row({
        key = "profile-option-" .. i,
        width = 104,
        height = 22,
        padding = 6,
        align = "center",
        radius = 4,
        fill = option_name == prof and "primary/0.8" or "surface/0.95",
        onClick = function()
          profile_menu_open = false
          onProfileChanged(tostring(i - 1), option_name)
          render()
        end,
      }, {
        ui.label({
          text = option_name,
          fontSize = 11,
          color = option_name == prof and "surface" or settings.text_color,
        }),
      }))
    end
    table.insert(children, ui.column({
      key = "profile-menu",
      gap = 2,
      align = "center",
    }, option_nodes))
  end

  return ui.column({ key = "profile-control", gap = 2, align = "center" }, children)
end

render = function()
  local s = type(current_state) == "table" and current_state or {}
  local mode, connected, charging, pct, known, is_fresh = mode_of()
  local off = mode == "disconnected"
  local dim = off and (is_fresh and 0.55 or 0.8) or 1
  local color = state_color(mode, connected, s)

  local left_children = {
    ui.image({
      key = "controller-art",
      path = art_path,
      width = 123,
      height = 92,
      fit = "contain",
      onClick = "onBuzzController",
    }),
  }

  local leds = player_leds_node(connected, s)
  if leds then
    table.insert(left_children, leds)
  else
    table.insert(left_children, ui.spacer({ key = "art-gap", height = 6, flexGrow = 0 }))
  end

  table.insert(left_children, pct_row(pct, known, known and not off, s.provisional == true, mode))
  table.insert(left_children, status_row(mode, connected, charging, s, is_fresh))

  if connected and settings.show_model_badge and (s.model == "edge" or s.model == "ds4") then
    table.insert(left_children, ui.label({
      key = "model-badge",
      text = s.model == "ds4" and noctalia.tr("status.model_ds4") or noctalia.tr("status.model_edge"),
      fontSize = 11,
      color = settings.muted_text_color,
      opacity = 0.85,
    }))
  end

  local prof = profile_row(s, is_fresh)
  if prof then
    table.insert(left_children, prof)
  end

  local left = ui.column({
    key = "left",
    width = 180,
    gap = 2,
    align = "center",
    opacity = dim,
  }, left_children)

  local fill_height = 0
  if known and not off then
    fill_height = math.floor(INNER_H * math.max(0, math.min(100, pct)) / 100 + 0.5)
  end

  local body_children = {}
  if fill_height > 0 then
    table.insert(body_children, ui.box({
      key = "battery-fill",
      width = BODY_W - 10,
      height = fill_height,
      radius = 7,
      fill = color,
      opacity = (charging and pulse or 1) * settings.battery_fill_opacity,
    }))
  end

  local battery = ui.column({ key = "battery", gap = 3, align = "center", opacity = dim }, {
    ui.box({
      key = "battery-nub",
      width = 22,
      height = 5,
      radius = 2,
      fill = with_alpha(settings.muted_text_color, 1),
    }),
    ui.column({
      key = "battery-body",
      width = BODY_W,
      height = BODY_H,
      radius = 12,
      border = with_alpha(settings.muted_text_color, 1),
      borderWidth = 2,
      padding = 5,
      justify = "end",
      align = "stretch",
    }, body_children),
  })

  local row = ui.row({
    key = "content",
    gap = 20,
    align = "center",
    justify = "center",
  }, { left, battery })

  if type(desktopWidget.setNeedsFrameTick) == "function" then
    desktopWidget.setNeedsFrameTick(mode == "charging")
  end

  desktopWidget.render(ui.column({
    key = "card",
    align = "center",
    padding = 2,
  }, { row }))
end

function onCycleProfile()
  action_seq = action_seq + 1
  noctalia.state.set("action", { action = "cycle-profile", seq = action_seq })
end

function onProfileChanged(index, text)
  local profile = type(text) == "string" and text or ""
  if profile == "" then
    local s = type(current_state) == "table" and current_state or {}
    local profiles = type(s.profiles) == "table" and s.profiles or {}
    profile = profiles[(tonumber(index) or -1) + 1] or ""
  end
  if profile == "" then
    return
  end
  local current = type(current_state) == "table" and current_state.profile or ""
  if profile == current then
    return
  end
  action_seq = action_seq + 1
  noctalia.state.set("action", {
    action = "switch-profile",
    profile = profile,
    seq = action_seq,
  })
end

function onToggleProfileMenu()
  profile_menu_open = not profile_menu_open
  render()
end

function onBuzzController()
  action_seq = action_seq + 1
  noctalia.state.set("action", { action = "buzz", seq = action_seq })
end

function onOpenDs4u()
  local home = type(noctalia.getenv) == "function" and noctalia.getenv("HOME") or ""
  local candidates = {
    home ~= "" and home .. "/bin/ds4u" or "",
    home ~= "" and home .. "/.local/bin/ds4u" or "",
    "/usr/local/bin/ds4u",
    "/usr/bin/ds4u",
  }
  if type(noctalia.fileExists) == "function" then
    for _, path in ipairs(candidates) do
      if path ~= "" and noctalia.fileExists(path) then
        noctalia.runAsync(string.format("%q", path))
        return
      end
    end
  end
  if type(noctalia.commandExists) ~= "function" or noctalia.commandExists("ds4u") then
    noctalia.runAsync("ds4u")
  end
end

function onFrameTick(delta_ms)
  local mode = mode_of()
  if mode ~= "charging" then
    return
  end

  frame_accum = frame_accum + (tonumber(delta_ms) or 16)
  if frame_accum < 33 then
    return
  end

  pulse_phase = (pulse_phase + frame_accum / 380) % (math.pi * 2)
  frame_accum = 0
  pulse = 0.35 + 0.65 * (0.5 + 0.5 * math.cos(pulse_phase))
  render()
end

function update()
  art_path = controller_art()
  render()
end

current_state = noctalia.state.get("controller")
art_path = controller_art()
noctalia.setUpdateInterval(1000)
noctalia.state.watch("controller", function(value)
  current_state = value
  art_path = controller_art()
  render()
end)
render()
