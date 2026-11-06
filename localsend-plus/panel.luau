--!nonstrict
-- Panel: incoming request, nearby devices (send files, a folder or the
-- clipboard) and recent transfers.

local lib = require("./lib.luau")

local open = false
local MAX_LISTED_FILES = 5
local MAX_LISTED_FOLDERS = 3
local MAX_PREVIEW_LINES = 10
-- Label widths inside a card and across the whole panel.
local CARD_TEXT_WIDTH = 340
local TEXT_WIDTH = 360
-- States that show a progress bar and a cancel button.
local IN_PROGRESS = { preparing = true, transferring = true }

-- The list scrolls inside the panel's full height, which plugin.toml sets.
local function panelHeight()
  local manifest = noctalia.readFile(lib.PLUGIN_DIR .. "/plugin.toml") or ""
  return tonumber(manifest:match("%[%[panel%]%][^%[]-\nheight%s*=%s*(%d+)")) or 560
end
local PANEL_HEIGHT = panelHeight()

local function tr(key, args)
  return noctalia.tr(key, args)
end

-- Controller error codes with a translated message.
local ERROR_KEYS = { insufficient_space = "error.insufficient_space" }

local function rpc(args, onOk)
  lib.rpc(args, function(ok, result, err)
    if ok then
      if onOk then onOk(result) end
    elseif err and ERROR_KEYS[err.code] then
      noctalia.notifyError(tr("notify.title"), tr(ERROR_KEYS[err.code]) .. "\n" .. (err.message or ""))
    else
      noctalia.notifyError(tr("notify.title"), lib.errorText(err))
    end
    lib.poke()
  end)
end

-- The file picker takes focus and closes this panel, so the service runs it;
-- the panel reopens once the send has started.
local function pick(peer, folder)
  lib.request(folder and "folder" or "files", peer)
  panel.close()
end

-- The whole clipboard text travels in the request itself, so the receiver
-- sees it even if they decline: sending asks first and shows what it holds.
-- The controller reads the preview and the SHA-256 of the whole text in one
-- go, and refuses to send if the clipboard no longer matches that hash.
local CLIP_PREVIEW_CHARS = 400
local clipConfirm = nil -- { fingerprint, peer, preview, more, sha, files, error } while asking

-- MIME type password managers offer next to a copied secret.
local PASSWORD_HINT_TYPE = "x-kde-passwordManagerHint"

local render

local function stillAsking(peer)
  return clipConfirm ~= nil and clipConfirm.fingerprint == peer.fingerprint
end

local function readClipboardText(peer)
  lib.readClipboard(CLIP_PREVIEW_CHARS, function(ok, result, err)
    if not stillAsking(peer) then return end
    if ok then
      clipConfirm.sha = result.sha256
      clipConfirm.preview = result.preview
      clipConfirm.more = result.truncated
    elseif err.code == "empty_text" or err.code == "clipboard_unavailable" then
      clipConfirm.preview = ""
    elseif err.code == "clipboard_secret" then
      clipConfirm.error = tr("error.clipboard_secret")
    else
      clipConfirm.error = lib.errorText(err)
    end
    render()
  end)
end

-- Local paths from a text/uri-list (what file managers put on the clipboard
-- for copied files), or nil when it names anything but local files.
local function copiedPaths(text)
  local paths = {}
  for _, line in ipairs(text:split("\n")) do
    line = lib.trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local path = lib.pathFromUri(line)
      if path == nil then return nil end
      table.insert(paths, path)
    end
  end
  return #paths > 0 and paths or nil
end

local function readCopiedFiles(peer)
  noctalia.runAsync({ "wl-paste", "--no-newline", "--type", "text/uri-list" }, function(res)
    if not stillAsking(peer) then return end
    clipConfirm.files = copiedPaths(res.stdout or "") or false
    render()
  end)
end

-- Copied files are sent as files; anything else as text. A password is
-- neither read nor shown.
local function askClipboard(peer)
  clipConfirm = { fingerprint = peer.fingerprint, peer = peer }
  render()
  noctalia.runAsync({ "wl-paste", "--list-types" }, function(res)
    if not stillAsking(peer) then return end
    local types = {}
    for _, line in ipairs((res.stdout or ""):split("\n")) do
      types[lib.trim(line)] = true
    end
    if types[PASSWORD_HINT_TYPE] then
      clipConfirm.error = tr("error.clipboard_secret")
      render()
    elseif types["text/uri-list"] then
      readCopiedFiles(peer)
    else
      readClipboardText(peer)
    end
  end)
end

