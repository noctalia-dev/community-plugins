--!nonstrict
-- Shared section frame: give every page the same height without a global title bar.
local palette = require("./palette.luau")
local geometry = require("./components.luau").layout
local Guide = require("./page_guide.luau")
local Forms = require("./page_forms.luau")
local Calls = require("./page_calls.luau")
local Messages = require("./page_messages.luau")
local M = {}
local metrics = geometry.page
local icons = {
  messages = "message", calls = "phone", photos = "photo",
  apps = "apps", deck = "puzzle", guide = "book",
}

function M.new(model, components, actions, items)
  local label = components.label
  local preview = components.preview
  local note = components.pageNote
  local forms = Forms.new(model, components, actions)
  local calls = Calls.new(model, components, actions, items)
  local messages = Messages.new(model, components, actions, forms, items)

  local function clearDetail()
    model.detail = nil
    model.detailPart = 0
    actions.render()
  end

  local function headingButton(key, glyph, hint, onClick, text, width, enabled)
    return ui.button({
      key = key, glyph = glyph, glyphSize = 17,
      text = text, tooltip = noctalia.tr(hint), width = width or 34, height = 34,
      controlSize = "sm", fontSize = text and 13 or nil,
      variant = text and "primary" or "ghost",
      enabled = enabled ~= false,
      onClick = enabled ~= false and onClick or nil,
    })
  end

  local function header(phone, online, width, view, settings, refresh)
    local page, detail = model.page, model.detail
    local title = components.titles[page]
    local subtitle = noctalia.tr("pages." .. page .. "_hint")
    local leading = components.iconBadge(icons[page], 40, nil, nil, 21)
    local target = model.selected
    if detail and page == "photos" then
      title, subtitle = preview(detail.title, 62), title
      if title == "" then title = subtitle end
      leading = headingButton("back-to-list", "chevron-left", "common.back_to_list", clearDetail)
    end

    local trailing, reserved = {}, 0
    local function append(node, nodeWidth)
      trailing[#trailing + 1] = node
      reserved = reserved + (nodeWidth or node.props.width) + 8
    end
    if phone and page ~= "guide" then
      local status = online and noctalia.tr("connection.connected")
        or (model.snapshot.state == "ready" and noctalia.tr("common.phone_offline")
          or noctalia.tr("common.no_connection"))
      append(ui.row({
        key = "page-phone", gap = 6, height = 26, paddingH = 8, radius = 9,
        fill = palette("raised", 0.72), align = "center",
        tooltip = preview(phone.name, 96) .. " · " .. status,
      }, {
        ui.box({ width = 6, height = 6, radius = 3, fill = online and "primary" or "on_surface_variant" }),
        label(phone.name, 11, "on_surface_variant", false, 166),
      }), 194)
    end
    if page == "messages" then
      local smsDenied = model.snapshot.smsDenied and model.snapshot.smsDenied[target]
      append(headingButton("new-sms", "message-plus", "messages.new_sms", function()
        if model.selected ~= target then return end
        actions.selectThread({ id = "", kind = "sms", title = noctalia.tr("messages.new_sms"), addresses = {} })
      end, noctalia.tr("messages.new_sms"), 142, phone ~= nil and not smsDenied
        and (not model.thread or model.thread.id ~= "")))
    elseif page == "photos" and detail then
      local dispatch = actions.bindAction("page", target)
      local waiting, waitingFor = actions.actionBusy("page")
      append(headingButton("download-photo", "download", "photos.download", function()
        if model.detail == detail then dispatch({ action = "photo", id = detail.id }) end
      end, noctalia.tr(waitingFor == "photo" and "common.sending" or "photos.download"), 185, online and not waiting
        and type(detail.id) == "string" and detail.id ~= ""))
    end
    if view and view.status == "ready" and (view.refreshing or view.stale) then
      local reason
      if view.error then
        local name, description = components.failure(view.error)
        reason = name .. ". " .. description
      end
      local color = view.error and "error" or "on_surface_variant"
      append(ui.row({
        key = "page-cache", height = 26, gap = 5, paddingH = 8, radius = 9,
        align = "center", fill = palette("raised", 0.72),
        tooltip = view.refreshing and noctalia.tr("cache.refreshing") or reason
          or noctalia.tr(view.refreshFailed and "cache.refresh_failed" or "cache.saved"),
      }, {
        ui.glyph({
          name = view.refreshing and "refresh" or "clock",
          size = 14, color = color,
        }),
        label(noctalia.tr(view.refreshing and "cache.updating_badge" or "cache.saved_badge"), 11, color, false, 83),
      }), 118)
    end
    if page ~= "guide" and (model.snapshot.error or (view and view.error)) then
      append(headingButton("help-fork", "book", "common.fork_help", function()
        actions.send("open_fork")
      end))
    end
    if page ~= "guide" then
      local hint = page == "messages" and model.thread and model.thread.id ~= ""
        and "messages.refresh_both" or "common.refresh_page"
      append(headingButton("refresh-page", "refresh", hint, function()
        refresh(true)
      end, nil, nil, phone ~= nil))
    end
    if settings then append(settings) end

    local textWidth = width - reserved - 64
    local children = {
      leading,
      ui.column({ gap = 0 }, {
        label(title, 20, "on_surface", true, textWidth),
        label(subtitle, 11, "on_surface_variant", false, textWidth),
      }),
      ui.spacer({ flexGrow = 1 }),
    }
    for _, node in ipairs(trailing) do children[#children + 1] = node end
    return ui.row({
      key = "page-heading", width = width, height = metrics.heading, gap = 8, align = "center",
    }, children)
  end

  local function photoPreview(width)
    local detail = model.detail
    return ui.column({
      key = "photo-preview", width = width, height = metrics.body, padding = 8,
      radius = 12, fill = palette("raised", 0.72), align = "center", justify = "center",
    }, {
      type(detail.thumbnailPath) == "string" and ui.image({
        path = detail.thumbnailPath, width = width - 16, height = metrics.body - 16,
        fit = "contain", radius = 8,
      }) or label(noctalia.tr("photos.no_thumbnail"), 13, "on_surface_variant", false, width - 32),
    })
  end

  local function renderPage(phone, online, width, settings)
    local inner = width - 2 * metrics.padding
    local view = model.pageView
    if view and view.key ~= model.pageKey then view = nil end
    local data = view and view.status == "ready" and view.data or nil
    local function refresh(force)
      model.pageKey = nil
      actions.loadPage(force)
      actions.render()
    end
    local rows = {}
    local function add(node)
      if node then rows[#rows + 1] = node end
    end

    local page = model.page
    local function stateNote(noteWidth, state, key)
      local failed = state and state.status ~= "loading"
      local reason = model.snapshot.error or (state and state.error)
        or (state and state.status == "unsupported" and "unsupported")
      local title, description
      if reason then
        title, description = components.failure(reason)
      elseif not phone then
        title, description = noctalia.tr("pages.no_phone"), noctalia.tr("pages.no_phone_hint")
      elseif failed then
        title, description = noctalia.tr("pages.failed"), noctalia.tr("pages.retry_hint")
      else
        title, description = noctalia.tr("pages.loading"), noctalia.tr("pages.loading_hint")
      end
      return note(title, description, reason and "info-circle" or icons[page], noteWidth, 104,
        (reason or failed) and "error" or nil, key or "page-state")
    end

    if page == "guide" then
      add(Guide.render(model, components, actions, inner))
    elseif page == "calls" then
      add(calls.render(inner, online, data, function(width)
        return stateNote(width, view)
      end, refresh))
    elseif page == "messages" then
      add(messages.render(inner, online, view, stateNote, refresh))
    elseif model.detail then
      add(photoPreview(inner))
    elseif page == "apps" then
      local pagination = data and items.render(add, online, inner, data, refresh)
      table.insert(rows, 1, forms.appSearch(inner, refresh, pagination))
      if not data then add(stateNote(inner, view)) end
    else
      if page == "photos" then add(forms.photoAlbums(inner, data, refresh)) end
      if data then
        items.render(add, online, inner, data, refresh)
      else
        add(stateNote(inner, view))
      end
    end

    return ui.column({
      key = "sidebar-page",
      width = width, height = geometry.bodyHeight, padding = metrics.padding, gap = metrics.gap,
      align = "start", radius = 14, fill = palette("card"),
    }, {
      header(phone, online, inner, view, settings, refresh),
      ui.column({
        key = "page-body", width = inner, height = metrics.body, gap = metrics.gap, align = "start",
      }, rows),
    })
  end
  return { render = renderPage }
end

return M
