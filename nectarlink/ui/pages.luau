--!nonstrict
-- Pages and confirmations share model-owned drafts and navigation without copying them.
local palette = require("./palette.luau")
local M = {}
function M.new(model, components, actions, items)
  local geometry = require("./components.luau").layout
  local preview = components.preview
  local label = components.label
  local smallButton = components.smallButton
  local pager = components.pager
  local pageNote = components.pageNote
  local titles = components.titles
  local directions = components.directions
  local render = actions.render
  local loadPage = actions.loadPage
  local confirmAction = actions.confirmAction
  local dispatchPageAction = actions.dispatchPageAction
  local renderPageItems = items.render
  local function renderConfirmation(add, online, width)
    add(
      label(
        noctalia.tr("confirm.title", { action = model.pendingAction.title }),
        14,
        "primary",
        true,
        width - 12
      )
    )
    add(ui.label({
      text = preview(model.pendingAction.text or model.pendingAction.id, 180),
      fontFamily = "sans-serif",
      height = 68,
      maxLines = 3,
      maxWidth = width - 12,
      fontSize = 13,
      color = "on_surface",
    }))
    add(label(noctalia.tr("confirm.target"), 12, "on_surface", false, width - 12))
    add(ui.row({ gap = 8 }, {
      smallButton(noctalia.tr("common.cancel"), function()
        model.pendingAction = nil
        render()
      end),
      smallButton(noctalia.tr("common.confirm"), function()
        -- Use the device and text captured when the confirmation opened.
        local actionToConfirm = model.pendingAction
        model.pendingAction = nil
        dispatchPageAction(
          actionToConfirm.action,
          actionToConfirm.id,
          actionToConfirm.text,
          actionToConfirm.recipients,
          actionToConfirm.device
        )
        render()
      end, not model.snapshot.pageActionBusy and (online or model.page == "deck")),
    }))
  end

  local function renderDetailPage(add, width)
    if model.page == "photos" then
      add(ui.column({
        key = "photo-preview",
        width = width - 12,
        height = 350,
        padding = 4,
        radius = 10,
        align = "center",
        justify = "center",
        tooltip = type(model.detail.title) == "string" and model.detail.title
          or noctalia.tr("pages.photos"),
      }, {
        type(model.detail.thumbnailPath) == "string" and ui.image({
          path = model.detail.thumbnailPath,
          width = width - 20,
          height = 342,
          fit = "contain",
          radius = 6,
        }) or label(noctalia.tr("photos.no_thumbnail"), 12, "on_surface_variant"),
      }))
    else
      add(smallButton(noctalia.tr("common.back"), function()
        model.detail = nil
        render()
      end))
      add(label(model.detail.title, 14, "primary", true))
      local fullText = type(model.detail.subtitle) == "string" and model.detail.subtitle or ""
      -- utf8.offset supplies byte boundaries for a 220-character page.
      local firstByte = utf8.offset(fullText, model.detailPart * 220 + 1) or (#fullText + 1)
      local nextByte = utf8.offset(fullText, (model.detailPart + 1) * 220 + 1) or (#fullText + 1)
      add(ui.label({
        text = fullText:sub(firstByte, nextByte - 1),
        fontFamily = "sans-serif",
        fontSize = 14,
        height = 220,
        maxLines = 10,
        maxWidth = width - 12,
        color = "on_surface",
      }))
      add(ui.spacer({ flexGrow = 1 }))
      add(pager(width - 12, model.detailPart + 1, function()
        model.detailPart = math.max(0, model.detailPart - 1)
        render()
      end, function()
        model.detailPart = model.detailPart + 1
        render()
      end, model.detailPart > 0, nextByte <= #fullText, "text-pagination"))
    end
  end

  local function renderMessagesToolbar(add, online, width, data)
    local draftKey = (model.selected or "none")
      .. "|"
      .. (model.thread and model.thread.id or "new")
    local draft = model.pageDrafts[draftKey] or ""
    if model.thread then
      if model.thread.id == "" then
        add(ui.input({
          key = "sms-recipient",
          value = model.recipient,
          placeholder = noctalia.tr("messages.recipient"),
          height = 28,
          controlSize = "sm",
          onChange = function(value)
            model.recipient = value
          end,
        }))
      end
      add(ui.row({ key = "message-composer", width = width - 12, gap = 6, height = 32 }, {
        ui.input({
          key = "message-draft-" .. draftKey,
          value = draft,
          placeholder = noctalia.tr("messages.draft"),
          controlSize = "sm",
          height = 28,
          flexGrow = 1,
          onChange = function(value)
            model.pageDrafts[draftKey] = value
            render()
          end,
        }),
        smallButton(
          noctalia.tr("common.send"),
          function()
            local recipients = model.thread.id == "" and { model.recipient }
              or model.thread.addresses
            confirmAction(
              model.thread.kind == "chat" and "reply" or "sms",
              model.thread.id,
              draft,
              recipients,
              noctalia.tr("confirm.message", { title = preview(model.thread.title, 25) })
            )
          end,
          online
            and not model.snapshot.pageActionBusy
            and draft ~= ""
            and (model.thread.id == "" and model.recipient ~= "" or data and data.reply == true)
        ),
        smallButton(noctalia.tr("common.clear"), function()
          model.pageDrafts[draftKey] = ""
          render()
        end, not model.snapshot.pageActionBusy),
      }))
    end
  end

  local function renderCallsToolbar(add, online, width, data)
    local draftKey = (model.selected or "none") .. "|dial"
    if model.dialOpen then
      add(ui.row({ key = "dial-toolbar", width = width - 12, gap = 6, height = 32 }, {
        ui.input({
          key = "dial-number-" .. tostring(model.selected),
          value = model.pageDrafts[draftKey] or "",
          placeholder = noctalia.tr("calls.number"),
          flexGrow = 1,
          controlSize = "sm",
          height = 28,
          onChange = function(value)
            model.pageDrafts[draftKey] = value
            render()
          end,
        }),
        smallButton(
          noctalia.tr("calls.dial"),
          function()
            confirmAction(
              "dial",
              nil,
              model.pageDrafts[draftKey],
              nil,
              noctalia.tr("confirm.dial", { number = preview(model.pageDrafts[draftKey], 32) })
            )
          end,
          online
            and data
            and data.dial == true
            and (model.pageDrafts[draftKey] or "") ~= ""
            and not model.snapshot.pageActionBusy
        ),
      }))
    end
    if
      data
      and type(data.active) == "table"
      and type(data.active.state) == "string"
      and data.active.state ~= "ended"
    then
      local activeCall = data.active
      local buttons = {
        label(
          (
            type(activeCall.name) == "string" and activeCall.name
            or (
              type(activeCall.number) == "string" and activeCall.number or noctalia.tr("calls.call")
            )
          )
            .. " · "
            .. (directions[activeCall.state] or activeCall.state),
          12,
          "primary"
        ),
      }
      for _, definition in ipairs({
        { "answer", noctalia.tr("calls.answer") },
        { "decline", noctalia.tr("calls.end") },
        { "silence", noctalia.tr("common.silent") },
      }) do
        if definition[1] == "decline" or activeCall.state == "ringing" then
          table.insert(
            buttons,
            smallButton(definition[2], function()
              confirmAction(definition[1], activeCall.id, nil, nil, definition[2])
            end, data.control == true and not model.snapshot.pageActionBusy)
          )
        end
      end
      add(ui.row({ key = "active-call-toolbar", gap = 5, height = 32 }, buttons))
    end
  end

  local function renderAppsToolbar(add, width, refresh)
    local function findApps()
      model.search = model.searchDraft
      model.offset = 0
      model.cursors = {}
      refresh()
    end
    add(ui.row({ key = "app-toolbar", width = width - 12, gap = 6, height = 32 }, {
      ui.input({
        key = "app-search",
        value = model.searchDraft,
        placeholder = noctalia.tr("apps.search"),
        flexGrow = 1,
        controlSize = "sm",
        height = 28,
        onChange = function(value)
          model.searchDraft = value
        end,
        onSubmit = findApps,
      }),
      smallButton(noctalia.tr("common.search"), findApps),
    }))
  end

  local function renderPhotoAlbums(add, width, data, refresh)
    if not data or type(data.albums) ~= "table" then
      return
    end
    local options, albumIds, selectedIndex = { noctalia.tr("photos.all_albums") }, { false }, 0
    for _, photoAlbum in ipairs(data.albums) do
      table.insert(options, photoAlbum.name or photoAlbum.id)
      table.insert(albumIds, photoAlbum.id)
      if photoAlbum.id == model.album then
        selectedIndex = #options - 1
      end
    end
    add(ui.select({
      key = "photo-album",
      width = width - 12,
      options = options,
      selectedIndex = selectedIndex,
      controlSize = "sm",
      height = 28,
      onChange = function(value)
        -- Noctalia indices are zero-based; albumIds is a one-based Lua array.
        model.album = albumIds[(tonumber(value) or 0) + 1] or nil
        model.before = nil
        model.beforeId = nil
        model.offset = 0
        model.cursors = {}
        refresh()
      end,
    }))
  end

  local function renderPageHeading(phone, online, width, refresh)
    local heading = {}
    if (model.page == "calls" and model.dialOpen) or (model.page == "photos" and model.detail) then
      table.insert(
        heading,
        ui.button({
          key = "back-to-list",
          glyph = "chevron-left",
          width = 28,
          height = 28,
          variant = "ghost",
          tooltip = noctalia.tr("common.back_to_list"),
          onClick = function()
            model.dialOpen = false
            model.detail = nil
            model.pendingAction = nil
            render()
          end,
        })
      )
    end
    if model.page == "messages" and model.thread then
      table.insert(
        heading,
        ui.button({
          key = "back-to-threads",
          glyph = "chevron-left",
          width = 28,
          height = 28,
          variant = "ghost",
          tooltip = noctalia.tr("messages.back_to_threads"),
          onClick = function()
            model.thread = nil
            model.offset = 0
            model.cursors = {}
            model.before = nil
            model.pageKey = nil
            render()
          end,
        })
      )
    end
    table.insert(
      heading,
      label(
        model.page == "messages" and model.thread and preview(model.thread.title, 28)
          or titles[model.page],
        16,
        "on_surface",
        true
      )
    )
    table.insert(heading, ui.spacer({ flexGrow = 1 }))
    if phone and model.page ~= "guide" then
      table.insert(heading, label(preview(phone.name, 36), 11, "on_surface_variant"))
    end
    if model.page == "messages" and not model.thread then
      table.insert(
        heading,
        ui.button({
          key = "new-sms",
          glyph = "message-plus",
          width = 28,
          height = 28,
          variant = "ghost",
          tooltip = noctalia.tr("messages.new_sms"),
          onClick = function()
            model.thread =
              { id = "", kind = "sms", title = noctalia.tr("messages.new_sms"), addresses = {} }
            model.offset = 0
            model.before = nil
            model.cursors = {}
            model.pageKey = nil
            render()
          end,
        })
      )
    end
    local view = model.pageView
    if model.page == "calls" and not model.dialOpen and not model.pendingAction then
      table.insert(
        heading,
        ui.button({
          key = "new-call",
          glyph = "phone-plus",
          width = 28,
          height = 28,
          variant = "ghost",
          tooltip = noctalia.tr("calls.new_call"),
          onClick = function()
            model.dialOpen = true
            render()
          end,
        })
      )
    end
    if model.page == "photos" and model.detail and not model.pendingAction then
      table.insert(
        heading,
        ui.button({
          key = "download-photo",
          glyph = "download",
          width = 28,
          height = 28,
          variant = "ghost",
          tooltip = noctalia.tr("photos.download"),
          enabled = online and not model.snapshot.pageActionBusy,
          onClick = online
              and not model.snapshot.pageActionBusy
              and function()
                confirmAction(
                  "photo",
                  model.detail.id,
                  nil,
                  nil,
                  noctalia.tr("confirm.download", {
                    title = type(model.detail.title) == "string" and model.detail.title
                      or noctalia.tr("pages.photos"),
                  })
                )
              end
            or nil,
        })
      )
    end
    if
      view
      and view.key == model.pageKey
      and view.status == "ready"
      and (view.refreshing or view.stale)
    then
      local errorText
      if view.error then
        local title, text = components.failure(view.error)
        errorText = title .. ". " .. text
      end
      table.insert(
        heading,
        ui.row({
          width = 16,
          height = 18,
          tooltip = view.refreshing and noctalia.tr("cache.refreshing")
            or errorText
            or (view.refreshFailed and noctalia.tr("cache.refresh_failed"))
            or noctalia.tr("cache.saved"),
        }, {
          ui.glyph({
            name = view.refreshing and "refresh" or "clock",
            size = 14,
            color = view.error and "error" or "on_surface_variant",
          }),
        })
      )
    end
    if model.page ~= "guide" then
      table.insert(
        heading,
        ui.button({
          key = "refresh-page",
          glyph = "refresh",
          controlSize = "sm",
          height = 28,
          width = 28,
          variant = "ghost",
          tooltip = noctalia.tr("common.refresh_page"),
          enabled = phone ~= nil,
          onClick = function()
            refresh(true)
          end,
        })
      )
    end
    return ui.row(
      { key = "page-heading", width = width - 12, gap = 8, align = "center", height = 32 },
      heading
    )
  end

  local function sidebarPage(phone, online, width)
    local rows = {}
    local function add(node)
      table.insert(rows, node)
    end
    local function refresh(force)
      model.pageKey = nil
      loadPage(force)
      render()
    end
    add(renderPageHeading(phone, online, width, refresh))
    if model.pendingAction then
      renderConfirmation(add, online, width)
    elseif model.page == "guide" then
      local tabs = {}
      for i, title in ipairs({
        noctalia.tr("guide.panel"),
        noctalia.tr("guide.sections"),
        noctalia.tr("guide.help"),
        noctalia.tr("guide.cache"),
        noctalia.tr("guide.compatibility"),
      }) do
        table.insert(
          tabs,
          ui.button({
            key = "guide-tab-" .. i,
            text = title,
            controlSize = "sm",
            height = 28,
            variant = model.guideTopic == i and "secondary" or "ghost",
            onClick = function()
              model.guideTopic = i
              render()
            end,
          })
        )
      end
      add(ui.row({ gap = 6, height = 30 }, tabs))
      local notes = {
        {
          {
            noctalia.tr("guide.widget.title"),
            noctalia.tr("guide.widget.body"),
            "device-mobile",
          },
          {
            noctalia.tr("guide.home.title"),
            noctalia.tr("guide.home.body"),
            "home",
          },
          {
            noctalia.tr("guide.settings.title"),
            noctalia.tr("guide.settings.body"),
            "settings",
          },
        },
        {
          {
            noctalia.tr("guide.messages.title"),
            noctalia.tr("guide.messages.body"),
            "message",
          },
          {
            noctalia.tr("guide.photos.title"),
            noctalia.tr("guide.photos.body"),
            "photo",
          },
          {
            noctalia.tr("guide.deck.title"),
            noctalia.tr("guide.deck.body"),
            "layout-grid",
          },
        },
        {
          {
            noctalia.tr("guide.connection.title"),
            noctalia.tr("guide.connection.body"),
            "wifi",
          },
          {
            noctalia.tr("guide.history.title"),
            noctalia.tr("guide.history.body"),
            "message",
          },
          {
            noctalia.tr("guide.unconfirmed.title"),
            noctalia.tr("guide.unconfirmed.body"),
            "info-circle",
          },
        },
      }
      -- Three cards per tab keep the guide within the fixed panel height.
      notes[4] = {
        {
          noctalia.tr("guide.navigation.title"),
          noctalia.tr("guide.navigation.body"),
          "history",
        },
        {
          noctalia.tr("guide.refresh.title"),
          noctalia.tr("guide.refresh.body"),
          "refresh",
        },
        {
          noctalia.tr("guide.reload.title"),
          noctalia.tr("guide.reload.body"),
          "info-circle",
        },
      }
      notes[5] = {
        {
          noctalia.tr("guide.fork.title"),
          noctalia.tr("guide.fork.body"),
          "device-mobile",
        },
        {
          noctalia.tr("guide.niri.title"),
          noctalia.tr("guide.niri.body"),
          "info-circle",
        },
        {
          noctalia.tr("guide.checks.title"),
          noctalia.tr("guide.checks.body"),
          "settings",
        },
      }
      for _, note in ipairs(notes[model.guideTopic]) do
        add(pageNote(note[1], note[2], note[3], 88, width - 12))
      end
    elseif model.detail then
      renderDetailPage(add, width)
    else
      local view = model.pageView
      local data = view and view.key == model.pageKey and view.status == "ready" and view.data
        or nil
      if model.page == "messages" then
        renderMessagesToolbar(add, online, width, data)
      elseif model.page == "calls" then
        renderCallsToolbar(add, online, width, data)
      elseif model.page == "apps" then
        renderAppsToolbar(add, width, refresh)
      elseif model.page == "photos" then
        renderPhotoAlbums(add, width, data, refresh)
      end
      local newSms = model.page == "messages" and model.thread and model.thread.id == ""
      if not data and not newSms then
        local failed = view and view.key == model.pageKey and view.status ~= "loading"
        local reason = model.snapshot.error
          or (view and view.error)
          or (view and view.status == "unsupported" and "unsupported")
        local errorTitle, errorText
        if reason then
          errorTitle, errorText = components.failure(reason)
        end
        add(
          pageNote(
            errorTitle
              or (
                not phone and noctalia.tr("pages.no_phone")
                or (failed and noctalia.tr("pages.failed") or noctalia.tr("pages.loading"))
              ),
            errorText
              or (failed and noctalia.tr("pages.retry_hint") or noctalia.tr("pages.loading_hint")),
            failed and "wifi" or "device-mobile",
            88,
            width - 12
          )
        )
      elseif not newSms then
        renderPageItems(add, online, width, data, refresh)
      end
    end
    model.pageHeight = geometry.pageHeight
    return ui.column({
      key = "sidebar-page",
      width = width,
      height = model.pageHeight,
      gap = 4,
      padding = 6,
      align = "start",
      justify = "start",
      radius = 10,
      fill = palette("card", 0.5),
    }, rows)
  end
  return { render = sidebarPage }
end
return M
