--!nonstrict
-- Forms use controller-owned drafts. Only an explicit Send click can send one.
local palette = require("./palette.luau")
local metrics = require("./components.luau").layout.page
local M = {}

function M.new(model, components, actions)
  local function actionButton(text, enabled, onClick)
    return ui.button({
      text = text,
      controlSize = "sm",
      height = 32,
      variant = "primary",
      enabled = enabled == true,
      onClick = enabled == true and onClick or nil,
    })
  end

  local function fieldRow(key, width, children)
    return ui.row({
      key = key, width = width, height = metrics.toolbar, gap = 8, paddingH = 8,
      align = "center", radius = 10, fill = palette("raised", 0.72),
    }, children)
  end

  local function input(props)
    props.controlSize = "sm"
    props.height = 32
    props.flexGrow = 1
    return ui.input(props)
  end

  local function composer(width, online, data)
    local thread, device = model.thread, model.selected
    local isNew = thread.id == ""
    local draftKey = (device or "none") .. "|" .. (isNew and "new" or thread.id)
    local draft = model.pageDrafts[draftKey] or ""
    local revision = model.pageDraftRevisions[draftKey] or 0
    local dispatch = actions.bindAction("page", device)
    local waiting, waitingFor = actions.actionBusy("page")
    local function editingThread()
      return model.opened and model.page == "messages" and model.selected == device and model.thread == thread
        and (model.pageDraftRevisions[draftKey] or 0) == revision
    end
    local function messagePayload(text, view)
      if type(text) ~= "string" or #text > 4096 or not text:find("%S") then return nil end
      if not isNew and (not view or view.reply ~= true) then return nil end
      if thread.kind == "chat" then
        if thread.id:sub(1, 5) == "chat:" then
          return { action = "reply", id = thread.id, text = text }
        end
        return nil
      end
      local recipients = isNew and { model.recipient } or thread.addresses
      if thread.kind ~= "sms" or type(recipients) ~= "table" or #recipients == 0 or #recipients > 10 then return nil end
      for _, address in ipairs(recipients) do
        if type(address) ~= "string" or #address > 128 or not address:find("%S") or address:find("%c") then return nil end
      end
      return { action = "sms", id = thread.id, text = text, recipients = recipients }
    end
    local canSend = online and not waiting and messagePayload(draft, data) ~= nil
    local sendingMessage = waitingFor == "sms" or waitingFor == "reply"
    return fieldRow("message-composer", width, {
      components.iconBadge("message", 28, "on_surface_variant", "transparent", 18),
      input({
        key = "message-draft-" .. draftKey .. "-" .. revision,
        value = draft,
        placeholder = noctalia.tr("messages.draft"),
        onChange = function(value)
          if not editingThread() then return end
          model.pageDrafts[draftKey] = value
          actions.render()
        end,
      }),
      components.smallButton(noctalia.tr("common.clear"), function()
        if not editingThread() then return end
        model.pageDrafts[draftKey] = ""
        model.pageDraftRevisions[draftKey] = revision + 1
        actions.render()
      end, not waiting),
      actionButton(noctalia.tr(sendingMessage and "common.sending" or "common.send"), canSend, function()
        if not editingThread() then return end
        local live = model.pageView and model.pageView.data
        local payload = messagePayload(model.pageDrafts[draftKey], live)
        if payload then dispatch(payload) end
      end),
    })
  end

  local function recipient(width)
    local device, thread = model.selected, model.thread
    return fieldRow("recipient-toolbar", width, {
      components.iconBadge("phone", 28, "on_surface_variant", "transparent", 18),
      input({
        key = "sms-recipient-" .. tostring(device),
        value = model.recipient,
        placeholder = noctalia.tr("messages.recipient"),
        onChange = function(value)
          if not model.opened or model.page ~= "messages" or model.selected ~= device
            or model.thread ~= thread then return end
          model.recipient = value
          actions.render()
        end,
      }),
    })
  end

  local function appSearch(width, refresh, pagination)
    local function findApps()
      model.search = model.searchDraft
      model.offset = 0
      model.cursors = {}
      refresh()
    end
    local controls = {
      components.iconBadge("search", 28, "on_surface_variant", "transparent", 18),
      input({
        key = "app-search",
        value = model.searchDraft,
        placeholder = noctalia.tr("apps.search"),
        onChange = function(value)
          model.searchDraft = value
        end,
        onSubmit = findApps,
      }),
      components.smallButton(noctalia.tr("common.search"), findApps),
    }
    if pagination then controls[#controls + 1] = pagination end
    return fieldRow("app-toolbar", width, controls)
  end

  local function photoAlbums(width, data, refresh)
    if not data or type(data.albums) ~= "table" then
      return nil
    end
    local options, ids, selectedIndex = { noctalia.tr("photos.all_albums") }, { false }, 0
    for _, album in ipairs(data.albums) do
      if type(album) == "table" and type(album.id) == "string" then
        options[#options + 1] = album.name or album.id
        ids[#ids + 1] = album.id
        if album.id == model.album then
          selectedIndex = #options - 1
        end
      end
    end
    return ui.row({ key = "album-toolbar", width = width, height = metrics.toolbar, gap = 8, align = "center" }, {
      ui.select({
        key = "photo-album",
        options = options,
        selectedIndex = selectedIndex,
        controlSize = "sm",
        width = 264,
        height = 36,
        onChange = function(value)
          -- Noctalia sends zero-based indices, Lua arrays are one-based.
          model.album = ids[(tonumber(value) or 0) + 1] or nil
          model.before = nil
          model.beforeId = nil
          model.offset = 0
          model.cursors = {}
          refresh()
        end,
      }),
    })
  end

  return {
    composer = composer, recipient = recipient,
    appSearch = appSearch, photoAlbums = photoAlbums,
  }
end

return M
