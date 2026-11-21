--!nonstrict
-- Frame and navigation for the fixed 860x470 panel.
local palette = require("./palette.luau")
local M = {}
function M.new(model, components, actions)
  local geometry = require("./components.luau").layout
  local setting = components.setting
  local label = components.label
  local send = actions.send
  local render = actions.render
  local navigate = actions.navigate
  local function renderFrame(header, content)
    if setting("panel_navigation") then
      local nav = {}
      for _, entry in ipairs({
        { components.titles.home, "home", "home" },
        { components.titles.messages, "message", "messages" },
        { components.titles.calls, "phone", "calls" },
        { components.titles.photos, "photo", "photos" },
        { components.titles.apps, "apps", "apps" },
        { components.titles.deck, "layout-grid", "deck" },
        { components.titles.guide, "book", "guide" },
      }) do
        table.insert(
          nav,
          ui.button({
            glyph = entry[2],
            glyphSize = 18,
            controlSize = "sm",
            width = 32,
            height = 32,
            key = "nav-" .. entry[3],
            variant = model.page == entry[3] and "secondary" or "ghost",
            tooltip = entry[1],
            onClick = function()
              navigate(entry[3])
            end,
          })
        )
      end
      table.insert(nav, ui.spacer({ flexGrow = 1 }))
      table.insert(
        nav,
        ui.button({
          key = "plugin-settings",
          glyph = "settings",
          glyphSize = 18,
          variant = "ghost",
          controlSize = "sm",
          width = 32,
          height = 32,
          tooltip = noctalia.tr("common.settings"),
          onClick = function()
            noctalia.openSettings()
          end,
        })
      )
      table.insert(
        content,
        1,
        ui.column({
          key = "navigation",
          gap = 5,
          padding = 5,
          width = 42,
          height = geometry.pageHeight,
          radius = 12,
          align = "center",
          fill = palette("card", 0.6),
        }, nav)
      )
    end
    model.renderedTree = ui.column({
      key = "panel-layout-0100",
      width = 828,
      height = 438,
      gap = 6,
      padding = 3,
      align = "start",
    }, {
      header,
      ui.row({ key = "dashboard", width = 822, gap = 10, height = geometry.pageHeight }, content),
    })
    panel.render(model.renderedTree)
  end

  local function header()
    local headerItems = {
      ui.glyph({ name = "device-mobile", size = 20, color = "primary" }),
      ui.label({
        text = "NectarLink",
        maxWidth = 600,
        maxLines = 1,
        fontFamily = "sans-serif",
        fontSize = 16,
        fontWeight = "bold",
        flexGrow = 1,
      }),
      ui.button({
        glyph = "external-link",
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("common.open_app"),
        onClick = function()
          send("open")
        end,
      }),
      ui.button({
        glyph = "settings",
        controlSize = "sm",
        height = 28,
        visible = not setting("panel_navigation"),
        variant = "ghost",
        tooltip = noctalia.tr("common.settings"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
    }
    if
      model.snapshot.error
      or (model.pageView and model.pageView.error)
      or model.page == "guide"
    then
      table.insert(
        headerItems,
        ui.button({
          key = "help-fork",
          glyph = "book",
          controlSize = "sm",
          variant = "ghost",
          tooltip = noctalia.tr("common.fork_help"),
          onClick = function()
            send("open_fork")
          end,
        })
      )
    end
    if model.page == "home" then
      table.insert(
        headerItems,
        ui.button({
          key = "refresh-home",
          glyph = "refresh",
          width = 28,
          height = 28,
          controlSize = "sm",
          variant = "ghost",
          tooltip = noctalia.tr("common.refresh"),
          onClick = function()
            send("refresh")
            render()
          end,
        })
      )
    end
    local header = ui.row({ width = 822, gap = 8, align = "center", height = 28 }, headerItems)

    return header
  end
  return { render = renderFrame, header = header }
end
return M
