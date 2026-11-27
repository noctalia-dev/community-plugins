--!nonstrict
-- First-run guidance for installing and connecting Desktop.
local palette = require("../palette.luau")
local setupReasons = {
  credentials_missing = true,
  credentials_invalid = true,
  loopback_proxy = true,
  api_unavailable = true,
  unauthorized = true,
  auth_changed = true,
  unsupported = true,
  invalid_response = true,
  permission = true,
  timeout = true,
}

local M = {}

function M.render(context, height, model, components, actions, settingsButton)
  local width = context.width
  local innerWidth = width - 32
  local reason = context.ready and "no_devices" or model.snapshot.error or "api_unavailable"
  if reason ~= "no_devices" and not setupReasons[reason] then
    reason = "api_unavailable"
  end

  local function button(text, action, key)
    return ui.button({
      key = key,
      text = noctalia.tr(text),
      controlSize = "sm",
      height = 32,
      fontSize = 11,
      variant = "ghost",
      onClick = function()
        actions.send(action)
      end,
    })
  end
  local buttons = {
    button("setup.instructions", "open_fork", "help-fork"),
    button("setup.open", "open"),
    button("setup.check", "refresh"),
  }
  if settingsButton then
    buttons[#buttons + 1] = settingsButton
  end

  local rows = {
    components.label(noctalia.tr("setup.title"), 18, "on_surface", true, innerWidth),
    ui.label({
      text = noctalia.tr("setup.intro"),
      fontSize = 12,
      maxWidth = innerWidth,
      maxLines = 2,
      height = 36,
      color = "on_surface_variant",
    }),
  }
  for _, key in ipairs({ "install", "api", "pair" }) do
    rows[#rows + 1] = ui.label({
      text = noctalia.tr("setup." .. key),
      fontSize = 13,
      maxWidth = innerWidth,
      maxLines = 2,
      height = 30,
    })
  end
  rows[#rows + 1] = ui.label({
    key = "setup-status", text = noctalia.tr("setup." .. reason), fontSize = 12,
    color = "primary", maxWidth = innerWidth, maxLines = 2, height = 38,
  })
  if not context.ready then
    local title, detail = components.failure(model.snapshot.error or "api_unavailable")
    rows[#rows + 1] = ui.row({
      tooltip = detail,
    }, {
      ui.label({
        key = "connection-error", text = title, fontSize = 10,
        color = "on_surface_variant", maxWidth = innerWidth, maxLines = 1,
      }),
    })
  end
  rows[#rows + 1] = ui.spacer({ flexGrow = 1 })
  rows[#rows + 1] = ui.row({ gap = 8, height = 36, align = "center" }, buttons)
  return ui.column({
    key = "connection-setup", width = width, height = height, padding = 16, gap = 6,
    radius = 14, fill = palette("card"),
  }, rows)
end

return M