local function sendClipboard()
  local peer = clipConfirm and clipConfirm.peer
  local sha = clipConfirm and clipConfirm.sha
  local files = clipConfirm and clipConfirm.files
  clipConfirm = nil
  if peer ~= nil and files then
    lib.request("paths", peer, nil, files)
  elseif peer ~= nil and sha ~= nil then
    lib.request("clipboard", peer, sha)
  end
  render()
end

-- A clipboard send asked for from the launcher ({ seq, fingerprint, at }):
-- opens the confirmation for that device. Requests older than a few seconds
-- are stale (state outlives the panel).
local lastClipAsk = nil
local CLIP_ASK_MAX_AGE = 10

local function takeClipAsk()
  local req = noctalia.state.get("clip_ask")
  if type(req) ~= "table" or req.seq == lastClipAsk then return end
  lastClipAsk = req.seq
  if os.time() - (req.at or 0) > CLIP_ASK_MAX_AGE then return end
  local ls = noctalia.state.get("ls") or {}
  for _, entry in ipairs(lib.sortedDevices(ls.devices)) do
    local d = entry.device
    if d.fingerprint == req.fingerprint and d.online and d.address ~= nil then
      askClipboard(d)
      return
    end
  end
end

-- Up to MAX_LISTED_FILES names of local paths, then "and N more".
local function pathSummary(paths)
  local names = {}
  for _, path in ipairs(paths) do
    table.insert(names, lib.basename(path))
  end
  return lib.summary(names, MAX_LISTED_FILES)
end

-- The folders the paths come from, so a file hidden among many still shows
-- where it lives.
local function folderSummary(paths)
  local folders, seen = {}, {}
  for _, path in ipairs(paths) do
    local folder = lib.dirname(path)
    if not seen[folder] then
      seen[folder] = true
      table.insert(folders, folder)
    end
  end
  return tr("panel.from_folders", { folders = lib.summary(folders, MAX_LISTED_FOLDERS) })
end

