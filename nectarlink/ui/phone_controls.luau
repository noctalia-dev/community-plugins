--!nonstrict
-- The controls reflect the selected phone. Unknown state is not treated as off.
local palette = require("./palette.luau")

local M = {}
local gap, padding = 6, 10
local chipDefinitions = {
  { id = "dnd", title = "controls.dnd", icon = "moon" },
  { id = "flashlight", title = "controls.flashlight", icon = "bolt" },
  { id = "wifi", title = "controls.wifi", icon = "wifi" },
  { id = "bluetooth", title = "controls.bluetooth", icon = "bluetooth" },
  { id = "hotspot", title = "controls.hotspot", icon = "world" },
}
local ringerDefinitions = {
  { id = "ring", title = "controls.ring", icon = "volume", width = 72 },
  { id = "vibrate", title = "controls.vibrate", icon = "device-mobile-vibration", width = 104 },
  { id = "silent", title = "common.silent", icon = "volume-off", width = 96 },
}
local sessionDefinitions = {
  { id = "pc_audio", title = "sessions.pc_audio_short", hint = "sessions.pc_audio_caption", icon = "speakerphone" },
  { id = "watch", title = "sessions.watch_short", hint = "sessions.watch_caption", icon = "device-tv" },
  { id = "phone_audio", title = "sessions.phone_audio_short", hint = "sessions.phone_audio_caption", icon = "headphones" },
}
local phaseKeys = {
  preparing = "sessions.preparing", asking = "sessions.asking", watching = "sessions.watching",
  playing = "sessions.playing", enabled = "sessions.enabled",
}

local function splitWidth(width, count, index)
  local available = width - gap * (count - 1)
  return math.floor(available / count) + (index <= available % count and 1 or 0)
end

