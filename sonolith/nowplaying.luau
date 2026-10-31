--!nonstrict
-- Now Playing panel: the current item with transport, seek, volume, rating, save to playlist, autoplay,
-- the current lyric line and the queue. While not connected it shows the connect screens instead.
-- Every control needs its scope; without it the control is hidden.
--
-- panel.openContextMenu only works from a right click, so the ⋮ menu and a queue row's left click open
-- inline action rows, and "save to playlist" is a native select.

local S = require("./lib/state.luau")
local commands = require("./lib/commands.luau")
local format = require("./lib/format.luau")
local art = require("./lib/art.luau")
local parts = require("./lib/ui_parts.luau")

commands.init("nowplaying")

local LIBRARY = "opecko/sonolith:library"
local PLAYLISTS_TTL_MS = 10 * 60 * 1000
local VOLUME_SEND_GAP_MS = 150
local FLASH_MS = 3000
local RATES = { 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3 }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

local isOpen = false
local busy = false -- a connect/disconnect request is on its way
local lastError = nil
local menuOpen = false
local showAllQueue = false
local fullQueue = nil -- queue.get page for "Show all"
local fullQueueRev = nil
local openRow = nil -- entryId whose inline actions are shown
local seekDraft = nil
local volumeDraft = nil
local lastVolumeSentAt = 0
local ratingOverride = {} -- trackId -> rating, until Sonolith reports it
local flash = nil -- { text, until }
local playlists = nil -- editable playlists
local playlistsAt = 0
local playlistsLoading = false
local saveKey = 0 -- fresh key resets the playlist select after a pick
local thumbs = {} -- item id -> local path

local function render() end -- defined below

local function showFlash(text)
  flash = { text = text, untilMs = noctalia.nowMs() + FLASH_MS }
  render()
end

local function can(scope)
  return S.hasScope(scope)
end

local function send(method, params, cb)
  commands.send(method, params, function(ok, result, err)
    if not ok and err and err.name == "PermissionDenied" then
      render() -- scopes changed under us; the control hides on the next state update
    end
    if cb then
      cb(ok, result, err)
    end
  end)
end

local function thumb(item)
  if not item or not item.id then
    return nil
  end
  local path = thumbs[item.id] or select(2, art.cached(item.id))
  if path then
    thumbs[item.id] = path
    return path
  end
  if thumbs[item.id] == nil and item.thumbnailUrl then
    thumbs[item.id] = false
    art.fetch(item.id, item.thumbnailUrl, function(_, p)
      thumbs[item.id] = p or false
      if p and isOpen then
        render()
      end
    end)
  end
  return nil
end

---- Connection screens

local function title(text)
  return ui.label({ text = text, fontSize = 15, fontWeight = "semibold", color = "on_surface", textAlign = "center" })
end

local function body(text)
  return ui.label({ text = text, color = "on_surface_variant", maxLines = 4, textAlign = "center" })
end

local function credit()
  return ui.label({ text = tr("np.usesSonolith"), fontSize = 11, color = "on_surface_variant" })
end

local function button(text, glyph, handler, variant, enabled)
  return ui.button({
    text = text,
    glyph = glyph,
    variant = variant or "default",
    enabled = enabled ~= false and not busy,
    onClick = handler,
  })
end

local function statusScreen(glyph, heading, text, buttons, glyphColor)
  local children = {
    ui.glyph({ name = glyph, size = 36, color = glyphColor or "primary" }),
    title(heading),
  }
  if text then
    table.insert(children, body(text))
  end
  if lastError then
    table.insert(children, ui.label({ text = lastError, color = "error", fontSize = 12, maxLines = 3 }))
  end
  if buttons and #buttons > 0 then
    table.insert(children, ui.row({ gap = 8, justify = "center" }, buttons))
  end
  return ui.column({ gap = 12, padding = 16, align = "center", fill = "surface_container_high", radius = 12 }, children)