local function clipboardCard()
  local preview, files = clipConfirm.preview, clipConfirm.files
  local name = clipConfirm.peer.alias
  local rows = {}
  local ready
  if clipConfirm.error ~= nil then
    table.insert(
      rows,
      ui.label({ text = clipConfirm.error, fontSize = 12, color = "error", maxWidth = CARD_TEXT_WIDTH, maxLines = 3 })
    )
    ready = false
  elseif files then
    table.insert(
      rows,
      ui.label({ text = tr("panel.files_confirm", { name = name, count = tostring(#files) }), fontWeight = "bold" })
    )
    table.insert(rows, ui.label({ text = pathSummary(files), maxLines = 3, maxWidth = CARD_TEXT_WIDTH, fontSize = 12 }))
    table.insert(
      rows,
      ui.label({
        text = folderSummary(files),
        maxLines = 2,
        maxWidth = CARD_TEXT_WIDTH,
        fontSize = 11,
        color = "on_surface_variant",
      })
    )
    ready = true
  elseif files == false then
    table.insert(
      rows,
      ui.label({
        text = tr("panel.files_not_local"),
        fontSize = 12,
        color = "error",
        maxWidth = CARD_TEXT_WIDTH,
        maxLines = 3,
      })
    )
    ready = false
  else
    table.insert(rows, ui.label({ text = tr("panel.clip_confirm", { name = name }), fontWeight = "bold" }))
    if preview == nil then
      table.insert(rows, ui.label({ text = tr("panel.clip_loading"), fontSize = 12, color = "on_surface_variant" }))
    elseif preview == "" then
      table.insert(rows, ui.label({ text = tr("panel.clip_empty"), fontSize = 12, color = "on_surface_variant" }))
    else
      table.insert(
        rows,
        ui.label({
          text = preview .. (clipConfirm.more and "…" or ""),
          maxLines = 4,
          maxWidth = CARD_TEXT_WIDTH,
          fontSize = 12,
        })
      )
    end
    ready = preview ~= nil and preview ~= "" and clipConfirm.sha ~= nil
  end
  table.insert(
    rows,
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("panel.clip_send"),
        glyph = "send",
        variant = "primary",
        controlSize = "sm",
        enabled = ready,
        onClick = sendClipboard,
      }),
      ui.button({
        text = tr("panel.cancel"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          clipConfirm = nil
          render()
        end,
      }),
    })
  )
  return ui.column(
    { key = "clip-" .. clipConfirm.fingerprint, gap = 6, padding = 10, radius = 10, fill = "surface_container" },
    rows
  )
end

-- Dolphin answers xdg-open for a folder it already shows by raising that
-- window, which Hyprland ignores without an activation token, so nothing
-- appears. A new window always shows up. Any other default file manager
-- gets the folder through xdg-open.
local function openFolder(path)
  local function open(useDolphin)
    if useDolphin then
      noctalia.runAsync({ "dolphin", "--new-window", path })
    else
      noctalia.runAsync({ "xdg-open", path })
    end
    panel.close()
  end
  if noctalia.commandExists("dolphin") and noctalia.commandExists("xdg-mime") then
    noctalia.runAsync({ "xdg-mime", "query", "default", "inode/directory" }, function(res)
      open(lib.trim(res.stdout or "") == "org.kde.dolphin.desktop")
    end)
  else
    open(false)
  end
end

-- `autoAccept` is the mode in effect: pinning a device then also means
-- taking its files without asking, which the pin's tooltip says.
local function deviceRow(d, pinned, autoAccept)
  local host = d.address and d.address.host or ""
  local tip = host
  if d.model ~= nil and d.model ~= "" then tip = d.model .. "  ·  " .. host end
  tip = tip .. "\n" .. tr("panel.fingerprint", { fp = lib.shortFingerprint(d.fingerprint) })
  if d.reportedAlias ~= nil then tip = tip .. "\n" .. tr("panel.reported_alias", { name = d.reportedAlias }) end
  local enabled = d.online == true and d.address ~= nil
  local dim = enabled and 1 or 0.5
  return ui.row({ key = "dev-" .. d.fingerprint, align = "center", gap = 2 }, {
    ui.button({
      glyph = lib.deviceGlyph(d.type),
      text = d.alias,
      variant = "ghost",
      contentAlign = "start",
      flexGrow = 1,
      enabled = enabled,
      opacity = dim,
      tooltip = enabled and tr("panel.send_files", { name = d.alias }) .. "\n" .. tip or tr("panel.offline"),
      onClick = function()
        pick(d, false)
      end,
    }),
    -- Stays enabled for offline favorites so they can be unpinned.
    ui.button({
      glyph = pinned and "pinned" or "pin",
      variant = "ghost",
      selected = pinned,
      tooltip = tr(pinned and "panel.unpin" or (autoAccept ~= "off" and "panel.pin_auto" or "panel.pin")),
      onClick = function()
        lib.setFavorite(d, not pinned)
      end,
    }),
    ui.button({
      glyph = "folder",
      variant = "ghost",
      enabled = enabled,
      opacity = dim,
      tooltip = tr("panel.send_folder", { name = d.alias }),
      onClick = function()
        pick(d, true)
      end,
    }),
    ui.button({
      glyph = "clipboard",
      variant = "ghost",
      enabled = enabled,
      opacity = dim,
      tooltip = tr("panel.send_clipboard", { name = d.alias }),
      onClick = function()
        askClipboard(d)
      end,
    }),
  })
end

local function fileSummary(files, total)
  local names = {}
  for _, f in ipairs(files or {}) do
    table.insert(names, f.name)
  end
  local text = lib.summary(names, MAX_LISTED_FILES)
  if total ~= nil then text = text .. "  ·  " .. lib.formatBytes(total) end
  return text
end

local function incomingCard(inc)
  local name, impostor = lib.peerLabel(inc.sender)
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "download", size = 18, color = "primary" }),
      ui.label({ text = tr("panel.incoming_from", { name = name }), fontWeight = "bold", flexGrow = 1 }),
    }),
  }
  if impostor then
    table.insert(
      rows,
      ui.label({ text = tr("panel.impostor"), fontSize = 12, color = "error", maxWidth = CARD_TEXT_WIDTH, maxLines = 3 })
    )
  end
  if inc.messagePreview ~= nil then
    local text = inc.messagePreview
    if inc.messagePreviewTruncated then text = text .. "…" end
    table.insert(rows, ui.label({ text = text, maxLines = MAX_PREVIEW_LINES, maxWidth = CARD_TEXT_WIDTH }))
    -- The clipboard gets the whole text; say so when the preview cannot show it.
    local lines = select(2, text:gsub("\n", "")) + 1
    if inc.messagePreviewTruncated or lines > MAX_PREVIEW_LINES then
      table.insert(
        rows,
        ui.label({
          text = tr("panel.text_long", { size = lib.formatBytes(inc.totalBytes) }),
          fontSize = 11,
          color = "error",
          maxWidth = CARD_TEXT_WIDTH,
          maxLines = 3,
        })
      )
    end
    table.insert(rows, ui.label({ text = tr("panel.text_hint"), fontSize = 11, color = "on_surface_variant" }))
  else
    table.insert(
      rows,
      ui.label({
        text = fileSummary(inc.files, inc.totalBytes),
        maxLines = 3,
        maxWidth = CARD_TEXT_WIDTH,
        fontSize = 12,
        color = "on_surface_variant",
      })
    )
  end
  table.insert(
    rows,
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("panel.accept"),
        glyph = "check",
        variant = "primary",
        onClick = function()
          rpc({ "accept", "--request", inc.id })
        end,
      }),
      ui.button({
        text = tr("panel.decline"),
        glyph = "x",
        variant = "outline",
        onClick = function()
          rpc({ "decline", "--request", inc.id })
        end,
      }),
    })
  )
  return ui.column({
    key = "inc-" .. inc.id,
    gap = 6,
    padding = 12,
    radius = 10,
    fill = "primary/0.12",
    border = "primary/0.5",
    borderWidth = 1,
  }, rows)