function M.new(model, components, actions)
  local label, send, render = components.label, actions.send, actions.render

  local function phoneState(phone)
    local controls = phone and phone.controls
    return controls and controls.state or {}, controls and controls.allowed or {}, controls
  end

  local function ringerButtons(phone, online)
    local state, allowed = phoneState(phone)
    local mode = state.ringer
    local known = mode == "ring" or mode == "vibrate" or mode == "silent"
    local enabled = online and allowed.ringer == true and known and not actions.actionBusy("control")
    local dispatch = actions.bindAction("control", phone and phone.id)
    local buttons, width = {}, 6 + (#ringerDefinitions - 1) * 5
    for i, def in ipairs(ringerDefinitions) do
      local id, title = def.id, noctalia.tr(def.title)
      buttons[i] = ui.button({
        key = "ringer-" .. id,
        text = title,
        glyph = def.icon,
        glyphSize = 13,
        width = def.width,
        height = 30,
        fontSize = 10,
        variant = known and mode == id and "primary" or "ghost",
        enabled = enabled,
        tooltip = not online and noctalia.tr("common.phone_offline")
          or (not allowed.ringer and noctalia.tr("controls.permission"))
          or (not known and noctalia.tr("controls.unknown")) or title,
        onClick = enabled and function()
          if mode ~= id then
            dispatch({ id = "ringer", mode = id })
          end
        end or nil,
      })
      width = width + def.width
    end
    return ui.row({
      key = "ringer-controls", width = width, height = 36, padding = 3, gap = 5, radius = 9,
      align = "center", fill = palette("raised", 0.72),
    }, buttons)
  end

  local function sessionRow(phone, online, width)
    local states = model.snapshot.sessions
    local session = phone and states and states[phone.id]
    local cards = {}
    for i, def in ipairs(sessionDefinitions) do
      local kind = def.id
      local cardWidth = splitWidth(width, #sessionDefinitions, i)
      local active = components.activeSession(session, kind)
      local enabled = not model.snapshot.sessionBusy and session
        and (active or (online and session.allowed and session.allowed[kind])) == true
      local phase = active and phaseKeys[session[kind]]
      local caption = noctalia.tr(phase or (enabled and def.hint or "sessions.unavailable"))
      -- Reserve the native toggle's full width before measuring the text.
      local textWidth = cardWidth - 80
      cards[i] = ui.row({
        key = "session-row-" .. kind,
        width = cardWidth,
        height = 46,
        gap = 5,
        padding = 6,
        radius = 9,
        align = "center",
        fill = palette("raised", 0.62),
        tooltip = kind == "watch" and noctalia.tr("sessions.watch_hint") or noctalia.tr("sessions.control_hint"),
      }, {
        ui.glyph({ name = def.icon, size = 18, color = active and "primary" or "on_surface_variant" }),
        ui.column({ width = textWidth, gap = 1, justify = "center", align = "start" }, {
          label(noctalia.tr(def.title), 10, "on_surface", true, textWidth),
          label(caption, 9, "on_surface_variant", false, textWidth),
        }),
        ui.toggle({
          key = "session-" .. kind,
          checked = active,
          enabled = enabled == true,
          width = 40,
          height = 18,
          onChange = function(value)
            if enabled then
              send("session", phone.id, { kind = kind, on = value == "true" or value == true })
            end
          end,
        }),
      })
    end
    return ui.row({ key = "session-strip", width = width, height = 46, gap = gap }, cards)
  end

  local function chipRow(phone, online, width)
    local state, allowed, controls = phoneState(phone)
    local dispatch = actions.bindAction("control", phone and phone.id)
    local busy = actions.actionBusy("control")
    local scope = model.actionScope
    local chips = {}
    for i, def in ipairs(chipDefinitions) do
      local id, title = def.id, noctalia.tr(def.title)
      local active = state[id] == true
      local known = type(state[id]) == "boolean"
      local enabled = online and not busy and allowed[id] == true
        and (known or id == "hotspot")
      local reason = not online and noctalia.tr("common.phone_offline")
        or (not controls and noctalia.tr("controls.update_required"))
        or (not allowed[id] and noctalia.tr("controls.permission"))
        or (busy and noctalia.tr("common.sending"))
        or (id == "hotspot" and noctalia.tr("controls.hotspot_hint"))
        or (id == "wifi" and active and noctalia.tr("controls.wifi_off_hint"))
        or (not known and noctalia.tr("controls.unknown")) or title
      local chipWidth = splitWidth(width, #chipDefinitions, i)
      chips[i] = ui.row({
        key = "control-" .. id,
        width = chipWidth,
        height = 34,
        gap = 6,
        paddingH = 6,
        radius = 9,
        align = "center",
        justify = "center",
        opacity = enabled and 1 or 0.5,
        fill = active and "primary/0.20" or palette("raised", 0.62),
        tooltip = reason,
        onClick = enabled and function()
          if id == "hotspot" then
            if not model.opened or model.selected ~= phone.id or model.actionScope ~= scope
              or actions.actionBusy("control") then return end
            model.hotspotMenu = phone.id
            render()
          else
            dispatch({ id = id, on = not active, confirm_disconnect = id == "wifi" and active or nil })
          end
        end or nil,
      }, {
        ui.glyph({ name = def.icon, size = 16, color = active and "primary" or "on_surface_variant" }),
        label(title, 10, active and "primary" or "on_surface_variant", false, chipWidth - 34),
      })
    end
    return ui.row({ key = "phone-switches", width = width, height = 34, gap = gap }, chips)
  end

  local function hotspotChoices(phone, online, width)
    if not phone then
      return nil
    end
    local _, allowed = phoneState(phone)
    local row = { key = "hotspot-choices", width = width, height = 46, gap = gap, align = "center" }
    if model.hotspotMenu == phone.id then
      local buttons = {
        label(noctalia.tr("controls.hotspot"), 11, "on_surface", true, width - 176),
        ui.spacer({ flexGrow = 1 }),
      }
      local enabled = online and allowed.hotspot == true and not actions.actionBusy("control")
      local dispatch = actions.bindAction("control", phone.id)
      for _, on in ipairs({ true, false }) do
        buttons[#buttons + 1] = ui.button({
          key = on and "hotspot-on" or "hotspot-off",
          text = noctalia.tr(on and "controls.on" or "controls.off"),
          controlSize = "sm",
          variant = "secondary",
          enabled = enabled,
          onClick = enabled and function()
            if model.hotspotMenu == phone.id then dispatch({ id = "hotspot", on = on }) end
          end or nil,
        })
      end
      buttons[#buttons + 1] = components.smallButton(noctalia.tr("common.cancel"), function()
        model.hotspotMenu = nil
        render()
      end)
      return ui.row(row, buttons)
    end
  end

  local function controlsCard(phone, online, width, height, settingsButton)
    local innerWidth = width - 2 * padding
    local ringer = ringerButtons(phone, online)
    local titleWidth = innerWidth - 20 - ringer.props.width - 30 - 4 * gap
      - (settingsButton and (36 + gap) or 0)
    local heading = {
      ui.glyph({ name = "volume", size = 20, color = "on_surface" }),
      label(noctalia.tr("controls.sound_title"), 14, "on_surface", true, titleWidth),
      ui.spacer({ flexGrow = 1 }),
      ringer,
      ui.button({
        glyph = "external-link", width = 30, height = 30, variant = "ghost",
        tooltip = noctalia.tr("common.open_app"),
        onClick = function()
          send("open")
        end,
      }),
    }
    if settingsButton then
      heading[#heading + 1] = settingsButton
    end
    -- The hotspot picker uses the session row's slot to preserve the layout.
    return ui.column({
      key = "phone-controls",
      width = width,
      height = height,
      padding = padding,
      gap = gap,
      radius = 14,
      justify = "space_between",
      fill = palette("card"),
    }, {
      ui.row({ width = innerWidth, height = 36, gap = gap, align = "center" }, heading),
      ui.box({ width = innerWidth, height = 1, fill = palette("muted_border", 0.4) }),
      hotspotChoices(phone, online, innerWidth) or sessionRow(phone, online, innerWidth),
      chipRow(phone, online, innerWidth),
    })
  end

  return { render = controlsCard }
end

return M