end

local function request(method, params)
  busy = true
  lastError = nil
  render()
  commands.send(method, params, function(ok, _, err)
    busy = false
    if not ok and err and err.name ~= "RegistrationDenied" and err.name ~= "Blocked" then
      lastError = err.name == "Unavailable" and tr("np.unavailable.title") or tr("np.error.generic", { name = err.name or "?" })
    end
    render()
  end)
end

function onConnect()
  request("bridge.register")
end

function onCancelConnect()
  request("bridge.cancelRegister")
end

function onRetry()
  request("bridge.retry")
end

function onDisconnect()
  menuOpen = false
  request("bridge.disconnect")
end

local function waitLeft(conn)
  return conn.retryAt and math.max(0, conn.retryAt - noctalia.nowMs()) or 0
end

local function connectionScreen(conn)
  local state = conn.state
  if state == "error" and conn.message == "noPython" then
    return statusScreen("alert-triangle", tr("np.noPython.title"), tr("np.noPython.body"), nil, "error")
  elseif state == "error" and conn.message == "unsupportedVersion" then
    return statusScreen("alert-triangle", tr("np.unsupported.title"), tr("np.unsupported.body"), nil, "error")
  elseif state == "error" then
    return statusScreen("alert-triangle", tr("np.error.title"), conn.message, nil, "error")
  elseif state == "starting" then
    return statusScreen("loader-2", tr("np.starting.title"), nil, nil)
  elseif state == "unavailable" then
    return statusScreen("music-off", tr("np.unavailable.title"), tr("np.unavailable.body"), {
      button(tr("np.openSonolith"), "external-link", "onOpenSonolith", "primary"),
    }, "on_surface_variant")
  elseif state == "unregistered" then
    return statusScreen("plug-connected", tr("np.unregistered.title"), tr("np.unregistered.body"), {
      button(tr("np.connect"), "plug-connected", "onConnect", "primary"),
    })
  elseif state == "pending" then
    local text = conn.kind == "identity" and tr("np.pending.identity") or tr("np.pending.body")
    local buttons = conn.kind ~= "identity" and { button(tr("np.cancel"), nil, "onCancelConnect", "outline") } or nil
    return statusScreen("hourglass", tr("np.pending.title"), text, buttons)
  elseif state == "denied" or state == "expired" then
    local left = waitLeft(conn)
    local heading = state == "denied" and tr("np.denied.title") or tr("np.expired.title")
    local text = left > 0 and tr("np.denied.wait", { time = format.wait(left) }) or tr("np.denied.ready")
    local handler = conn.kind == "identity" and "onRetry" or "onConnect"
    return statusScreen("ban", heading, text, {
      button(tr("np.tryAgain"), "refresh", handler, "primary", left <= 0),
    }, "on_surface_variant")
  elseif state == "blocked" then
    return statusScreen("lock", tr("np.blocked.title"), tr("np.blocked.body"), {
      button(tr("np.tryAgain"), "refresh", "onConnect", "outline"),
    }, "error")
  elseif state == "disconnected" then
    return statusScreen("plug-connected-x", tr("np.disconnected.title"), tr("np.disconnected.body"), {
      button(tr("np.connect"), "plug-connected", "onConnect", "primary"),
    }, "on_surface_variant")
  end
  return statusScreen("help", state or "?", nil, nil)
end

---- Header and ⋮ menu

function onOpenSonolith()
  menuOpen = false
  noctalia.runAsync({ "sonolith" }) -- once per click, never on our own
end

function onOpenSettings()
  menuOpen = false
  noctalia.openSettings()
end

function onToggleMenu()
  menuOpen = not menuOpen
  render()
end

function onOpenLibrary()
  noctalia.togglePanel(LIBRARY)
end