end

-- A failed send the receiver wants a PIN for can be retried from its row;
-- the service still holds what was sent (state "retry_id").
local retryPins = {} -- transfer id -> PIN typed so far

local function retryWithPin(id, pin)
  if not lib.validPin(pin) then
    noctalia.notifyError(tr("notify.title"), tr("pin.invalid"))
    return
  end
  retryPins[id] = nil
  lib.post("pin_retry", { id = id, pin = pin })
end

local function pinRetryRow(t)
  return ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "retry-" .. t.id,
      password = true,
      focus = true,
      flexGrow = 1,
      controlSize = "sm",
      placeholder = tr("pin.receiver_placeholder"),
      onChange = function(value)
        retryPins[t.id] = value
      end,
      onSubmit = function(value)
        retryWithPin(t.id, value)
      end,
    }),
    ui.button({
      text = tr("pin.send"),
      glyph = "lock",
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        retryWithPin(t.id, retryPins[t.id])
      end,
    }),
  })
end

local function transferRow(t)
  local incoming = t.direction == "incoming"
  local name = lib.peerLabel(t.peer)
  local code = t.error and t.error.code
  local rows = {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = incoming and "download" or "upload", size = 16, color = "on_surface_variant" }),
      ui.label({
        text = tr(incoming and "panel.from" or "panel.to", { name = name }),
        fontWeight = "bold",
        flexGrow = 1,
      }),
      ui.label({ text = tr("status." .. t.state), fontSize = 12, color = "on_surface_variant" }),
    }),
    ui.label({
      text = t.textMessage and tr("panel.text_message") or fileSummary(t.files, t.totalBytes),
      maxLines = 2,
      maxWidth = CARD_TEXT_WIDTH,
      fontSize = 12,
      color = "on_surface_variant",
    }),
  }
  if IN_PROGRESS[t.state] then
    local p = (t.totalBytes or 0) > 0 and (t.completedBytes or 0) / t.totalBytes or 0
    table.insert(rows, ui.progress({ progress = p, height = 6 }))
  end
  local errorText = lib.transferError(t.error)
  if errorText ~= nil then
    table.insert(
      rows,
      ui.label({ text = errorText, fontSize = 11, color = "error", maxWidth = CARD_TEXT_WIDTH, maxLines = 2 })
    )
  end
  if t.state == "failed" and lib.PIN_ERRORS[code] and t.id == noctalia.state.get("retry_id") then
    table.insert(rows, pinRetryRow(t))
  end

  local buttons = {}
  if IN_PROGRESS[t.state] then
    table.insert(
      buttons,
      ui.button({
        text = tr("panel.cancel"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          rpc({ "cancel", "--transfer", t.id })
        end,
      })
    )
  end
  if incoming and t.state == "completed" then
    local first = t.files and t.files[1]
    local path = first and first.destinationPath
    if not t.textMessage and path ~= nil then
      table.insert(
        buttons,
        ui.button({
          glyph = "folder-open",
          text = tr("panel.open_folder"),
          variant = "outline",
          controlSize = "sm",
          onClick = function()
            openFolder(lib.dirname(path))
          end,
        })
      )
    elseif t.textMessage then -- the controller copied it on accept
      table.insert(
        buttons,
        ui.button({
          glyph = "clipboard-check",
          text = tr("panel.in_clipboard"),
          variant = "ghost",
          controlSize = "sm",
          enabled = false,
        })
      )
    end
  end
  if #buttons > 0 then table.insert(rows, ui.row({ gap = 8 }, buttons)) end

  return ui.column({ key = "tr-" .. t.id, gap = 4, padding = 10, radius = 10, fill = "surface_container" }, rows)
end

local visMenu = false -- the visibility chooser is open
local visShown = nil -- the visibility change shown while the panel is open

-- Identifies one visibility change; the card describing it is shown until
-- the panel has been closed once with it on screen.
local function visKey(vis)
  local temp = vis.tempUntil ~= nil and vis.tempUntil > 0
  return tostring(vis.seq or 0) .. ":" .. tostring(vis.mode) .. (temp and ":temp" or "")
end

local function visibilityText(vis)
  if vis.tempUntil ~= nil and vis.tempUntil > 0 then
    return tr(
      "visibility.temp_left",
      { minutes = tostring(lib.minutesLeft(vis.tempUntil)), mode = tr("visibility." .. vis.base) }
    )
  end
  return tr("visibility.title", { mode = tr("visibility." .. vis.mode) })
end

-- Current mode with what it means; the chooser adds the mode buttons.
local function visibilityCard(ls)
  local vis = ls.vis
  local temp = vis.tempUntil ~= nil and vis.tempUntil > 0
  local rows = {
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({
        name = lib.visibilityGlyph(vis.mode),
        size = 16,
        color = vis.mode == "everyone" and "primary" or "on_surface_variant",
      }),
      ui.label({ text = visibilityText(vis), fontWeight = "bold", flexGrow = 1, maxWidth = 320 }),
    }),
  }
  if visMenu then
    local function choice(mode)
      return ui.button({
        text = tr("visibility.short_" .. mode),
        glyph = lib.visibilityGlyph(mode),
        controlSize = "sm",
        variant = (not temp and vis.base == mode) and "primary" or "outline",
        onClick = function()
          lib.requestVisibility(mode, false)
        end,
      })
    end
    table.insert(rows, ui.row({ gap = 6 }, { choice("everyone"), choice("favorites"), choice("hidden") }))
    table.insert(
      rows,
      ui.row({ gap = 6 }, {
        ui.button({
          text = tr("visibility.temp"),
          glyph = "clock",
          controlSize = "sm",
          variant = temp and "primary" or "outline",
          onClick = function()
            lib.requestVisibility("everyone", true)
          end,
        }),
      })
    )
  end
  local notes = { tr("visibility.desc_" .. vis.mode) }
  if vis.mode == "favorites" and next(lib.favorites()) == nil then
    table.insert(notes, tr("visibility.no_favorites"))
  end
  if vis.mode == "hidden" and ls.daemon ~= nil and ls.daemon.receiving then
    table.insert(notes, tr("visibility.draining"))
  end
  table.insert(
    rows,
    ui.label({
      text = table.concat(notes, " "),
      fontSize = 11,
      color = "on_surface_variant",
      maxWidth = CARD_TEXT_WIDTH,
      maxLines = 5,
    })
  )
  return ui.column({ key = "visibility", gap = 6, padding = 10, radius = 10, fill = "surface_container" }, rows)
