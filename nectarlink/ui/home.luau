--!nonstrict
-- The two Home columns stay independent: live activity never hides the controls.
local geometry = require("./components.luau").layout
local deviceCard = require("./home/device.luau")
local shortcuts = require("./home/actions.luau")
local activity = require("./home/activity.luau")
local setup = require("./home/setup.luau")

local M = {}
local gap = 8

function M.new(model, components, actions, controls, frame)
  local setting = components.setting

  local function render(context)
    local phone = context.phone
    if context.ready and phone then
      model.connectedOnce = true
    end

    local settingsButton = not setting("panel_navigation") and frame.settingsButton() or nil
    -- Keep first-run guidance out of the normal layout, including on brief
    -- disconnects after a phone has already been seen.
    if (not context.ready and not model.connectedOnce) or (context.ready and not phone) then
      frame.render({ setup.render(context, geometry.bodyHeight, model, components, actions, settingsButton) })
      return
    end

    local showNotifications = setting("panel_notifications")
    local showTimeline = setting("panel_timeline")
    local sidebar = showNotifications or showTimeline
    local mainWidth = context.width - (sidebar and (geometry.activityWidth + geometry.gap) or 0)
    local left = { deviceCard.render(context, mainWidth, model, components, actions) }
    local usedHeight = deviceCard.height
    if setting("panel_actions") then
      local primary, secondary, height = shortcuts.render(context, mainWidth, model, components, actions)
      left[#left + 1] = primary
      left[#left + 1] = secondary
      usedHeight = usedHeight + height + 2 * gap
    end
    if setting("panel_controls") then
      local available = geometry.bodyHeight - usedHeight - gap
      left[#left + 1] = controls.render(phone, context.online, mainWidth, math.min(190, available), settingsButton)
    elseif settingsButton then
      left[#left + 1] = ui.spacer({ flexGrow = 1 })
      left[#left + 1] = ui.row({ width = mainWidth, height = 36 }, { settingsButton })
    end

    local content = {
      ui.column({
        key = "content", width = mainWidth, height = geometry.bodyHeight, gap = gap,
      }, left),
    }
    if sidebar then
      content[#content + 1] = activity.render(
        context, geometry.activityWidth, geometry.bodyHeight,
        showNotifications, showTimeline, model, components, actions
      )
    end
    frame.render(content)
  end

  return { render = render }
end

return M