local function header(connected)
  local children = {
    ui.glyph({ name = "music", size = 18, color = "primary" }),
    ui.label({ text = tr("np.title"), fontWeight = "semibold", color = "on_surface", flexGrow = 1 }),
  }
  if connected and (can("library:read") or can("search")) then
    table.insert(children, ui.button({ text = tr("np.library"), glyph = "books", variant = "outline", controlSize = "sm", onClick = "onOpenLibrary" }))
  end
  if connected then
    table.insert(children, ui.button({ glyph = "dots-vertical", variant = "ghost", controlSize = "sm", selected = menuOpen, tooltip = tr("np.more"), onClick = "onToggleMenu" }))
  end
  return ui.row({ key = "header", gap = 8, align = "center" }, children)
end

local function menu()
  local function item(text, glyph, handler)
    return ui.button({ text = text, glyph = glyph, variant = "ghost", controlSize = "sm", onClick = handler, enabled = not busy })
  end
  return ui.row({ key = "menu", gap = 8, paddingH = 8, height = 44, radius = 12, align = "center", fill = "surface_container_high" }, {
    item(tr("np.openSonolith"), "external-link", "onOpenSonolith"),
    item(tr("np.settings"), "settings", "onOpenSettings"),
    item(tr("np.disconnect"), "logout", "onDisconnect"),
    ui.label({ text = tr("np.usesSonolith"), fontSize = 11, color = "on_surface_variant", flexGrow = 1, textAlign = "end" }),
  })
end

---- Rating and playlists

local function currentRating(item)
  local o = ratingOverride[item.id]
  if o ~= nil then
    return o
  end
  return item.rating
end

local function rate(rating)
  local item = S.track()
  if not item then
    return
  end
  local target = currentRating(item) == rating and "none" or rating
  ratingOverride[item.id] = target
  render()
  send("rating.set", { item = { type = item.type, id = item.id }, rating = target }, function(ok)
    if not ok then
      ratingOverride[item.id] = nil
      render()
    end
  end)
end

function onLike()
  rate("like")
end

function onDislike()
  rate("dislike")
end

local function loadPlaylists()
  if playlistsLoading or not (can("library:read") and can("library:write")) or S.get(S.SIGNED_IN) == false then
    return
  end
  if playlists and noctalia.nowMs() - playlistsAt < PLAYLISTS_TTL_MS then
    return
  end
  playlistsLoading = true
  local found = {}
  local function page(cursor, n)
    send("library.playlists", { cursor = cursor, limit = 100 }, function(ok, result)
      if not ok then
        playlistsLoading = false
        return
      end
      for _, p in ipairs(result.items or {}) do
        if p.editable then
          table.insert(found, p)
        end
      end
      if result.nextCursor and n < 3 then
        page(result.nextCursor, n + 1)
      else
        playlists, playlistsAt, playlistsLoading = found, noctalia.nowMs(), false
        render()
      end
    end)
  end
  page(nil, 1)
end

function onSaveToPlaylist(index, text)
  local item = S.track()
  local i = tonumber(index)
  local playlist = playlists and i and playlists[i] -- index 0 is the prompt
  if playlists and (not playlist or playlist.title ~= text) then
    playlist = nil
    for _, p in ipairs(playlists) do
      if p.title == text then
        playlist = p
      end
    end
  end
  saveKey += 1
  if not item or not playlist then
    render()
    return
  end
  send("playlist.addTracks", { id = playlist.id, items = { { type = item.type, id = item.id } } }, function(ok, result)
    if ok and result and (result.added or 0) == 0 then
      showFlash(tr("np.saved.already", { playlist = playlist.title }))
    elseif ok then
      showFlash(tr("np.saved", { playlist = playlist.title }))
    else
      showFlash(tr("np.saved.failed"))
    end
  end)
  render()
end

---- Transport

function onToggle()
  send("player.toggle")
end

function onPrevious()
  send("player.previous")
end

function onNext()
  send("player.next")
end

