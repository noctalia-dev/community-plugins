--!nonstrict
-- Phone and session controls. Unknown state must not be represented as off.
local palette = require("./palette.luau")
local M = {}
function M.new(model, components, actions)
  local geometry = require("./components.luau").layout
  local activeSession = components.activeSession
  local label = components.label
  local send = actions.send
  local render = actions.render
  local function controlsCard(phone, online)
    local controls = phone and phone.controls
    local state = controls and controls.state
    local allowed = controls and controls.allowed or {}
    local rows = {
      ui.row({ width = 244, height = 28, gap = 5, align = "center" }, {
        ui.label({
          text = noctalia.tr("controls.title"),
          maxWidth = 211,
          maxLines = 1,
          fontFamily = "sans-serif",
          fontSize = 12,
          fontWeight = "bold",
          flexGrow = 1,
        }),
        ui.button({
          glyph = "external-link",
          width = 28,
          height = 28,
          controlSize = "sm",
          variant = "ghost",
          tooltip = noctalia.tr("common.open_app"),
          onClick = function()
            send("open")
          end,
        }),
      }),
    }
    local chips = {}
    for _, def in ipairs({
      { "dnd", noctalia.tr("controls.dnd"), "moon" },
      { "flashlight", noctalia.tr("controls.flashlight"), "bolt" },
      { "wifi", noctalia.tr("controls.wifi"), "wifi" },
      { "bluetooth", noctalia.tr("controls.bluetooth"), "bluetooth" },
      { "hotspot", noctalia.tr("controls.hotspot"), "world" },
    }) do
      local id, title, glyph = def[1], def[2], def[3]
      local active = type(state) == "table" and state[id] == true
      local known = type(state) == "table" and type(state[id]) == "boolean"
      local enabled = online
        and not model.snapshot.controlBusy
        and allowed[id] == true
        and (known or id == "hotspot")
      local reason = not online and noctalia.tr("common.phone_offline")
        or (
          not controls and noctalia.tr("controls.update_required")
          or (
            not allowed[id] and noctalia.tr("controls.permission")
            or (
              id == "hotspot" and noctalia.tr("controls.hotspot_hint")
              or (not known and noctalia.tr("controls.unknown") or title)
            )
          )
        )
      table.insert(
        chips,
        ui.column({
          key = "control-" .. id,
          width = 44,
          height = 54,
          gap = 5,
          padding = 4,
          radius = 10,
          align = "center",
          justify = "center",
          opacity = enabled and 1 or 0.45,
          fill = active and "primary/0.25" or palette("raised"),
          tooltip = reason,
          onClick = enabled and function()
            if id == "wifi" and active then
              model.confirmWifi = phone.id
              model.hotspotMenu = nil
              render()
            elseif id == "hotspot" then
              model.hotspotMenu = phone.id
              model.confirmWifi = nil
              render()
            else
              send("phone_toggle", phone.id, { id = id, on = not active })
            end
          end or nil,
        }, {
          ui.glyph({
            name = glyph,
            size = 17,
            color = active and "primary" or "on_surface_variant",
          }),
          label(title, 9, "on_surface_variant", false, 36),
        })
      )
    end
    table.insert(rows, ui.row({ width = 244, gap = 4, justify = "center" }, chips))
    if phone and model.confirmWifi == phone.id then
      table.insert(rows, label(noctalia.tr("controls.wifi_confirmation"), 10, "primary"))
      table.insert(
        rows,
        ui.row({ gap = 5 }, {
          ui.button({
            text = noctalia.tr("common.cancel"),
            controlSize = "sm",
            variant = "ghost",
            onClick = function()
              model.confirmWifi = nil
              render()
            end,
          }),
          ui.button({
            text = noctalia.tr("controls.turn_off"),
            controlSize = "sm",
            variant = "destructive",
            enabled = online and allowed.wifi == true and not model.snapshot.controlBusy,
            onClick = function()
              model.confirmWifi = nil
              send("phone_toggle", phone.id, { id = "wifi", on = false, confirm_disconnect = true })
              render()
            end,
          }),
        })
      )
    elseif phone and model.hotspotMenu == phone.id then
      local buttons = {}
      for _, choice in ipairs({
        { noctalia.tr("controls.on"), true },
        { noctalia.tr("controls.off"), false },
      }) do
        local on = choice[2]
        table.insert(
          buttons,
          ui.button({
            text = choice[1],
            controlSize = "sm",
            variant = "secondary",
            enabled = online and allowed.hotspot == true and not model.snapshot.controlBusy,
            onClick = function()
              model.hotspotMenu = nil
              send("phone_toggle", phone.id, { id = "hotspot", on = on })
              render()
            end,
          })
        )
      end
      table.insert(
        buttons,
        ui.button({
          glyph = "x",
          controlSize = "sm",
          variant = "ghost",
          onClick = function()
            model.hotspotMenu = nil
            render()
          end,
        })
      )
      table.insert(rows, ui.row({ gap = 5 }, buttons))
    end
    local session = phone and model.snapshot.sessions and model.snapshot.sessions[phone.id]
    local phases = {
      preparing = noctalia.tr("sessions.preparing"),
      asking = noctalia.tr("sessions.asking"),
      watching = noctalia.tr("sessions.watching"),
      playing = noctalia.tr("sessions.playing"),
      enabled = noctalia.tr("sessions.enabled"),
    }
    for _, def in ipairs({
      { noctalia.tr("sessions.pc_audio"), "volume", "pc_audio" },
      { noctalia.tr("sessions.watch"), "video", "watch" },
      { noctalia.tr("sessions.phone_audio"), "headphones", "phone_audio" },
    }) do
      local kind = def[3]
      local active = activeSession(session, kind)
      local enabled = not model.snapshot.sessionBusy
        and session
        and (active or (online and session.allowed[kind]))
      local text = active and (phases[session[kind]] or session[kind])
        or (not enabled and noctalia.tr("sessions.unavailable") or "")
      table.insert(
        rows,
        ui.row({
          key = "session-row-" .. kind,
          width = 244,
          height = 32,
          gap = 6,
          padding = 3,
          radius = 9,
          fill = palette("raised"),
          tooltip = kind == "watch" and noctalia.tr("sessions.watch_hint")
            or noctalia.tr("sessions.control_hint"),
        }, {
          ui.glyph({ name = def[2], size = 15, color = "on_surface_variant" }),
          ui.column({ gap = 0, flexGrow = 1, height = 26, align = "start", justify = "center" }, {
            ui.column({ height = 14, align = "start", justify = "center" }, {
              ui.label({
                text = def[1],
                fontFamily = "sans-serif",
                fontSize = 10,
                maxWidth = 184,
                maxLines = 1,
              }),
            }),
            ui.column({
              height = 12,
              align = "start",
              justify = "center",
              visible = text ~= "",
            }, {
              ui.label({
                text = text,
                fontFamily = "sans-serif",
                fontSize = 9,
                maxWidth = 184,
                maxLines = 1,
                color = "on_surface_variant",
              }),
            }),
          }),
          ui.toggle({
            key = "session-" .. kind,
            checked = active,
            enabled = enabled == true,
            width = 30,
            height = 18,
            onChange = function(value)
              if enabled then
                send("session", phone.id, { kind = kind, on = value == "true" or value == true })
              end
            end,
          }),
        })
      )
    end
    return ui.column({
      key = "phone-controls",
      width = 260,
      gap = 7,
      padding = 8,
      radius = 14,
      align = "start",
      fill = palette("card", 0.75),
    }, rows)
  end

  local function ringerCard(phone, online)
    local controls = phone and phone.controls
    local mode = controls and controls.state and controls.state.ringer
    local known = mode == "ring" or mode == "vibrate" or mode == "silent"
    local allowed = controls and controls.allowed and controls.allowed.ringer == true
    local enabled = online and allowed and known and not model.snapshot.controlBusy
    local buttons = {}
    for _, choice in ipairs({
      { "ring", noctalia.tr("controls.ring") },
      { "vibrate", noctalia.tr("controls.vibrate") },
      { "silent", noctalia.tr("common.silent") },
    }) do
      local value, title = choice[1], choice[2]
      table.insert(
        buttons,
        ui.button({
          key = "ringer-" .. value,
          text = title,
          width = 80,
          height = 32,
          fontSize = 10,
          controlSize = "sm",
          variant = known and mode == value and "secondary" or "ghost",
          enabled = enabled == true,
          tooltip = not online and noctalia.tr("common.phone_offline")
            or (
              not allowed and noctalia.tr("controls.permission")
              or (not known and noctalia.tr("controls.unknown") or title)
            ),
          onClick = enabled and function()
            if mode ~= value then
              send("phone_toggle", phone.id, { id = "ringer", mode = value })
            end
          end or nil,
        })
      )
    end
    return ui.row({
      key = "ringer-controls",
      width = 260,
      height = 40,
      padding = 4,
      gap = 6,
      radius = 12,
      fill = palette("card", 0.75),
      align = "center",
    }, buttons)
  end
  return { render = controlsCard, ringer = ringerCard }
end
return M
