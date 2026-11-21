--!nonstrict
-- Lists, grids and pagination: node construction and explicit callbacks only.
local palette = require("./palette.luau")
local M = {}
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) <= 9007199254740991
end
function M.new(model, components, actions)
  local geometry = require("./components.luau").layout
  local appsLayout = components.appsLayout
  local preview = components.preview
  local label = components.label
  local pager = components.pager
  local directions = components.directions
  local deckLabels = components.deckLabels
  local deckGlyphs = components.deckGlyphs
  local render = actions.render
  local dispatchPageAction = actions.dispatchPageAction
  local function renderPageItems(add, online, width, data, refresh)
    -- data is the displayed response; refresh explicitly requests another read.
    -- Node construction never executes actions; only onClick dispatches them.
    -- The service validates before caching; also defend against legacy snapshots.
    local items = type(data.items) == "table" and data.items or {}
    local notice = type(data.notice) == "string" and data.notice or ""
    local appLayout = appsLayout()
    local maxRows = model.page == "photos" and 8
      or (
        model.page == "apps" and appLayout.limit
        or (model.page == "deck" and #items or (model.page == "messages" and 7 or 6))
      )
    if model.page == "calls" and type(data.active) == "table" and data.active.state ~= "ended" then
      maxRows = 5
    end
    -- Reserve space for composer, navigation and status; lists never scroll.
    if model.page == "messages" and model.thread then
      maxRows = 6
    end
    -- Legacy API notice text, not a UI translation key. Keep matching the wire
    -- value regardless of the shell language until the API supplies a notice code.
    local legacyHistoryNotice = notice:find("Последние 100", 1, true) ~= nil
    if
      (model.page == "messages" or model.page == "calls")
      and notice ~= ""
      and not legacyHistoryNotice
    then
      maxRows = math.max(1, maxRows - 1)
    end
    if model.page == "calls" and model.dialOpen then
      maxRows = 0
    end
    local grid = {}
    local gridColumns = model.page == "apps" and appLayout.columns or 4
    if model.page == "deck" then
      gridColumns = #items <= 16 and 4
        or (#items <= 30 and 5 or (#items <= 48 and 6 or (#items <= 96 and 8 or 16)))
    end
    local gridRows = math.max(1, math.ceil(math.min(#items, maxRows) / gridColumns))
    local cellWidth = math.floor((width - 12 - (gridColumns - 1) * 6) / gridColumns)
    local imageSide = cellWidth - 8
    local cellHeight = model.page == "photos" and 136
      or (
        model.page == "apps" and 80
        or math.min(88, math.floor((336 - (gridRows - 1) * 6) / gridRows))
      )
    if model.page == "apps" then
      cellWidth = appLayout.side
      cellHeight = appLayout.side
      imageSide = cellWidth - 8
    end
    for i, rawItem in ipairs(items) do
      if i > maxRows then
        break
      end
      local item = type(rawItem) == "table" and rawItem or {}
      local addresses = {}
      if type(item.addresses) == "table" then
        for _, address in ipairs(item.addresses) do
          if type(address) == "string" then
            table.insert(addresses, address)
          end
        end
      end
      local title = type(item.title) == "string" and item.title ~= "" and item.title
        or (#addresses > 0 and table.concat(addresses, ", ") or noctalia.tr("messages.message"))
      local subtitle = type(item.subtitle) == "string" and item.subtitle
        or (finite(item.size) and item.size >= 0 and noctalia.tr(
          "common.kib",
          { size = math.floor(item.size / 1024) }
        ))
        or ""
      if model.page == "deck" then
        title = deckLabels[title] or title
        subtitle = subtitle == "Main" and noctalia.tr("deck.main") or subtitle
      end
      if model.page == "calls" then
        subtitle = (directions[subtitle] or subtitle)
          .. (
            finite(item.duration)
              and item.duration > 0
              and (" · " .. noctalia.tr(
                "calls.duration",
                { minutes = math.floor(item.duration / 60), seconds = item.duration % 60 }
              ))
            or ""
          )
      end
      if model.page == "messages" and not model.thread then
        subtitle = noctalia.tr(
          item.kind == "sms" and "messages.sms_preview" or "messages.chat_preview",
          { text = subtitle }
        )
      end
      local itemClick = function()
        if type(item.id) ~= "string" or item.id == "" then
          return
        end
        if
          item.addresses ~= nil
          and (type(item.addresses) ~= "table" or #addresses ~= #item.addresses)
        then
          return
        end
        if model.page == "messages" and not model.thread then
          model.thread = item
          model.offset = 0
          model.cursors = {}
          model.before = nil
          model.pageKey = nil
          render()
        elseif model.page == "messages" then
          model.detail = item
          model.detailPart = 0
          render()
        elseif model.page == "calls" then
          model.pageDrafts[(model.selected or "none") .. "|dial"] = type(item.number) == "string"
              and item.number
            or ""
          model.dialOpen = true
          render()
        elseif model.page == "photos" then
          model.detail = item
          model.detailPart = 0
          render()
        elseif model.page == "apps" and online and not model.snapshot.pageActionBusy then
          dispatchPageAction("app", item.id)
          render()
        elseif model.page == "deck" and not model.snapshot.pageActionBusy then
          dispatchPageAction("deck", item.id)
          render()
        end
      end
      if model.page == "photos" or model.page == "deck" or model.page == "apps" then
        local children = {}
        if model.page == "photos" then
          table.insert(
            children,
            ui.row({ width = imageSide, height = 128, align = "center", justify = "center" }, {
              type(item.thumbnailPath) == "string"
                  and ui.image({
                    path = item.thumbnailPath,
                    width = imageSide,
                    height = 128,
                    fit = "cover",
                    radius = 6,
                  })
                or ui.column({
                  width = imageSide,
                  height = 128,
                  align = "center",
                  justify = "center",
                  fill = palette("raised"),
                  radius = 6,
                }, {
                  ui.glyph({ name = "photo", size = 28, color = "on_surface_variant" }),
                }),
            })
          )
        elseif model.page == "apps" then
          table.insert(
            children,
            ui.row({ width = imageSide, height = 24, align = "center", justify = "center" }, {
              type(item.iconPath) == "string"
                  and ui.image({ path = item.iconPath, width = 24, height = 24, fit = "contain" })
                or ui.glyph({ name = "apps", size = 24, color = "primary" }),
            })
          )
        else
          local glyphSize = cellHeight >= 76 and 24 or math.min(18, cellHeight - 8)
          table.insert(
            children,
            ui.row({ width = imageSide, height = cellHeight >= 76 and 28 or glyphSize }, {
              ui.glyph({
                name = deckGlyphs[item.kind] or "layout-grid",
                size = glyphSize,
                color = "primary",
              }),
            })
          )
        end
        -- Label.height is not a rigid layout constraint in Noctalia 5.5.
        -- Give text its own fixed flex slot and maxWidth so image/title
        -- measurements cannot grow a card or spill into the next row.
        if
          (model.page == "apps" and appLayout.names)
          or (
            model.page ~= "apps"
            and model.page ~= "photos"
            and (model.page ~= "deck" or cellHeight >= 48)
          )
        then
          table.insert(
            children,
            ui.column({
              width = imageSide,
              height = 20,
              align = model.page == "apps" and "center" or "start",
              justify = "center",
            }, {
              ui.label({
                text = preview(title, 26),
                maxWidth = imageSide,
                maxLines = 1,
                fontFamily = "sans-serif",
                fontSize = model.page == "apps" and 10 or 12,
                fontWeight = model.page ~= "apps" and "bold" or nil,
              }),
            })
          )
        end
        if model.page == "deck" and cellHeight >= 76 then
          table.insert(
            children,
            ui.column({ width = imageSide, height = 16, align = "start" }, {
              ui.label({
                text = preview(subtitle, 26),
                maxWidth = imageSide,
                maxLines = 1,
                fontFamily = "sans-serif",
                fontSize = 10,
                color = "on_surface_variant",
              }),
            })
          )
        end
        local appKey = "page-item-" .. tostring(item.id)
        table.insert(
          grid,
          ui.column({
            key = appKey,
            width = cellWidth,
            height = cellHeight,
            gap = 2,
            padding = 4,
            radius = 8,
            align = model.page == "apps" and "center" or "start",
            justify = model.page == "apps" and "center" or "start",
            tooltip = title .. (subtitle ~= "" and (" · " .. subtitle) or ""),
            onClick = itemClick,
            onHover = model.page == "apps" and "onTileHover" or nil,
            fill = model.page == "apps"
                and (model.hovered == appKey and palette("raised") or "transparent")
              or palette("card"),
          }, children)
        )
        if model.page == "apps" then
          model.appHoverNodes[appKey] = grid[#grid]
        end
      else
        local glyph = model.page == "calls"
            and (item.subtitle == "outgoing" and "arrow-up-right" or "arrow-down-left")
          or (model.page == "apps" and "apps" or "message")
        -- Reserve the icon, padding, gaps and optional timestamp explicitly.
        local textWidth = width - 62 - (finite(item.date) and noctalia.formatTime and 94 or 0)
        local children = {
          ui.column({
            width = 28,
            height = 30,
            align = "center",
            justify = "center",
            radius = 8,
            fill = "primary/0.1",
          }, {
            ui.glyph({
              name = glyph,
              size = 18,
              color = model.page == "calls" and item.subtitle == "missed" and "error" or "primary",
            }),
          }),
          ui.column({ gap = 1, flexGrow = 1 }, {
            label(preview(title, 54), 12, "on_surface", true, textWidth),
            label(preview(subtitle, 72), 11, "on_surface_variant", false, textWidth),
          }),
        }
        if finite(item.date) and noctalia.formatTime then
          table.insert(
            children,
            label(
              noctalia.formatTime("%d.%m %H:%M", math.floor(item.date / 1000)),
              10,
              "on_surface_variant",
              false,
              86
            )
          )
        end
        if model.page == "apps" then
          table.insert(
            children,
            ui.glyph({ name = "external-link", size = 16, color = "on_surface_variant" })
          )
        end
        add(ui.row({
          key = "page-item-" .. tostring(item.id),
          width = width - 12,
          gap = 8,
          padding = 3,
          height = 40,
          radius = 9,
          fill = palette("card"),
          tooltip = model.page == "apps" and noctalia.tr("apps.open_window") or title,
          onClick = itemClick,
        }, children))
      end
    end
    if #grid > 0 then
      local lines = {}
      for first = 1, #grid, gridColumns do
        local cells = {}
        for j = first, math.min(first + gridColumns - 1, #grid) do
          table.insert(cells, grid[j])
        end
        table.insert(
          lines,
          ui.row({
            key = "grid-row-" .. first,
            width = width - 12,
            gap = model.page == "apps" and appLayout.gap or 6,
            height = cellHeight,
            align = "start",
            justify = "start",
          }, cells)
        )
      end
      add(ui.column({
        key = "page-grid",
        width = width - 12,
        gap = 6,
        height = gridRows * cellHeight + (gridRows - 1) * 6,
        align = "start",
        justify = "start",
      }, lines))
    end
    if #items == 0 then
      add(label(noctalia.tr("common.no_items"), 12, "on_surface_variant"))
    end
    if notice ~= "" and not legacyHistoryNotice then
      add(label(preview(notice, 110), 10, "on_surface_variant"))
    end
    if model.page ~= "deck" and not (model.page == "calls" and model.dialOpen) then
      add(ui.spacer({ flexGrow = 1 }))
      add(pager(width - 12, #model.cursors + 1, function()
        local old = table.remove(model.cursors)
        if old then
          model.offset = old.offset
          model.before = old.before
          model.beforeId = old.beforeId
          refresh()
        end
      end, function()
        local cursorPage = model.page == "calls"
          or model.page == "photos"
          or (model.page == "messages" and model.thread and model.thread.kind == "sms")
        local last = items[math.min(#items, maxRows)]
        if
          cursorPage
          and (type(last) ~= "table" or not finite(last.date) or type(last.id) ~= "string")
        then
          return
        end
        table.insert(
          model.cursors,
          { offset = model.offset, before = model.before, beforeId = model.beforeId }
        )
        if cursorPage then
          model.before = last.date
          model.beforeId = last.id
          model.offset = 0
        else
          model.offset = model.offset + math.min(maxRows, #items)
        end
        refresh()
      end, #model.cursors > 0, data.more == true or #items > maxRows))
    end
  end
  return { render = renderPageItems }
end
return M