function onShuffle()
  local player = S.get(S.PLAYER)
  if player then
    send("player.setShuffle", { enabled = not player.shuffle })
  end
end

function onRepeat()
  local player = S.get(S.PLAYER)
  if player then
    local nextMode = ({ off = "all", all = "one", one = "off" })[player["repeat"]] or "all"
    send("player.setRepeat", { mode = nextMode })
  end
end

function onSkipBack()
  send("player.seek", { offsetMs = -10000 })
end

function onSkipForward()
  send("player.seek", { offsetMs = 30000 })
end

function onRate(index)
  local speed = RATES[(tonumber(index) or 0) + 1]
  if speed then
    send("player.setRate", { rate = speed })
  end
end

function onSeekChange(value)
  seekDraft = tonumber(value)
  render()
end

function onSeekEnd()
  if seekDraft then
    local target = math.floor(seekDraft)
    send("player.seek", { positionMs = target }, function()
      seekDraft = nil
      render()
    end)
  end
end

local function sendVolume(force)
  if volumeDraft and (force or noctalia.nowMs() - lastVolumeSentAt >= VOLUME_SEND_GAP_MS) then
    lastVolumeSentAt = noctalia.nowMs()
    local target = math.floor(volumeDraft)
    send("player.setVolume", { volume = target }, function()
      if force and volumeDraft == target then
        volumeDraft = nil
      end
    end)
  end
end

function onVolumeChange(value)
  volumeDraft = tonumber(value)
  sendVolume(false)
  render()
end

function onVolumeEnd()
  sendVolume(true)
end

function onMute()
  local player = S.get(S.PLAYER)
  if player then
    send("player.setVolume", { muted = not player.muted })
  end
end

function onAutoplay(value)
  send("queue.setAutoplay", { enabled = value == "true" })
end

---- Queue

local function fetchFullQueue()
  local q = S.get(S.QUEUE)
  if not q then
    return
  end
  local rev = q.revision
  send("queue.get", { fromIndex = q.currentIndex or 0, limit = 100 }, function(ok, result)
    if ok and showAllQueue then
      fullQueue, fullQueueRev = result, rev
      render()
    end
  end)
end

function onToggleQueue()
  showAllQueue = not showAllQueue
  if showAllQueue then
    fetchFullQueue()
  else
    fullQueue = nil
  end
  render()
end

local function queueEntry(entryId)
  local q = (showAllQueue and fullQueue) or S.get(S.QUEUE)
  for _, e in ipairs(q and q.items or {}) do
    if e.entryId == entryId then
      return e
    end
  end
  return nil
end

local function queueAction(action, entryId)
  openRow = nil
  local q = S.get(S.QUEUE)
  if action == "remove" then
    send("queue.remove", { entryIds = { entryId } })
  elseif action == "next" and q and q.currentIndex then
    send("queue.move", { entryId = entryId, toIndex = q.currentIndex + 1 })
  end
  render()
end

