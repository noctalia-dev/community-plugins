--!nonstrict
-- The bar opens a dashboard, not a second application window. No title bar is needed.
local palette = require("./palette.luau")
local geometry = require("./components.luau").layout

local M = {}

function M.new(model, components, actions)
  local function settingsButton()
    return ui.button({
      key = "plugin-settings",
      glyph = "settings",
      glyphSize = 18,
      variant = "ghost",
      width = 36,
      height = 36,
      tooltip = noctalia.tr("common.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    })
  end

  local function navigation()
    local items = {}
    for _, entry in ipairs({
      { "home", "home" },
      { "messages", "message" },
      { "calls", "phone" },
      { "photos", "photo" },
      { "apps", "apps" },
      { "deck", "puzzle" },
      { "guide", "book" },
    }) do
      local page, glyph = entry[1], entry[2]
      items[#items + 1] = ui.button({
        key = "nav-" .. page,
        glyph = glyph,
        glyphSize = 19,
        width = 36,
        height = 36,
        variant = model.page == page and "primary" or "ghost",
        tooltip = components.titles[page],
        onClick = function()
          actions.navigate(page)
        end,
      })
    end
    items[#items + 1] = ui.box({ width = 28, height = 1, fill = palette("muted_border", 0.55) })
    items[#items + 1] = ui.spacer({ flexGrow = 1 })
    items[#items + 1] = settingsButton()

    return ui.column({
      key = "navigation",
      gap = 6,
      padding = 8,
      width = geometry.navigationWidth,
      height = geometry.bodyHeight,
      radius = 14,
      align = "center",
      fill = palette("card", 0.72),
    }, items)
  end

  local function renderFrame(content)
    if components.setting("panel_navigation") then
      table.insert(content, 1, navigation())
    end
    model.renderedTree = ui.column({
      key = "panel-layout",
      width = geometry.frameWidth,
      height = geometry.frameHeight,
      padding = geometry.framePadding,
      align = "start",
    }, {
      ui.row({
        key = "dashboard",
        width = geometry.bodyWidth,
        height = geometry.bodyHeight,
        gap = geometry.gap,
        align = "start",
      }, content),
    })
    panel.render(model.renderedTree)
  end

  return { render = renderFrame, settingsButton = settingsButton }
end

return M
