--!nonstrict
-- A bound thread list on the left, the selected source on the right.
local palette = require("./palette.luau")
local metrics = require("./components.luau").layout.page
local M = {}
local pad, gap = 9, 6
local rowHeight, rowGap = 46, 5
local headingHeight = 36

function M.new(model, components, actions, forms, items)
  local label, preview = components.label, components.preview

  local function contactTitle(thread)
    local title = preview(thread.title, 80)
    if title ~= "" then return title end
    if type(thread.addresses) == "table" then
      local addresses = {}
      for _, address in ipairs(thread.addresses) do
        if type(address) == "string" then addresses[#addresses + 1] = address end
      end
      title = preview(table.concat(addresses, ", "), 80)
    end
    return title ~= "" and title or noctalia.tr("messages.message")
  end

  local function clearSelection()
    actions.selectThread(nil)
  end

  local function header(width, title, subtitle, controls)
    local reserved = 6
    for _, control in ipairs(controls) do reserved = reserved + control.props.width + gap end
    local textWidth = width - reserved
    local nodes = {
      ui.column({ gap = 0 }, {
        label(title, 15, "on_surface", true, textWidth),
        subtitle and label(subtitle, 10, "on_surface_variant", false, textWidth) or nil,
      }),
      ui.spacer({ flexGrow = 1 }),
    }
    for _, control in ipairs(controls) do nodes[#nodes + 1] = control end
    return ui.row({ width = width, height = headingHeight, gap = gap, align = "center" }, nodes)
  end

  local function iconButton(key, glyph, hint, onClick)
    return ui.button({
      key = key, glyph = glyph, glyphSize = 17, width = 32, height = 32,
      tooltip = noctalia.tr(hint), variant = "ghost", onClick = onClick,
    })
  end

  local function readyData(view)
    return view and view.status == "ready" and view.data or nil
  end

  local function rows(key, width, children)
    return ui.column({
      key = key, width = width, gap = rowGap, align = "start",
      height = #children * rowHeight + math.max(0, #children - 1) * rowGap,
    }, children)
  end

  local function leftPane(width, stateNote)
    local inner = width - 2 * pad
    local nav, device = model.threadList, model.selected
    local view = actions.threadsView()
    local data = readyData(view)
    local records = data and type(data.items) == "table" and data.items or {}
    local count = math.min(#records, metrics.limits.messages)
    local function currentList()
      return model.opened and model.page == "messages" and model.selected == device
        and model.threadList == nav
    end
    local controls = {}
    if data and not view.partial and (#nav.cursors > 0 or data.more == true or #records > count) then
      controls[1] = items.steps(data, count, nav, false, function(nextNav)
        -- Moving the left pager returns to the list query, not the active thread's cursor.
        if currentList() then actions.selectThread(nil, nextNav) end
      end, "thread-list-pagination", "threads-pager")
    end
    local listStatus
    if view and view.partial then
      listStatus = noctalia.tr(view.refreshing and "messages.loading_sms"
        or (view.error == "local_chats_unavailable" and "messages.local_chats_not_loaded" or "messages.sms_not_loaded"))
    elseif view and view.refreshing then
      listStatus = noctalia.tr("cache.refreshing")
    elseif view and view.error and data then
      listStatus = noctalia.tr("cache.refresh_failed")
    end
    local children = { header(inner, noctalia.tr("messages.threads"), listStatus, controls) }
    local function add(node)
      if node then children[#children + 1] = node end
    end
    if not data then
      if view or not model.thread or not device then
        add(stateNote(inner, view, "threads-state"))
      else
        add(components.pageNote(noctalia.tr("messages.threads_unavailable"),
          noctalia.tr("messages.refresh_threads_hint"), "message", inner, 104, nil, "threads-state"))
        add(components.smallButton(noctalia.tr("messages.refresh_threads"), clearSelection))
      end
    elseif count == 0 then
      add(components.pageNote(noctalia.tr("common.no_items"), noctalia.tr("pages.messages_empty"),
        "message", inner, 104, nil, "page-empty"))
    else
      local list = {}
      for index = 1, count do
        local thread = type(records[index]) == "table" and records[index] or {}
        local selected = model.thread and model.thread.id == thread.id and model.thread.kind == thread.kind
        local sms, notification = thread.kind == "sms", thread.kind == "chat"
        local name = contactTitle(thread)
        local badgeWidth = 86
        local titleWidth = inner - 46 - badgeWidth - 18
        list[index] = ui.row({
          key = "thread-item-" .. tostring(thread.id), width = inner, height = rowHeight, gap = 6,
          paddingH = 8, radius = 10, align = "center",
          fill = selected and "primary/0.19" or palette("raised", 0.74),
          tooltip = name,
          onClick = function()
            if not currentList() or selected or type(thread.id) ~= "string" or thread.id == "" then return end
            if thread.addresses ~= nil then
              if type(thread.addresses) ~= "table" then return end
              for _, address in ipairs(thread.addresses) do
                if type(address) ~= "string" then return end
              end
            end
            actions.selectThread(thread)
          end,
        }, {
          components.iconBadge(sms and "message" or (notification and "bell" or "message"), 28, nil, nil, 16),
          ui.column({ flexGrow = 1, gap = 0 }, {
            label(name, 12, "on_surface", true, titleWidth),
            label(thread.subtitle, 10, "on_surface_variant", false, titleWidth),
          }),
          label(noctalia.tr(sms and "messages.sms_source" or (notification and "messages.notification_short"
            or "messages.message")), 10, selected and "primary" or "on_surface_variant", false, badgeWidth),
        })
      end
      add(rows("thread-list", inner, list))
    end
    if data then add(items.notice(inner, data.notice, "threads-notice")) end
    return ui.column({
      key = "message-threads", width = width, height = metrics.body, padding = pad, gap = gap,
      radius = 12, fill = palette("raised", 0.32),
    }, children)
  end

  local function messageRows(width, records, count, thread)
    local device, pageKey = model.selected, model.pageKey
    local list = {}
    for index = 1, count do
      local item = type(records[index]) == "table" and records[index] or {}
      -- Notification records are an event list even if the API marks one as outgoing.
      local sms = thread.kind == "sms"
      local outgoing = item.outgoing == true
      local bubble = sms and outgoing
      local cardWidth = sms and math.floor(width * 0.86) or width
      local time
      if noctalia.formatTime and type(item.date) == "number" and item.date > 0 and item.date < 253402300800000 then
        time = noctalia.formatTime("%d.%m · %H:%M", math.floor(item.date / 1000))
      end
      local textWidth = cardWidth - 68 - (time and 90 or 0)
      local title = preview(item.title, 66)
      local children = {
        components.iconBadge(outgoing and "arrow-up-right" or (sms and "message" or "bell"), 28, nil, nil, 16),
        ui.column({ flexGrow = 1, gap = 0 }, {
          label(title ~= "" and title or noctalia.tr(outgoing and "messages.you" or "messages.message"),
            12, "on_surface", true, textWidth),
          label(item.subtitle, 11, "on_surface_variant", false, textWidth),
        }),
      }
      if time then children[#children + 1] = label(time, 10, "on_surface_variant", false, 84) end
      children[#children + 1] = ui.glyph({ name = "chevron-right", size = 14, color = "on_surface_variant" })
      local card = ui.row({
        key = "page-item-" .. tostring(item.id), width = cardWidth, height = rowHeight,
        gap = 7, paddingH = 8, radius = 9, align = "center",
        fill = bubble and "primary/0.15" or palette("raised", 0.76),
        tooltip = title,
        onClick = function()
          if not model.opened or model.page ~= "messages" or model.selected ~= device or model.pageKey ~= pageKey
            or model.thread ~= thread or type(item.id) ~= "string" or item.id == "" then return end
          model.detail, model.detailPart = item, 0
          actions.render()
        end,
      }, children)
      list[index] = sms and ui.row({
        width = width, height = rowHeight, justify = outgoing and "end" or "start",
      }, { card }) or card
    end
    return rows("page-list", width, list)
  end

  local function fullText(width)
    local detail = model.detail
    local text = type(detail.subtitle) == "string" and detail.subtitle or ""
    if not utf8.len(text) then text = text:gsub("[\128-\255]", "?") end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\194\133", "\n"):gsub("\226\128[\168\169]", "\n")
    -- Page on character and line boundaries so the full text stays readable.
    local first, nextByte = 1, 1
    for _ = 0, model.detailPart do
      first = nextByte
      nextByte = utf8.offset(text, 221, first) or (#text + 1)
      local from = first
      for index = 1, 12 do
        local newline = text:find("\n", from, true)
        if not newline or newline >= nextByte then break end
        from = newline + 1
        if index == 12 then nextByte = from end
      end
    end
    local block = ui.column({
      key = "message-detail", width = width, height = metrics.body - 2 * pad - headingHeight - gap,
      padding = 12, radius = 10, fill = palette("raised", 0.74),
    }, {
      ui.label({
        text = text:sub(first, nextByte - 1), fontFamily = "sans-serif", fontSize = 14,
        maxLines = 20, maxWidth = width - 24, color = "on_surface",
      }),
    })
    local controls = {}
    if model.detailPart > 0 or nextByte <= #text then
      controls[1] = components.pageSteps(model.detailPart + 1, function()
        if model.detail ~= detail then return end
        model.detailPart = math.max(0, model.detailPart - 1)
        actions.render()
      end, function()
        if model.detail ~= detail then return end
        model.detailPart = model.detailPart + 1
        actions.render()
      end, model.detailPart > 0, nextByte <= #text, "text-pagination")
    end
    controls[#controls + 1] = iconButton("back-to-message", "chevron-left", "common.back_to_list", function()
      model.detail, model.detailPart = nil, 0
      actions.render()
    end)
    return block, controls
  end

  local function rightPane(width, online, view, stateNote, refresh)
    local inner = width - 2 * pad
    local thread = model.thread
    local children = {}
    local function add(node)
      if node then children[#children + 1] = node end
    end
    if not thread then
      add(header(inner, noctalia.tr("messages.choose_thread"), nil, {}))
      add(components.pageNote(noctalia.tr("messages.choose_thread_title"), noctalia.tr("messages.choose_thread_hint"),
        "message", inner, 100, nil, "choose-thread"))
    else
      local sms, notification = thread.kind == "sms", thread.kind == "chat"
      local source = noctalia.tr(sms and "messages.sms_source" or (notification
        and "messages.notification_source" or "messages.message"))
      local controls = { iconButton("back-to-threads", "x", "messages.back_to_threads", clearSelection) }
      if model.detail then
        local detail, textControls = fullText(inner)
        add(header(inner, contactTitle(thread), source, textControls))
        add(detail)
      elseif thread.id == "" then
        add(header(inner, noctalia.tr("messages.new_sms"), nil, controls))
        add(components.pageNote(noctalia.tr("messages.recipient"), noctalia.tr("messages.compose_hint"),
          "phone", inner, 92))
        add(forms.recipient(inner))
        add(forms.composer(inner, online, nil))
      else
        local data = readyData(view)
        local messages = data and type(data.items) == "table" and data.items or {}
        local count = math.min(#messages, metrics.limits.thread)
        if data and (#model.cursors > 0 or data.more == true or #messages > count) then
          table.insert(controls, 1, items.pageSteps(data, count, sms, refresh))
        end
        if data and data.reply ~= true then
          source = source .. " · " .. noctalia.tr("messages.reply_unavailable")
        end
        add(header(inner, contactTitle(thread), source, controls))
        if not data then
          add(stateNote(inner, view, "message-state"))
        elseif count == 0 then
          add(components.pageNote(noctalia.tr("common.no_items"), noctalia.tr("pages.messages_empty"),
            "info-circle", inner, 96))
        else
          add(messageRows(inner, messages, count, thread))
        end
        if notification then
          add(items.notice(inner, noctalia.tr("messages.history_notice")))
        elseif data then
          add(items.notice(inner, data.notice))
        end
        add(forms.composer(inner, online, data))
      end
    end
    return ui.column({
      key = "message-thread", width = width, height = metrics.body, padding = pad, gap = gap,
      radius = 12, fill = palette("raised", 0.32),
    }, children)
  end

  local function render(width, online, view, stateNote, refresh)
    local splitGap, listWidth = 10, 338
    return ui.row({
      key = "messages-layout", width = width, height = metrics.body, gap = splitGap, align = "start",
    }, {
      leftPane(listWidth, stateNote),
      rightPane(width - listWidth - splitGap, online, view, stateNote, refresh),
    })
  end
  return { render = render }
end

return M