-- Native menu (right click on a row's ⋮).
function onQueueMenu(actionId, entryId)
  queueAction(actionId, entryId)
end

local function queueMenuItems()
  return {
    { id = "next", label = tr("np.queue.playNext") },
    { id = "remove", label = tr("np.queue.remove") },
  }
end

local function queueSection(limit)
  local q = (showAllQueue and fullQueue) or S.get(S.QUEUE)
  if not q or not q.items then
    return nil
  end
  local rows = {}
  local count, total = 0, 0
  local canWrite = can("queue:write")
  for _, e in ipairs(q.items) do
    if e.index ~= q.currentIndex then
      total += 1
      if showAllQueue or count < limit then
        count += 1
        local entryId = e.entryId
        local menuLeft = canWrite and function()
          openRow = openRow ~= entryId and entryId or nil
          render()
        end or nil
        local menuRight = canWrite and function()
          panel.openContextMenu({ items = queueMenuItems(), onActivate = "onQueueMenu", context = entryId })
        end or nil
        table.insert(rows, parts.mediaRow(e.item, {
          key = "q-" .. entryId,
          artPath = thumb(e.item),
          artSize = 32,
          dim = e.autoplay,
          selected = openRow == entryId,
          onClick = menuLeft,
          onMenu = menuLeft,
          onMenuRight = menuRight,
        }))
        if openRow == entryId then
          table.insert(rows, ui.row({ key = "qa-" .. entryId, gap = 8, paddingH = 8, justify = "end" }, {
            ui.button({ text = tr("np.queue.playNext"), glyph = "arrow-bar-to-up", variant = "ghost", controlSize = "sm", onClick = function()
              queueAction("next", entryId)
            end }),
            ui.button({ text = tr("np.queue.remove"), glyph = "trash", variant = "ghost", controlSize = "sm", onClick = function()
              queueAction("remove", entryId)
            end }),
          }))
        end
      end
    end
  end
  local more = (q.length or 0) - (q.currentIndex or 0) - 1
  local trailing = {}
  local player = S.get(S.PLAYER)
  if can("queue:write") and type(player) == "table" then
    table.insert(trailing, ui.label({ text = tr("np.autoplay"), fontSize = 12, color = "on_surface_variant" }))
    table.insert(trailing, ui.toggle({ checked = player.autoplay == true, onChange = "onAutoplay" }))
  end
  if more > limit or showAllQueue then
    table.insert(trailing, ui.button({
      text = showAllQueue and tr("np.queue.less") or tr("np.queue.all"),
      glyph = showAllQueue and "chevron-up" or "chevron-down",
      variant = "ghost",
      controlSize = "sm",
      onClick = "onToggleQueue",
    }))
  end
  local list
  if total == 0 then
    list = ui.label({ text = tr("np.queue.empty"), fontSize = 12, color = "on_surface_variant" })
  else
    list = ui.scroll({ flexGrow = 1, gap = 2 }, rows)
  end
  return ui.column({ key = "queue", gap = 8, flexGrow = 1 }, {
    parts.sectionHeader(tr("np.queue.title"), ui.row({ gap = 8, align = "center" }, trailing)),
    list,
  })
end

---- Lyrics

-- How many of the line's words have started, from the extrapolated position.
local function sungWords(words)
  local pos = S.positionNow()
  local count = 0
  for i, w in ipairs(words) do
    if w.startMs and w.startMs <= pos then
      count = i
    end
  end
  return count
end

local function lyricsSection()
  local lyrics = S.get(S.LYRICS)
  local item = S.track()
  if type(lyrics) ~= "table" or not item or lyrics.trackId ~= item.id then
    return nil
  end
  if lyrics.status == "instrumental" then
    return ui.label({ text = tr("np.lyrics.instrumental"), color = "on_surface_variant" })
  end
  if lyrics.status ~= "found" or lyrics.tier == "unsynced" then
    return nil
  end
  -- Fixed height, so it never takes the queue's space: the current line (lit up word by word when the
  -- lyrics have word timings) and the next one, dimmed. During a break the first row is a note.
  local current
  if not lyrics.line then
    current = ui.label({ text = "♪", fontWeight = "medium", color = "on_surface_variant", maxLines = 1 })
  elseif lyrics.words then
    local sung, rest = {}, {}
    local count = sungWords(lyrics.words)
    for i, w in ipairs(lyrics.words) do
      table.insert(i <= count and sung or rest, w.text)
    end
    local sungText, restText = table.concat(sung), table.concat(rest)
    -- Labels drop edge spaces, so the space between the halves becomes a gap (none inside a split word).
    local gap = (string.match(sungText, "%s$") and restText ~= "") and 4 or 0
    current = ui.row({ gap = gap, align = "center" }, {
      ui.label({ text = noctalia.string.trim(sungText), fontWeight = "medium", color = "primary", maxLines = 1, visible = sungText ~= "" }),
      ui.label({ text = noctalia.string.trim(restText), fontWeight = "medium", color = "on_surface/0.5", maxLines = 1, flexGrow = 1, visible = restText ~= "" }),
    })
  else
    current = ui.label({ text = lyrics.line, fontWeight = "medium", color = "primary", maxLines = 1 })
  end
  return ui.row({ key = "lyrics", gap = 12, paddingH = 12, height = 60, radius = 10, align = "center", fill = "surface_container_high" }, {
    ui.glyph({ name = "microphone-2", size = 16, color = "on_surface_variant" }),
    ui.column({ gap = 2, flexGrow = 1, justify = "center" }, {
      current,
      ui.label({ text = lyrics.nextLine or "", fontSize = 12, color = "on_surface_variant", maxLines = 1, visible = lyrics.nextLine ~= nil }),
    }),
  })