end

-- The receive PIN. The input is uncontrolled, so a new key clears it.
local pinMenu = false
local pinField = 0
local pinDraft = ""

local function setReceivePin(pin)
  if pin ~= nil and not lib.validPin(pin) then
    noctalia.notifyError(tr("notify.title"), tr("pin.invalid"))
    return
  end
  lib.post("pin_req", { pin = pin })
  pinDraft, pinField, pinMenu = "", pinField + 1, false
  render()
end

-- The service keeps the choice.
local function setAcceptWithPin(on)
  lib.post("auto_req", { on = on })
end

local function pinCard(ls)
  local required = ls.daemon ~= nil and ls.daemon.pinRequired
  return ui.column({ key = "pin", gap = 6, padding = 10, radius = 10, fill = "surface_container" }, {
    ui.label({ text = tr(required and "pin.on" or "pin.off"), fontWeight = "bold" }),
    ui.label({
      text = tr("pin.desc"),
      fontSize = 11,
      color = "on_surface_variant",
      maxWidth = CARD_TEXT_WIDTH,
      maxLines = 4,
    }),
    ui.input({
      key = "pin-" .. pinField,
      password = true,
      focus = true,
      controlSize = "sm",
      placeholder = tr(required and "pin.change_placeholder" or "pin.placeholder"),
      onChange = function(value)
        pinDraft = value
      end,
      onSubmit = function(value)
        setReceivePin(value)
      end,
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("pin.set"),
        glyph = "lock",
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          setReceivePin(pinDraft)
        end,
      }),
      ui.button({
        text = tr("pin.remove"),
        glyph = "lock-open",
        variant = "outline",
        controlSize = "sm",
        enabled = required,
        onClick = function()
          setReceivePin(nil)
        end,
      }),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = tr("pin.auto"), fontSize = 12, flexGrow = 1, maxWidth = 290, maxLines = 2 }),
      ui.toggle({
        checked = ls.autoAcceptChoice == "everyone",
        onChange = function(value)
          setAcceptWithPin(value == true or value == "true")
        end,
      }),
    }),
  })
