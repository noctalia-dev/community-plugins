--!nonstrict
-- Section lists and grids are projections of the current page, not new reads.
local palette = require("./palette.luau")
local metrics = require("./components.luau").layout.page
local M = {}
local callIcons = {
  outgoing = "arrow-up-right", incoming = "arrow-down-left",
  missed = "phone-x", rejected = "phone-x",
}

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) <= 9007199254740991
end

function M.new(model, components, actions)
  local label, preview = components.label, components.preview
  local badge = components.iconBadge

  local function callRow(width, key, item, title, subtitle, onClick)
    local icon = callIcons[item.subtitle] or "phone"
    local missed = item.subtitle == "missed"
    local time
    if noctalia.formatTime and finite(item.date) and item.date > 0 and item.date < 253402300800000 then
      time = noctalia.formatTime("%d.%m · %H:%M", math.floor(item.date / 1000))
    end
    local textWidth = width - 80 - (time and 96 or 0)
    local children = {
      badge(icon, 34, missed and "error" or "primary",
        missed and "error/0.12" or nil),
      ui.column({ flexGrow = 1, gap = 1 }, {
        label(title, 13, "on_surface", true, textWidth),
        label(subtitle, 11, "on_surface_variant", false, textWidth),
      }),
    }
    if time then children[#children + 1] = label(time, 10, "on_surface_variant", false, 88) end
    if onClick then
      children[#children + 1] = ui.glyph({ name = "chevron-right", size = 14, color = "on_surface_variant" })
    end
    return ui.row({
      key = key, width = width, height = metrics.callRow, gap = 9, paddingH = 8,
      align = "center", radius = 10, tooltip = title, onClick = onClick,
      fill = palette("raised", 0.72),
    }, children)
  end

  local function cell(gallery, key, item, title, subtitle, onClick)
    local page, w, h = gallery.page, gallery.cellWidth, gallery.cellHeight
    local children, padding, gap = {}, page == "photos" and 6 or 4, 4
    if page == "deck" then padding = h >= 94 and 10 or (h >= 60 and 6 or 4) end
    local inner = w - 2 * padding
    if page == "photos" then
      local imageHeight = h - 2 * padding - gap - 18
      children[1] = type(item.thumbnailPath) == "string" and ui.image({
        path = item.thumbnailPath, width = inner, height = imageHeight, fit = "cover", radius = 8,
      }) or ui.column({
        width = inner, height = imageHeight, align = "center", justify = "center",
        fill = "on_surface_variant/0.08", radius = 8,
      }, { ui.glyph({ name = "photo", size = 28, color = "on_surface_variant" }) })
      children[2] = ui.row({ width = inner, height = 18, gap = 5, paddingH = 2, align = "center" }, {
        label(title, 11, "on_surface", true, inner - 4),
      })
    elseif page == "apps" then
      local side = gallery.names and 34 or 26
      children[1] = ui.row({ width = inner, height = side, align = "center", justify = "center" }, {
        type(item.iconPath) == "string"
            and ui.image({ path = item.iconPath, width = side, height = side, fit = "contain" })
          or ui.glyph({ name = "apps", size = side, color = "primary" }),
      })
      if gallery.names then
        children[2] = ui.column({ width = inner, height = 32, align = "center", justify = "center" }, {
          ui.label({
            text = title, fontFamily = "sans-serif", fontSize = 11, color = "on_surface",
            maxWidth = inner, maxLines = 2, textAlign = "center",
          }),
        })
      end
    else
      local large = h >= 88
      local badgeSide = large and 34 or math.min(24, h - 8)
      children[1] = badge(components.deckGlyphs[item.kind] or "layout-grid", badgeSide,
        "primary", nil, large and 21 or math.min(17, badgeSide - 2))
      if h >= 58 then
        children[2] = ui.column({ width = inner, height = 18, justify = "center" }, {
          label(title, 12, "on_surface", true, inner),
        })
      end
      if large and subtitle ~= "" then
        children[3] = ui.column({ width = inner, height = 14 }, {
          label(subtitle, 10, "on_surface_variant", false, inner),
        })
      end
    end
    local centered = page == "apps" or (page == "deck" and h < 58)
    local node = ui.column({
      key = key, width = w, height = h, padding = padding, gap = gap, radius = 10,
      align = centered and "center" or "start",
      justify = page == "photos" and "start" or "center",
      tooltip = title .. (subtitle ~= "" and (" · " .. subtitle) or ""),
      onClick = onClick,
      onHover = page == "apps" and "onTileHover" or nil,
      fill = page == "apps" and components.appTileFill(model.hovered == key) or palette("raised", 0.72),
    }, children)
    if page == "apps" then model.appHoverNodes[key] = node end
    return node
  end

  local function gridLayout(page, width, count)
    local gap, columns = metrics.itemGap, 4
    local apps = page == "apps" and components.appsLayout()
    if apps then
      columns = apps.columns
    elseif page == "deck" then
      -- Keep all of the API's Deck tiles visible, including the dense 192-tile case.
      columns = count <= 16 and 4
        or (count <= 30 and 5 or (count <= 48 and 6 or (count <= 96 and 8 or 16)))
    end
    local rows = math.ceil(count / columns)
    local cellWidth = apps and apps.width or math.floor((width - (columns - 1) * gap) / columns)
    local cellHeight = apps and apps.height or (page == "photos"
      and math.floor((metrics.gallery - gap) / 2)
      or math.min(110, math.floor((metrics.body - metrics.notice - metrics.gap - (rows - 1) * gap) / rows)))
    return {
      page = page, columns = columns, rows = rows, cellWidth = cellWidth, cellHeight = cellHeight,
      names = apps and apps.names,
      gap = apps and apps.gap or (width - columns * cellWidth) / (columns - 1),
    }
  end

  local function grid(width, gallery, cells)
    local lines = {}
    for first = 1, #cells, gallery.columns do
      local row = {}
      for index = first, math.min(first + gallery.columns - 1, #cells) do
        row[#row + 1] = cells[index]
      end
      lines[#lines + 1] = ui.row({
        key = "grid-row-" .. first, width = width, height = gallery.cellHeight, gap = gallery.gap,
        align = "start",
      }, row)
    end
    return ui.column({
      key = "page-grid", width = width, gap = metrics.itemGap,
      height = gallery.rows * gallery.cellHeight + (gallery.rows - 1) * metrics.itemGap,
    }, lines)
  end

  local function noticeRow(width, notice, key)
    if type(notice) ~= "string" or notice == "" then return nil end
    return ui.row({
      key = key or "page-notice", width = width, height = metrics.notice, gap = 6, align = "center",
      tooltip = preview(notice, 220),
    }, {
      ui.glyph({ name = "info-circle", size = 14, color = "on_surface_variant" }),
      label(notice, 11, "on_surface_variant", false, width - 20),
    })
  end

  local function steps(data, count, nav, cursorPage, apply, key, prefix)
    local items = type(data.items) == "table" and data.items or {}
    -- A cursor must point at the last displayed row, never a hidden response row.
    local last = items[count]
    local canNext = (data.more == true or #items > count) and count > 0
      and (not cursorPage or (type(last) == "table" and finite(last.date) and type(last.id) == "string"))
    local stack = nav.cursors
    local current = { offset = nav.offset, before = nav.before, beforeId = nav.beforeId }
    local function copyStack(take)
      local copy = {}
      for i = 1, take do copy[i] = stack[i] end
      return copy
    end
    return components.pageSteps(#stack + 1, function()
      local old = stack[#stack]
      apply({
        offset = old.offset, before = old.before, beforeId = old.beforeId,
        cursors = copyStack(#stack - 1),
      })
    end, function()
      local cursors = copyStack(#stack)
      cursors[#cursors + 1] = current
      if cursorPage then
        apply({ offset = 0, before = last.date, beforeId = last.id, cursors = cursors })
      else
        apply({ offset = current.offset + count, cursors = cursors })
      end
    end, #stack > 0, canNext, key, prefix)
  end

  local function pageSteps(data, count, cursorPage, refresh)
    local page, device, key, cursors = model.page, model.selected, model.pageKey, model.cursors
    return steps(data, count, model, cursorPage, function(nav)
      if not model.opened or model.page ~= page or model.selected ~= device or model.pageKey ~= key
        or model.cursors ~= cursors then return end
      model.offset, model.before, model.beforeId = nav.offset, nav.before, nav.beforeId
      model.cursors = nav.cursors
      refresh()
    end)
  end

  local function render(add, online, width, data, refresh, selectNumber)
    local page, device, pageKey = model.page, model.selected, model.pageKey
    local dispatch = actions.bindAction("page", device)
    local actionEnabled = not actions.actionBusy("page") and (page == "deck" or online)
    local items = type(data.items) == "table" and data.items or {}
    local limits = metrics.limits
    local limit = (page == "apps" and components.appsLayout().limit) or limits[page]
    local count = math.min(#items, limit)
    local gallery = count > 0 and (page == "photos" or page == "apps" or page == "deck")
      and gridLayout(page, width, count) or nil
    local nodes = {}
    for index = 1, count do
      local item = type(items[index]) == "table" and items[index] or {}
      local title = preview(item.title, 96)
      if title == "" then
        title = page == "calls" and preview(item.number, 96) or ""
        if title == "" then title = components.titles[page] end
      end
      local subtitle = type(item.subtitle) == "string" and item.subtitle
        or (finite(item.size) and item.size >= 0
          and noctalia.tr("common.kib", { size = math.floor(item.size / 1024) })) or ""
      if page == "deck" then
        title = components.deckLabels[title] or title
        if subtitle == "Main" then subtitle = noctalia.tr("deck.main") end
      elseif page == "calls" then
        subtitle = components.directions[subtitle] or subtitle
        if finite(item.duration) and item.duration > 0 then
          subtitle = subtitle .. " · " .. noctalia.tr("calls.duration", {
            minutes = math.floor(item.duration / 60), seconds = math.floor(item.duration % 60),
          })
        end
      end
      local function onClick()
        if not model.opened or model.page ~= page or model.selected ~= device
          or model.pageKey ~= pageKey or model.detail
          or type(item.id) ~= "string" or item.id == "" then return end
        if page == "photos" then
          model.detail = item
          model.detailPart = 0
        elseif page == "calls" then
          if type(item.number) == "string" and item.number ~= "" then return selectNumber(item.number) end
          return
        elseif page == "deck" or page == "apps" then
          return dispatch({ action = page == "apps" and "app" or "deck", id = item.id })
        else
          return
        end
        actions.render()
      end
      local key = "page-item-" .. tostring(item.id)
      local canPickNumber = type(item.number) == "string" and item.number ~= ""
      local tileClick = (page == "photos" or actionEnabled) and onClick or nil
      if gallery then
        nodes[index] = cell(gallery, key, item, title, subtitle, tileClick)
      else
        nodes[index] = callRow(width, key, item, title, subtitle, canPickNumber and onClick or nil)
      end
    end
    if gallery then
      add(grid(width, gallery, nodes))
    elseif count > 0 then
      add(ui.column({
        key = "page-list", width = width, height = count * metrics.callRow + (count - 1) * metrics.itemGap,
        gap = metrics.itemGap, align = "start",
      }, nodes))
    else
      add(components.pageNote(noctalia.tr("common.no_items"), noctalia.tr("pages." .. page .. "_empty"),
        "info-circle", width, 96, nil, "page-empty"))
    end
    add(noticeRow(width, data.notice))
    if page == "deck" then return end

    local pagination = pageSteps(data, count, page ~= "apps", refresh)
    if page == "photos" then
      add(ui.spacer({ flexGrow = 1 }))
      add(ui.row({ width = width, height = metrics.pager, justify = "center" }, { pagination }))
    else
      return pagination
    end
  end
  return { render = render, steps = steps, pageSteps = pageSteps, notice = noticeRow }
end

return M