end

---- The player

local function infoBlock(item)
  local titleRow = {
    ui.label({ text = item.title or "", fontSize = 20, fontWeight = "semibold", color = "on_surface", maxLines = 2, flexGrow = 1 }),
  }
  if item.explicit then
    table.insert(titleRow, parts.explicitBadge())
  end
  local children = {
    ui.row({ gap = 8, align = "start" }, titleRow),
    ui.label({ text = format.artists(item), fontSize = 15, color = "on_surface_variant", maxLines = 1 }),
  }
  local album = format.album(item)
  if album ~= "" and album ~= format.artists(item) then
    table.insert(children, ui.label({ text = album, fontSize = 13, color = "on_surface_variant/0.8", maxLines = 1 }))
  end

  -- Rating and saving change the user's YouTube account.
  local actions = {}
  if can("library:write") and S.get(S.SIGNED_IN) ~= false then
    local rating = currentRating(item)
    table.insert(actions, ui.button({
      key = "like",
      glyph = rating == "like" and "heart-filled" or "heart",
      variant = "ghost",
      controlSize = "sm",
      selected = rating == "like",
      tooltip = tr("np.like"),
      onClick = "onLike",
    }))
    if item.type == "track" then
      table.insert(actions, ui.button({
        key = "dislike",
        glyph = rating == "dislike" and "thumb-down-filled" or "thumb-down",
        variant = "ghost",
        controlSize = "sm",
        selected = rating == "dislike",
        tooltip = tr("np.dislike"),
        onClick = "onDislike",
      }))
    end
    if playlists and #playlists > 0 then
      -- The first option is the prompt and stays selected; a select never shows its placeholder once it
      -- has options.
      local names = { tr("np.saveTo") }
      for _, p in ipairs(playlists) do
        table.insert(names, p.title)
      end
      table.insert(actions, ui.select({
        key = "save-" .. saveKey,
        options = names,
        selectedIndex = 0,
        controlSize = "sm",
        width = 200,
        onChange = "onSaveToPlaylist",
      }))
    end
  end
  if flash and noctalia.nowMs() < flash.untilMs then
    table.insert(actions, ui.label({ key = "flash", text = flash.text, fontSize = 12, color = "primary" }))
  end
  if #actions > 0 then
    table.insert(children, ui.row({ gap = 4, align = "center" }, actions))
  end
  return ui.column({ key = "info", gap = 4 }, children)
end

local function seekRow(player, item)
  local pos, dur = S.positionNow()
  dur = dur or item.durationMs
  local shown = seekDraft or pos
  local canSeek = can("player:control") and dur ~= nil and dur > 0
  return ui.row({ key = "seek-row", gap = 8, align = "center" }, {
    ui.label({ text = format.duration(shown), fontSize = 12, color = "on_surface_variant", width = 40 }),
    ui.slider({
      key = "seek",
      min = 0,
      max = math.max(dur or 1, 1),
      step = 1000,
      value = shown,
      enabled = canSeek,
      flexGrow = 1,
      onChange = "onSeekChange",
      onDragEnd = "onSeekEnd",
    }),
    ui.label({ text = format.duration(dur), fontSize = 12, color = "on_surface_variant", width = 40, textAlign = "end" }),
  })