end

-- Adding a device by address, for networks where discovery cannot reach it.
local addOpen = false
local addDraft = ""

local function addDevice(address)
  address = lib.trim(address or "")
  if address == "" then return end
  lib.rpc({ "add-device", "--address", address }, function(ok, result, err)
    if ok then
      addOpen, addDraft = false, ""
      local found = result and result.device
      noctalia.notify(tr("notify.title"), tr("notify.device_added", { name = found and found.alias or address }))
    elseif err and err.code == "invalid_arguments" then
      noctalia.notifyError(tr("notify.title"), tr("error.bad_address"))
    elseif err and err.code == "device_unreachable" then
      noctalia.notifyError(tr("notify.title"), tr("error.device_unreachable", { address = address }))
    else
      noctalia.notifyError(tr("notify.title"), lib.errorText(err))
    end
    lib.poke()
  end)
end

local function addDeviceCard()
  return ui.column({ key = "add", gap = 6, padding = 10, radius = 10, fill = "surface_container" }, {
    ui.label({
      text = tr("panel.add_desc"),
      fontSize = 11,
      color = "on_surface_variant",
      maxWidth = CARD_TEXT_WIDTH,
      maxLines = 4,
    }),
    ui.input({
      key = "add-address",
      focus = true,
      controlSize = "sm",
      placeholder = tr("panel.add_placeholder"),
      onChange = function(value)
        addDraft = value
      end,
      onSubmit = function(value)
        addDevice(value)
      end,
    }),
    ui.row({ gap = 8 }, {
      ui.button({
        text = tr("panel.add"),
        glyph = "plus",
        variant = "primary",
        controlSize = "sm",
        onClick = function()
          addDevice(addDraft)
        end,
      }),
      ui.button({
        text = tr("panel.cancel"),
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          addOpen = false
          render()
        end,
      }),
    }),
  })
end

-- Paths handed over by IPC `send` ({ seq, paths, at }), waiting for the
-- user to pick a device. Requests older than a minute are stale.
local sendPaths = nil
local lastSendAsk = nil
local SEND_ASK_MAX_AGE = 60

local function takeSendAsk()
  local req = noctalia.state.get("send_ask")
  if type(req) ~= "table" or req.seq == lastSendAsk then return end
  lastSendAsk = req.seq
  if os.time() - (req.at or 0) > SEND_ASK_MAX_AGE then return end
  sendPaths = req.paths
  render()
end

