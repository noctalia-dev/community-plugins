--!nonstrict
-- The device card displays only connection and battery data reported by NectarLink.
local palette = require("../palette.luau")
local charge = require("../battery.luau")

local M = { height = 144 }
local padding, gap = 12, 12
local accentWidth, previewWidth, batteryWidth = 4, 76, 154
local refreshWidth = 30

local function phonePreview(online)
  return ui.column({
    key = "phone-preview",
    width = previewWidth,
    height = 120,
    padding = 4,
    gap = 3,
    radius = 15,
    fill = palette("raised"),
    border = palette("muted_border"),
    borderWidth = 1,
    align = "center",
    opacity = online and 1 or 0.55,
  }, {
    ui.box({ width = 9, height = 3, radius = 2, fill = "on_surface_variant/0.7" }),
    ui.column({
      key = "phone-preview-screen",
      width = 66,
      height = 94,
      radius = 11,
      fill = "primary/0.08",
      align = "center",
      justify = "center",
    }, { ui.glyph({ name = "hexagon", size = 32, color = "primary" }) }),
    ui.box({ width = 22, height = 2, radius = 1, fill = "on_surface_variant/0.72" }),
  })
end

function M.render(context, width, model, components, actions)
  local phone, online = context.phone, context.online
  local label = components.label
  local battery = phone and phone.battery
  local level = battery and tonumber(battery.level)
  if level then
    level = math.floor(math.max(0, math.min(100, level)) + 0.5)
  end
  local showBattery = components.setting("panel_battery")
  local infoWidth = width - 2 * padding - accentWidth - previewWidth - 3 * gap
    - (showBattery and (1 + gap + batteryWidth) or refreshWidth)

  local refresh = ui.button({
    key = "refresh-home",
    glyph = "refresh",
    glyphSize = 16,
    width = refreshWidth,
    height = refreshWidth,
    variant = "ghost",
    tooltip = noctalia.tr("common.refresh"),
    onClick = function()
      actions.send("refresh")
    end,
  })

  local deviceName = label(
    phone and phone.name or noctalia.tr("common.disconnected"),
    22,
    "on_surface",
    true,
    infoWidth
  )
  if #model.snapshot.devices > 1 then
    local names, ids, index = {}, {}, 0
    for i, device in ipairs(model.snapshot.devices) do
      names[i] = components.preview(device.name, 42)
      ids[i] = device.id
      if device.id == model.selected then
        index = i - 1
      end
    end
    deviceName = ui.select({
      key = "device-picker",
      options = names,
      selectedIndex = index,
      controlSize = "sm",
      width = infoWidth,
      onChange = function(value)
        local i = tonumber(value)
        if i and ids[i + 1] then
          model.selected = ids[i + 1]
          actions.render()
        end
      end,
    })
  end

  local link = online and ({
    lan = noctalia.tr("connection.lan"),
    usb = "USB",
    relay = noctalia.tr("connection.relay"),
  })[phone.link] or nil
  local status = online and noctalia.tr("connection.connected") or noctalia.tr("connection.offline")
  if link then
    status = status .. " · " .. link
  end
  local info = {
    deviceName,
    label(phone and phone.platform or noctalia.tr("common.phone"), 12, "on_surface_variant", false, infoWidth),
    ui.row({
      key = "phone-link",
      height = 25,
      paddingH = 8,
      gap = 6,
      radius = 12,
      align = "center",
      fill = palette("raised"),
    }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = online and "secondary" or "on_surface_variant" }),
      label(status, 11, "on_surface", false, infoWidth - 30),
    }),
  }
  if not context.ready then
    local title, detail = components.failure(model.snapshot.error or "api_unavailable")
    info[#info + 1] = ui.row({
      key = "connection-error",
      height = 20,
      tooltip = detail,
    }, { label(title, 11, "error", false, infoWidth) })
  end

  local children = {
    ui.box({
      width = accentWidth, height = 112, radius = 2,
      fill = online and "primary" or "on_surface_variant/0.35",
    }),
    phonePreview(online),
    ui.column({
      key = "phone-info",
      width = infoWidth,
      height = 120,
      gap = 4,
      align = "start",
      justify = "center",
    }, info),
  }

  if showBattery then
    local charging = battery and battery.charging
    local accent = level and level <= 20 and not charging and "error" or "primary"
    local power = {
      ui.row({ height = refreshWidth, align = "center" }, {
        ui.glyph({ name = charging and "battery-charging" or "battery", size = 21, color = "on_surface" }),
        ui.spacer({ flexGrow = 1 }),
        refresh,
      }),
      label(level and (level .. "%") or "—", 28, "on_surface", true, batteryWidth),
    }
    if level then
      power[#power + 1] = ui.progress({
        progress = level / 100,
        width = batteryWidth,
        height = 7,
        radius = 4,
        fill = accent,
        track = "on_surface_variant/0.22",
      })
    end
    local batteryState = not level and "battery.unknown"
      or not online and "common.last_known"
      or charging and "battery.charging"
      or "battery.discharging"
    local estimate = online and level and charge.estimate(battery)
    local text = estimate and noctalia.tr("battery.estimate_card", { estimate = estimate })
      or noctalia.tr(batteryState)
    power[#power + 1] = label(text, 11, "on_surface_variant", false, batteryWidth)

    children[#children + 1] = ui.box({
      width = 1, height = 106, fill = palette("muted_border", 0.55),
    })
    children[#children + 1] = ui.column({
      key = "phone-battery",
      width = batteryWidth,
      height = 120,
      gap = 5,
      justify = "center",
    }, power)
  else
    children[#children + 1] = ui.column({ width = refreshWidth, height = 120 }, { refresh })
  end

  return ui.row({
    key = "device",
    width = width,
    height = M.height,
    padding = padding,
    gap = gap,
    align = "center",
    radius = 16,
    fill = palette("card"),
  }, children)
end

return M