end

local function transportRow(player, item)
  local playing = player.status == "playing" or player.status == "buffering"
  local episode = item.type == "episode"
  local mode = player["repeat"]
  local function side(props)
    props.variant = props.variant or "ghost"
    return ui.button(props)
  end
  local left = episode
    and side({ glyph = "rewind-backward-10", tooltip = tr("np.back10"), onClick = "onSkipBack" })
    or side({ glyph = "arrows-shuffle", selected = player.shuffle, tooltip = tr("np.shuffle"), onClick = "onShuffle" })
  local right = episode
    and side({ glyph = "rewind-forward-30", tooltip = tr("np.forward30"), onClick = "onSkipForward" })
    or side({
      glyph = mode == "one" and "repeat-once" or "repeat",
      selected = mode ~= "off",
      tooltip = tr("np.repeat." .. (mode or "off")),
      onClick = "onRepeat",
    })
  return ui.row({ key = "transport", gap = 12, justify = "center", align = "center" }, {
    left,
    side({ glyph = "player-skip-back-filled", enabled = player.canGoPrevious ~= false, onClick = "onPrevious" }),
    ui.button({ glyph = playing and "player-pause-filled" or "player-play-filled", variant = "primary", controlSize = "lg", glyphSize = 22, onClick = "onToggle" }),
    side({ glyph = "player-skip-forward-filled", enabled = player.canGoNext ~= false, onClick = "onNext" }),
    right,
  })
end

local function volumeRow(player, item)
  local volume = volumeDraft or player.volume or 0
  local glyph = (player.muted or volume == 0) and "volume-off" or (volume < 50 and "volume-2" or "volume")
  local children = {
    ui.button({ glyph = glyph, variant = "ghost", controlSize = "sm", selected = player.muted, tooltip = tr("np.mute"), onClick = "onMute" }),
    ui.slider({ key = "volume", min = 0, max = 100, step = 1, value = volume, flexGrow = 1, onChange = "onVolumeChange", onDragEnd = "onVolumeEnd" }),
  }
  if item.type == "episode" then
    local names, selected = {}, nil
    for i, r in ipairs(RATES) do
      table.insert(names, `{r}×`)
      if r == player.episodeRate then
        selected = i - 1
      end
    end
    table.insert(children, ui.select({ key = "rate", options = names, selectedIndex = selected, controlSize = "sm", width = 84, onChange = "onRate" }))
  end
  return ui.row({ key = "volume-row", gap = 8, align = "center" }, children)
end

-- Two columns: art and the controls on the left, the item, lyrics and queue on the right. The body has a
-- fixed height (art + controls) so the queue scrolls inside the right column.
local function playerScreen()
  local item = S.track()
  local player = S.get(S.PLAYER)
  if not item or type(player) ~= "table" then
    local buttons = (can("library:read") or can("search")) and { button(tr("np.library"), "books", "onOpenLibrary", "primary") } or nil
    return statusScreen("music", tr("np.nothingPlaying"), tr("np.nothingPlaying.body"), buttons, "on_surface_variant")
  end

  local artSize = cfg("np_layout", "compact") == "large_art" and 340 or 260
  local currentArt = S.get(S.ART)
  local artPath = type(currentArt) == "table" and currentArt.trackId == item.id and currentArt.path or nil
  local glyph = item.type == "episode" and "microphone" or "music"

  local left = { parts.art(artPath, artSize, { radius = 16, glyph = glyph }), seekRow(player, item) }
  if can("player:control") then
    table.insert(left, transportRow(player, item))
    table.insert(left, volumeRow(player, item))
  end

  local right = { infoBlock(item) }
  if cfg("np_show_lyrics", true) and can("lyrics:read") then
    local lyrics = lyricsSection()
    if lyrics then
      table.insert(right, lyrics)
    end
  end
  if cfg("np_show_queue", true) and can("queue:read") then
    local queue = queueSection(cfg("np_queue_preview", 6))
    if queue then
      table.insert(right, queue)
    end
  end

  -- Keys and an explicit (transparent) fill: nodes are matched by position, so without them the body
  -- inherits the ⋮ strip's fill once the strip closes.
  return ui.row({ key = "body", fill = "surface_container/0", gap = 24, align = "stretch", height = artSize + 148 }, {
    ui.column({ key = "left", gap = 8, width = artSize }, left),
    ui.column({ key = "right", gap = 16, flexGrow = 1 }, right),
  })