local function sendAskCard(devices)
  local rows = {
    ui.label({ text = tr("panel.send_ask", { count = tostring(#sendPaths) }), fontWeight = "bold" }),
    ui.label({
      text = pathSummary(sendPaths),
      maxLines = 3,
      maxWidth = CARD_TEXT_WIDTH,
      fontSize = 12,
      color = "on_surface_variant",
    }),
    ui.label({
      text = folderSummary(sendPaths),
      maxLines = 2,
      maxWidth = CARD_TEXT_WIDTH,
      fontSize = 11,
      color = "on_surface_variant",
    }),
  }
  local any = false
  for _, entry in ipairs(devices) do
    local d = entry.device
    if d.online and d.address ~= nil then
      any = true
      table.insert(
        rows,
        ui.button({
          glyph = lib.deviceGlyph(d.type),
          text = d.alias,
          variant = "outline",
          contentAlign = "start",
          onClick = function()
            lib.request("paths", d, nil, sendPaths)
            sendPaths = nil
            render()
          end,
        })
      )
    end
  end
  if not any then
    table.insert(
      rows,
      ui.label({
        text = tr("panel.no_devices"),
        fontSize = 12,
        color = "on_surface_variant",
        maxWidth = CARD_TEXT_WIDTH,
      })
    )
  end
  table.insert(
    rows,
    ui.button({
      text = tr("panel.cancel"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        sendPaths = nil
        render()
      end,
    })
  )
  return ui.column({
    key = "send-ask",
    gap = 6,
    padding = 12,
    radius = 10,
    fill = "primary/0.12",
    border = "primary/0.5",
    borderWidth = 1,
  }, rows)
end

local function header(ls)
  local vis, daemon = ls.vis, ls.daemon
  local pinRequired = daemon ~= nil and daemon.pinRequired
  local buttons = {
    ui.glyph({ name = "send", size = 20, color = "primary" }),
    ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
  }
  -- Favorites are accepted by default; only accepting anyone with the PIN
  -- is worth a reminder in the header.
  if daemon ~= nil and daemon.autoAccept == "everyone" then
    table.insert(
      buttons,
      ui.button({
        glyph = "robot",
        variant = "ghost",
        tooltip = tr("auto_accept.active", { mode = tr("auto_accept." .. daemon.autoAccept) }),
        onClick = function()
          noctalia.openSettings()
        end,
      })
    )
  end
  table.insert(
    buttons,
    ui.button({
      glyph = pinRequired and "lock" or "lock-open",
      variant = "ghost",
      selected = pinMenu,
      tooltip = tr(pinRequired and "pin.on" or "pin.off"),
      onClick = function()
        pinMenu = not pinMenu
        render()
      end,
    })
  )
  table.insert(
    buttons,
    ui.button({
      glyph = lib.visibilityGlyph(vis and vis.mode),
      variant = "ghost",
      selected = visMenu,
      tooltip = vis and visibilityText(vis) .. "\n" .. tr("visibility.change") or tr("visibility.change"),
      onClick = function()
        visMenu = not visMenu
        render()
      end,
    })
  )
  table.insert(
    buttons,
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      tooltip = tr("panel.refresh"),
      onClick = function()
        rpc({ "refresh" })
      end,
    })
  )
  table.insert(
    buttons,
    ui.button({
      glyph = "settings",
      variant = "ghost",
      tooltip = tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    })
  )
  table.insert(
    buttons,
    ui.button({
      glyph = "x",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    })
  )
  return ui.row({ align = "center", gap = 8 }, buttons)
end

function render()
  if not open then return end
  local ls = noctalia.state.get("ls") or { up = false }
  local children = { header(ls) }

  if not ls.up then
    local text = ls.startError or tr(ls.phase == "failed" and "error.unknown" or "panel.starting")
    table.insert(
      children,
      ui.label({
        text = text,
        color = ls.startError and "error" or "on_surface_variant",
        maxWidth = TEXT_WIDTH,
        maxLines = 4,
      })
    )
    if ls.install ~= nil then
      table.insert(
        children,
        ui.label({ text = tr("panel.install_hint"), fontSize = 12, maxWidth = TEXT_WIDTH, maxLines = 6 })
      )
      table.insert(
        children,
        ui.label({ text = ls.install, fontSize = 11, color = "on_surface_variant", maxWidth = TEXT_WIDTH, maxLines = 4 })
      )
    end
    if ls.phase == "failed" then
      local buttons = {
        ui.button({
          glyph = "refresh",
          text = tr("panel.retry"),
          variant = "outline",
          onClick = function()
            noctalia.state.set("restart", (noctalia.state.get("restart") or 0) + 1)
          end,
        }),
      }
      if ls.install ~= nil then
        table.insert(
          children,
          ui.button({
            glyph = "terminal",
            text = tr("panel.update_in_terminal"),
            onClick = function()
              if not noctalia.runInTerminal(lib.updateCommand(true)) then
                noctalia.notifyError(tr("notify.title"), tr("error.no_terminal"))
              end
            end,
          })
        )
        table.insert(
          buttons,
          ui.button({
            glyph = "copy",
            text = tr("panel.copy_command"),
            variant = "outline",
            onClick = function()
              noctalia.copyToClipboard(ls.install, "text/plain")
            end,
          })
        )
      end
      table.insert(children, ui.row({ gap = 8 }, buttons))
    end
    panel.render(ui.column({ gap = 10, padding = 16 }, children))
    return
  end

  -- Shown while choosing, once after a change to a restricted or temporary
  -- mode, and while hidden mode waits for a transfer to end. The header
  -- button's tooltip keeps telling the current mode.
  local vis = ls.vis
  if vis ~= nil then
    local key = visKey(vis)
    local restricted = vis.mode ~= "everyone" or (vis.tempUntil or 0) > 0
    local draining = vis.mode == "hidden" and ls.daemon ~= nil and ls.daemon.receiving
    local unseen = restricted and key ~= noctalia.state.get("vis_seen")
    if visMenu or draining or unseen then
      table.insert(children, visibilityCard(ls))
      if unseen then visShown = key end
    end
  end

  if pinMenu then table.insert(children, pinCard(ls)) end
  -- Everyone was chosen, but the controller narrows it to favorites until a
  -- PIN is set.
  if ls.autoAcceptChoice == "everyone" and ls.daemon ~= nil and ls.daemon.autoAccept ~= "everyone" then
    table.insert(
      children,
      ui.label({
        text = tr("auto_accept.needs_pin"),
        fontSize = 11,
        color = "error",
        maxWidth = TEXT_WIDTH,
        maxLines = 3,
      })
    )
  end

  if ls.incoming ~= nil then table.insert(children, incomingCard(ls.incoming)) end

  local devices = lib.sortedDevices(ls.devices)
  if sendPaths ~= nil then table.insert(children, sendAskCard(devices)) end

  table.insert(
    children,
    ui.row({ align = "center", gap = 4 }, {
      ui.label({ text = tr("panel.nearby"), fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "plus",
        variant = "ghost",
        controlSize = "sm",
        selected = addOpen,
        tooltip = tr("panel.add_device"),
        onClick = function()
          addOpen = not addOpen
          render()
        end,
      }),
    })
  )
  if addOpen then table.insert(children, addDeviceCard()) end
  if #devices == 0 then
    table.insert(
      children,
      ui.label({ text = tr("panel.no_devices"), color = "on_surface_variant", maxWidth = TEXT_WIDTH, fontSize = 12 })
    )
  else
    local autoAccept = ls.daemon and ls.daemon.autoAccept or "off"
    for _, entry in ipairs(devices) do
      table.insert(children, deviceRow(entry.device, entry.pinned, autoAccept))
      if clipConfirm ~= nil and clipConfirm.fingerprint == entry.device.fingerprint then
        table.insert(children, clipboardCard())
      end
    end
  end

  local destination = ls.daemon and ls.daemon.destination
  local hidden = lib.hiddenTransfers()
  local transfers, finished = {}, false
  for _, t in ipairs(ls.transfers or {}) do
    if not hidden[t.id] then
      table.insert(transfers, t)
      if not lib.ACTIVE[t.state] then finished = true end
    end
  end
  if #transfers > 0 then
    table.insert(children, ui.separator({ spacing = 4 }))
    table.insert(
      children,
      ui.row({ align = "center", gap = 4 }, {
        ui.label({ text = tr("panel.transfers"), fontWeight = "bold", flexGrow = 1 }),
        ui.button({
          glyph = "trash",
          variant = "ghost",
          controlSize = "sm",
          enabled = finished,
          tooltip = tr("panel.clear_history"),
          onClick = function()
            lib.clearHistory(ls.transfers)
          end,
        }),
      })
    )
    for _, t in ipairs(transfers) do
      table.insert(children, transferRow(t))
    end
  end

  if ls.error ~= nil and ls.error.message ~= nil then
    table.insert(
      children,
      ui.label({
        text = ls.error.message,
        fontSize = 11,
        color = "on_surface_variant",
        maxWidth = TEXT_WIDTH,
        maxLines = 2,
      })
    )
  end

  local footer = {}
  if ls.daemon ~= nil then
    local key = ({ favorites = "panel.visible_favorites", hidden = "panel.hidden_as" })[ls.daemon.visibility]
      or "panel.visible_as"
    table.insert(
      footer,
      ui.label({
        text = tr(key, { name = ls.daemon.alias }),
        fontSize = 11,
        color = "on_surface_variant",
        flexGrow = 1,
      })
    )
  end
  if destination ~= nil then
    table.insert(
      footer,
      ui.button({
        glyph = "folder-open",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.saving_to", { dir = destination }),
        onClick = function()
          openFolder(destination)
        end,
      })
    )
  end

  -- Header stays fixed, the list scrolls over the full height, footer at the bottom.
  local head = table.remove(children, 1)
  panel.render(ui.column({ gap = 8, padding = 16, height = PANEL_HEIGHT }, {
    head,
    ui.scroll({ gap = 10, flexGrow = 1 }, children),
    ui.row({ align = "center", gap = 4 }, footer),
  }))
end

function onOpen()
  open = true
  noctalia.state.set("panel_open", true)
  lib.poke()
  render()
  takeClipAsk()
  takeSendAsk()
end

function onClose()
  open = false
  clipConfirm = nil
  visMenu = false
  pinMenu, pinDraft = false, ""
  addOpen, addDraft = false, ""
  sendPaths = nil
  retryPins = {}
  if visShown ~= nil then
    noctalia.state.set("vis_seen", visShown)
    visShown = nil
  end
  noctalia.state.set("panel_open", false)
end

noctalia.state.watch("ls", function()
  render()
end)
noctalia.state.watch("favorites", function()
  render()
end)
noctalia.state.watch("hidden", function()
  render()
end)
noctalia.state.watch("clip_ask", function()
  if open then takeClipAsk() end
end)
noctalia.state.watch("send_ask", function()
  if open then takeSendAsk() end
end)
noctalia.state.watch("retry_id", function()
  render()
end)
