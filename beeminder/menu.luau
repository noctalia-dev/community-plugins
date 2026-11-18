--!nonstrict
local shared = require("./shared.luau")

local function item(glyph, label, enabled, action)
  return ui.button({
    glyph = glyph,
    text = label,
    variant = "ghost",
    contentAlign = "start",
    enabled = enabled,
    onClick = function()
      action()
      panel.close()
    end,
  })
end

local function render()
  local report = shared.report()
  local username = report and report.username or nil
  panel.render(ui.column({ flexGrow = 1, gap = 2, align = "stretch" }, {
    item("user", noctalia.tr("menu.open_profile"), username ~= nil, function()
      shared.openUrl(shared.profileUrl(username))
    end),
    item("refresh", noctalia.tr("menu.refresh"), true, shared.requestRefresh),
    item("settings", noctalia.tr("menu.settings"), true, noctalia.openSettings),
  }))
end

function onOpen(_context)
  render()
end