end

-- Connection screens stay a readable width inside the wide panel.
local function centered(node)
  return ui.row({ key = "connect", justify = "center", paddingV = 24 }, { ui.column({ width = 440, gap = 12, align = "center" }, { node, credit() }) })
end

local frameTicks = false
local lastWordKey = nil

local function wordKey()
  local lyrics = S.get(S.LYRICS)
  local player = S.get(S.PLAYER)
  if not (isOpen and cfg("np_show_lyrics", true) and type(lyrics) == "table" and lyrics.words)
    or type(player) ~= "table" or player.status ~= "playing" then
    return nil
  end
  return `{lyrics.lineIndex}:{sungWords(lyrics.words)}`
end

local function syncFrameTicks()
  local want = wordKey() ~= nil
  if want ~= frameTicks then
    frameTicks = want
    panel.setNeedsFrameTick(want)
  end
end

function onFrameTick(_deltaMs)
  local key = wordKey()
  if key ~= lastWordKey then
    lastWordKey = key
    render()
  end
  syncFrameTicks()
end

render = function()
  if not isOpen then
    return
  end
  lastWordKey = wordKey()
  syncFrameTicks()
  local conn = S.get(S.CONN) or { state = "starting" }
  local connected = conn.state == S.CONNECTED
  local children = { header(connected) }
  if connected and menuOpen then
    table.insert(children, menu())
  end
  if connected then
    table.insert(children, playerScreen())
  else
    table.insert(children, centered(connectionScreen(conn)))
  end
  panel.render(ui.column({ gap = 16, padding = 20, fill = "surface_container" }, children))
end

---- Lifecycle

function onOpen(_context)
  isOpen = true
  lastError = nil
  menuOpen = false
  openRow = nil
  panel.setWantsSecondTicks(true)
  if S.isConnected() then
    loadPlaylists()
  end
  render()
end

function onClose()
  isOpen = false
  frameTicks = false
  showAllQueue = false
  fullQueue = nil
  seekDraft = nil
  volumeDraft = nil
  art.clearQueue()
end

-- Second ticks: the position, the denial countdown and the flash message move on.
function update()
  render()
end

local function onStateChange()
  render()
end

for _, key in ipairs({ S.SCOPES, S.SIGNED_IN, S.PLAYER, S.ART, S.LYRICS }) do
  noctalia.state.watch(key, onStateChange)
end

noctalia.state.watch(S.TRACK, function(t)
  local item = type(t) == "table" and t.item or nil
  -- Drop the optimistic rating once Sonolith reports one for this item.
  if item and ratingOverride[item.id] ~= nil and item.rating == ratingOverride[item.id] then
    ratingOverride[item.id] = nil
  end
  seekDraft = nil
  render()
end)

noctalia.state.watch(S.QUEUE, function(q)
  if showAllQueue and isOpen and q and q.revision ~= fullQueueRev then
    fetchFullQueue()
  end
  render()
end)

noctalia.state.watch(S.CONN, function(conn)
  if isOpen and type(conn) == "table" and conn.state == S.CONNECTED then
    loadPlaylists()
  end
  render()
end)

