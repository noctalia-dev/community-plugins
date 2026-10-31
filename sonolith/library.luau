--!nonstrict
-- Library panel: a rail (back to Now Playing, search, library tabs) and a content area with a navigation
-- stack (tab -> playlist/album/artist/podcast detail, search results). Every view's data is cached for as
-- long as the panel's runtime lives; reopening shows the cache at once and refreshes it in the background.
--
-- panel.openContextMenu only works from a right click: a row's ⋮ opens inline actions on a left click and
-- the native menu on a right click; a card's ▶ plays on a left click and opens the menu on a right click.

local S = require("./lib/state.luau")
local commands = require("./lib/commands.luau")
local format = require("./lib/format.luau")
local art = require("./lib/art.luau")
local parts = require("./lib/ui_parts.luau")

commands.init("library")

local NOW_PLAYING = "opecko/sonolith:nowplaying"
local LAST_TAB = "lib.lastTab"
local PAGE = 50
local SEARCH_PAGE = 30
local GRID_COLS = 4
local CARD = 116
local REFRESH_MS = 2 * 60 * 1000
local SUGGEST_DEBOUNCE_MS = 250
local SUGGEST_GAP_MS = 500 -- search.suggestions is in the 2/s network class
local PLAYLISTS_TTL_MS = 10 * 60 * 1000
local FLASH_MS = 3000

local TABS = {
  { id = "playlists", glyph = "playlist", method = "library.playlists", layout = "grid" },
  { id = "liked", glyph = "heart", method = "library.likedSongs", layout = "list", context = { type = "playlist", id = "LM" } },
  { id = "albums", glyph = "disc", method = "library.albums", layout = "grid" },
  { id = "artists", glyph = "user", method = "library.artists", layout = "grid" },
  { id = "podcasts", glyph = "microphone", method = "library.podcasts", layout = "grid" },
  { id = "later", glyph = "clock", method = "library.episodesForLater", layout = "list" },
  { id = "history", glyph = "history", method = "library.history", layout = "list" },
}
local TAB_BY_ID = {}
for _, t in ipairs(TABS) do
  TAB_BY_ID[t.id] = t
end

local FILTERS = { "all", "songs", "albums", "artists", "playlists", "podcasts" }
local GRID_FILTERS = { albums = true, artists = true, playlists = true, podcasts = true }
local COLLECTIONS = { album = true, playlist = true, podcast = true }
local PLAYABLE = { track = true, episode = true, album = true, playlist = true, podcast = true }

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function now()
  return noctalia.nowMs()
end

local function can(scope)
  return S.hasScope(scope)
end

---- Panel state

local isOpen = false
local dirty = false
local stack = {} -- views, top last: { kind = "tab" | "search" | "suggest" | "detail" | "home", ... }
local data = {} -- viewKey -> { items, nextCursor, loading, error, at, header, topResult, sections }
local query = ""
local searchKey = 0 -- a fresh key clears the input
local suggestAt = nil
local lastSuggestAt = 0
local suggestions = nil -- { query, queries, items }
local openRow = nil -- row key with inline actions shown
local thumbs = {} -- id -> path | false (downloading)
local fulls = {} -- id -> path for detail headers
local editablePlaylists = nil
local playlistsAt = 0
local playlistsLoading = false
local flash = nil
local scopeRequestBusy = false

local function render() end -- defined below

-- Panels get update() only on second ticks, so changes are drawn on the next frame tick instead: one
-- render per frame however many thumbnails land, and no ticks while nothing changes.
local frameTicks = false

local function wantFrames(on)
  if on ~= frameTicks then
    frameTicks = on
    panel.setNeedsFrameTick(on)
  end
end

local function markDirty()
  dirty = true
  if isOpen then
    wantFrames(true)
  end
end

local function showFlash(text)
  flash = { text = text, untilMs = now() + FLASH_MS }
  markDirty()
end

local function send(method, params, cb)
  commands.send(method, params, cb)
end

local function viewKey(v)
  if v.kind == "tab" then
    return "tab:" .. v.tab
  elseif v.kind == "search" then
    return `search:{v.filter}:{v.query}`
  elseif v.kind == "detail" then
    return `detail:{v.ref.type}:{v.ref.id}`
  end
  return v.kind
end

local function top()
  return stack[#stack]
end

-- Rows hold an Item, a PlaylistEntry ({ entryId, item }) or a HistoryEntry ({ item, sectionText }).
local function itemOf(row)
  return row.item or row
end

---- Thumbnails

local function thumb(item)
  local id = item and item.id
  if not id then
    return nil
  end
  local cached = thumbs[id]
  if cached then
    return cached
  end
  local _, t = art.cached(id)
  if t then
    thumbs[id] = t
    return t
  end
  if cached == nil and item.thumbnailUrl then
    thumbs[id] = false
    art.fetch(id, item.thumbnailUrl, function(full, small)
      thumbs[id] = small or false
      if full then
        fulls[id] = full
      end
      if small and isOpen then
        markDirty()
      end
    end)
  end
  return nil
end

local function fullArt(item)
  local id = item and item.id
  if not id then
    return nil
  end
  if fulls[id] then
    return fulls[id]
  end
  local f = art.cached(id)
  if f then
    fulls[id] = f
    return f
  end
  thumb(item) -- downloads both sizes
  return nil
end

---- Loading

local function request(view, cursor)
  if view.kind == "tab" then
    return TAB_BY_ID[view.tab].method, { cursor = cursor, limit = PAGE }
  elseif view.kind == "search" then
    return "search.query", { query = view.query, type = view.filter, cursor = cursor, limit = SEARCH_PAGE }
  elseif view.kind == "detail" then
    local ref = view.ref
    if ref.type == "playlist" then
      return "playlist.get", { id = ref.id, cursor = cursor, limit = PAGE }
    elseif ref.type == "album" then
      return "browse.album", { id = ref.id }
    elseif ref.type == "artist" then
      return "browse.artist", { id = ref.id }
    elseif ref.type == "podcast" then
      return "browse.podcast", { id = ref.id, cursor = cursor, limit = PAGE }
    end
  end
  return nil
end

-- items, nextCursor, extras
local function shape(view, result)
  if view.kind == "detail" then
    local t = view.ref.type
    if t == "playlist" then
      return result.items or {}, result.nextCursor, { header = result.playlist }
    elseif t == "album" then
      return result.tracks or {}, nil, { header = result }
    elseif t == "artist" then
      return {}, nil, { header = result, sections = result.sections or {} }
    elseif t == "podcast" then
      return result.items or {}, result.nextCursor, { header = result.podcast }
    end
  elseif view.kind == "search" then
    return result.items or {}, result.nextCursor, { topResult = result.topResult }
  end
  return result.items or {}, result.nextCursor, {}
end

local function load(view, more)
  local method, params = request(view, nil)
  if not method then
    return
  end
  local key = viewKey(view)
  local d = data[key]
  if not d then
    d = { items = {} }
    data[key] = d
  end
  if d.loading then
    return
  end
  if more then
    params.cursor = d.nextCursor
    if not params.cursor then
      return
    end
  end
  d.loading = true
  d.error = nil
  markDirty()
  send(method, params, function(ok, result, err)
    d.loading = false
    if not ok then
      if err and err.name == "InvalidParams" and err.reason == "cursorExpired" then
        d.items, d.nextCursor = {}, nil
        load(view, false)
        return
      end
      d.error = err or { name = "?" }
      markDirty()
      return
    end
    local items, nextCursor, extras = shape(view, result or {})
    if more then
      for _, it in ipairs(items) do
        table.insert(d.items, it)
      end
    else
      d.items = items
    end
    d.nextCursor = nextCursor
    d.at = now()
    for k, v in pairs(extras) do
      d[k] = v
    end
    markDirty()
  end)
end

local function ensureLoaded(view)
  local d = data[viewKey(view)]
  if not d or (not d.loading and (not d.at or now() - d.at > REFRESH_MS)) then
    load(view, false)
  end
end

local function loadEditablePlaylists()
  if playlistsLoading or not (can("library:read") and can("library:write")) or S.get(S.SIGNED_IN) == false then
    return
  end
  if editablePlaylists and now() - playlistsAt < PLAYLISTS_TTL_MS then
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
        editablePlaylists, playlistsAt, playlistsLoading = found, now(), false
      end
    end)
  end
  page(nil, 1)
end

---- Navigation

local function defaultView()
  if not can("library:read") or S.get(S.SIGNED_IN) == false then
    return { kind = "home" }
  end
  local tab = noctalia.getConfig("library_default_tab") or "last"
  if tab == "last" then
    tab = noctalia.state.get(LAST_TAB) or "playlists"
  end
  return { kind = "tab", tab = TAB_BY_ID[tab] and tab or "playlists" }
end

local function push(view)
  openRow = nil
  table.insert(stack, view)
  ensureLoaded(view)
  markDirty()
end

local function selectTab(id)
  openRow = nil
  stack = { { kind = "tab", tab = id } }
  noctalia.state.set(LAST_TAB, id)
  ensureLoaded(stack[1])
  markDirty()
end

function onBack()
  if #stack > 1 then
    table.remove(stack)
    openRow = nil
    markDirty()
  end
end

local function openItem(item)
  if item.type == "track" or item.type == "episode" then
    return false
  end
  push({ kind = "detail", ref = { type = item.type, id = item.id }, title = format.name(item) })
  return true
end

function onNowPlaying()
  noctalia.togglePanel(NOW_PLAYING)
end

function onToggle()
  send("player.toggle")
end

---- Playback and library actions

local function ref(item)
  return { type = item.type, id = item.id }
end

local function failed(err, fallback)
  if err and err.name == "NotSignedIn" then
    showFlash(tr("lib.signed_out"))
  elseif err and err.name ~= "Timeout" then
    showFlash(fallback)
  end
end

local function playItem(item, context, shuffle)
  if not can("player:control") then
    return
  end
  local params
  if context then
    params = { item = context, startId = item and item.id or nil, shuffle = shuffle or nil }
  else
    params = { item = ref(item), shuffle = shuffle or nil }
  end
  send("player.playItem", params, function(ok, _, err)
    if not ok then
      failed(err, tr("lib.play_failed"))
    end
  end)
end

local function enqueue(item, nextUp)
  send(nextUp and "queue.playNext" or "queue.add", { items = { ref(item) } }, function(ok, _, err)
    if ok then
      showFlash(nextUp and tr("lib.playing_next", { name = format.name(item) }) or tr("lib.added_to_queue", { name = format.name(item) }))
    else
      failed(err, tr("lib.queue_failed"))
    end
  end)
end

local function setRating(item)
  local target = item.rating == "like" and "none" or "like"
  send("rating.set", { item = ref(item), rating = target }, function(ok, _, err)
    if ok then
      item.rating = target
      showFlash(target == "like" and tr("lib.liked") or tr("lib.unliked"))
    else
      failed(err, tr("lib.rate_failed"))
    end
  end)
end

local function saveTo(item, playlist)
  send("playlist.addTracks", { id = playlist.id, items = { ref(item) } }, function(ok, result, err)
    if ok and result and (result.added or 0) == 0 then
      showFlash(tr("np.saved.already", { playlist = playlist.title }))
    elseif ok then
      showFlash(tr("np.saved.done", { playlist = playlist.title }))
    else
      failed(err, tr("np.saved.failed"))
    end
  end)
end

local function removeFromPlaylist(playlistId, entryId)
  send("playlist.removeTracks", { id = playlistId, entryIds = { entryId } }, function(ok, _, err)
    if not ok then
      failed(err, tr("lib.remove_failed"))
      return
    end
    local d = data["detail:playlist:" .. playlistId]
    if d then
      for i, row in ipairs(d.items) do
        if row.entryId == entryId then
          table.remove(d.items, i)
          break
        end
      end
    end
    markDirty()
  end)
end

local function goAlbum(item)
  if item.album and item.album.id then
    push({ kind = "detail", ref = { type = "album", id = item.album.id }, title = item.album.title })
  end
end

local function goArtist(item)
  local a = item.artists and item.artists[1]
  if a and a.id then
    push({ kind = "detail", ref = { type = "artist", id = a.id }, title = a.name })
  end
end

local function goPodcast(item)
  if item.podcast and item.podcast.id then
    push({ kind = "detail", ref = { type = "podcast", id = item.podcast.id }, title = item.podcast.title })
  end
end

---- Context menus: targets live here, the menu carries only a key

local menuTargets = {}
local menuSeq = 0

-- target: { item, context?, playlistId?, entryId? }
local function actionsFor(target)
  local item = target.item
  local list = {}
  local function add(id, label)
    table.insert(list, { id = id, label = label })
  end
  local signedIn = S.get(S.SIGNED_IN) ~= false
  if PLAYABLE[item.type] and can("player:control") then
    add("play", tr("lib.play"))
    if COLLECTIONS[item.type] then
      add("shuffle", tr("lib.shuffle"))
    end
  end
  if PLAYABLE[item.type] and can("queue:write") then
    add("next", tr("np.queue.play_next"))
    add("queue", tr("lib.add_to_queue"))
  end
  if PLAYABLE[item.type] and can("library:write") and signedIn and item.type ~= "podcast" then
    add("rate", item.rating == "like" and tr("lib.unlike") or tr("lib.like"))
  end
  if item.type == "track" and item.album and item.album.id then
    add("album", tr("lib.go_album"))
  end
  if (item.type == "track" or item.type == "album") and item.artists and item.artists[1] and item.artists[1].id then
    add("artist", tr("lib.go_artist"))
  end
  if item.type == "episode" and item.podcast and item.podcast.id then
    add("podcast", tr("lib.go_podcast"))
  end
  if not COLLECTIONS[item.type] and item.type ~= "artist" then
    if target.playlistId and target.entryId and can("library:write") then
      add("remove", tr("lib.remove_from_playlist"))
    end
  end
  return list
end

local function runAction(target, action)
  local item = target.item
  openRow = nil
  if action == "play" then
    playItem(item, target.context)
  elseif action == "shuffle" then
    playItem(item, nil, true)
  elseif action == "next" then
    enqueue(item, true)
  elseif action == "queue" then
    enqueue(item, false)
  elseif action == "rate" then
    setRating(item)
  elseif action == "album" then
    goAlbum(item)
  elseif action == "artist" then
    goArtist(item)
  elseif action == "podcast" then
    goPodcast(item)
  elseif action == "remove" then
    removeFromPlaylist(target.playlistId, target.entryId)
  elseif string.sub(action, 1, 5) == "save:" then
    local id = string.sub(action, 6)
    for _, p in ipairs(editablePlaylists or {}) do
      if p.id == id then
        saveTo(item, p)
      end
    end
  end
  markDirty()
end

function onLibMenu(actionId, key)
  local target = menuTargets[key]
  if target then
    runAction(target, actionId)
  end
end

local function openMenu(target)
  local items = {}
  for _, a in ipairs(actionsFor(target)) do
    table.insert(items, a)
  end
  local item = target.item
  if (item.type == "track" or item.type == "episode") and can("library:write") and editablePlaylists and #editablePlaylists > 0 then
    table.insert(items, { kind = "separator" })
    table.insert(items, { kind = "header", label = tr("lib.save_to_playlist") })
    for i, p in ipairs(editablePlaylists) do
      if i > 40 then
        break
      end
      table.insert(items, { id = "save:" .. p.id, label = p.title })
    end
  end
  if #items == 0 then
    return
  end
  menuSeq += 1
  local key = "m" .. menuSeq
  menuTargets = { [key] = target } -- only the latest menu is live
  panel.openContextMenu({ items = items, onActivate = "onLibMenu", context = key, maxVisible = 16 })
end

---- Pieces

local function emptyState(glyph, text, buttons)
  local children = {
    ui.glyph({ name = glyph, size = 32, color = "on_surface_variant/0.7" }),
    ui.label({ text = text, color = "on_surface_variant", textAlign = "center", maxLines = 3 }),
  }
  if buttons then
    table.insert(children, ui.row({ gap = 8, justify = "center" }, buttons))
  end
  return ui.column({ key = "empty", gap = 12, paddingV = 48, align = "center" }, children)
end

local function errorState(d, view)
  local err = d.error or {}
  local text = err.name == "NotSignedIn" and tr("lib.signed_out")
    or err.name == "PermissionDenied" and tr("lib.no_permission")
    or err.name == "NotFound" and tr("lib.not_found")
    or tr("lib.load_failed")
  return emptyState("alert-triangle", text, {
    ui.button({ text = tr("np.try_again"), glyph = "refresh", variant = "outline", onClick = function()
      load(view, false)
    end }),
  })
end

local function loadMore(view, d)
  if not d.nextCursor then
    return nil
  end
  return ui.row({ key = "more", justify = "center", paddingV = 8 }, {
    ui.button({
      text = d.loading and tr("lib.loading") or tr("lib.load_more"),
      variant = "outline",
      enabled = not d.loading,
      onClick = function()
        load(view, true)
      end,
    }),
  })
end

-- A list row with its inline actions; `context` makes a click play inside the playlist/album/podcast.
local function listRow(row, index, opts)
  local item = itemOf(row)
  local rowKey = `{opts.prefix or "r"}{index}-{item.id or ""}`
  local target = { item = item, context = opts.context, playlistId = opts.playlistId, entryId = row.entryId }
  local playable = item.type == "track" or item.type == "episode"
  local onClick
  if playable then
    onClick = can("player:control") and function()
      playItem(item, opts.context)
    end or nil
  else
    onClick = function()
      openItem(item)
    end
  end
  local out = {
    parts.mediaRow(item, {
      key = rowKey,
      artPath = thumb(item),
      selected = openRow == rowKey,
      onClick = onClick,
      onMenu = function()
        openRow = openRow ~= rowKey and rowKey or nil
        markDirty()
      end,
      onMenuRight = function()
        openMenu(target)
      end,
    }),
  }
  if openRow == rowKey then
    local buttons = {}
    for _, a in ipairs(actionsFor(target)) do
      if a.id ~= "play" then
        table.insert(buttons, ui.button({ text = a.label, variant = "ghost", controlSize = "sm", onClick = function()
          runAction(target, a.id)
        end }))
      end
    end
    if #buttons > 0 then
      table.insert(out, ui.row({ key = rowKey .. "-a", gap = 4, paddingH = 8, justify = "end" }, buttons))
    end
  end
  return out
end

local function listBody(view, d, opts)
  opts = opts or {}
  local rows = {}
  local lastSection = nil
  for i, row in ipairs(d.items) do
    if row.sectionText and row.sectionText ~= lastSection then
      lastSection = row.sectionText
      table.insert(rows, ui.label({ key = "sec" .. i, text = row.sectionText, fontSize = 12, fontWeight = "semibold", color = "on_surface_variant" }))
    end
    for _, node in ipairs(listRow(row, i, opts)) do
      table.insert(rows, node)
    end
  end
  local more = loadMore(view, d)
  if more then
    table.insert(rows, more)
  end
  return rows
end

local function card(item, index, prefix)
  local target = { item = item }
  local playable = PLAYABLE[item.type] and can("player:control")
  return parts.card(item, {
    key = `{prefix or "c"}{index}-{item.id}`,
    artPath = thumb(item),
    size = CARD,
    round = item.type == "artist",
    playTooltip = tr("lib.play_hint"),
    onClick = function()
      openItem(item)
    end,
    onPlay = playable and function()
      playItem(item)
    end or nil,
    onMenuRight = function()
      openMenu(target)
    end,
  })
end

local function gridRows(items, prefix, limit)
  local rows, cells = {}, {}
  for i, item in ipairs(items) do
    if limit and i > limit then
      break
    end
    table.insert(cells, card(item, i, prefix))
    if #cells == GRID_COLS then
      table.insert(rows, ui.row({ key = `{prefix or "g"}row{i}`, gap = 12 }, cells))
      cells = {}
    end
  end
  if #cells > 0 then
    table.insert(rows, ui.row({ key = `{prefix or "g"}row-last`, gap = 12 }, cells))
  end
  return rows
end

local function gridBody(view, d)
  local rows = gridRows(d.items)
  local more = loadMore(view, d)
  if more then
    table.insert(rows, more)
  end
  return rows
end

---- Views

local function tabBody(view)
  local tab = TAB_BY_ID[view.tab]
  local d = data[viewKey(view)]
  if not d or (#d.items == 0 and d.loading) then
    return tab.layout == "grid" and parts.skeletonGrid(GRID_COLS, 2, CARD) or parts.skeletonRows(7)
  end
  if d.error and #d.items == 0 then
    return { errorState(d, view) }
  end
  if #d.items == 0 then
    return { emptyState(tab.glyph, tr("lib.empty." .. tab.id)) }
  end
  if tab.layout == "grid" then
    return gridBody(view, d)
  end
  return listBody(view, d, { context = tab.context })
end

local function detailHeader(view, d)
  local h = d.header or {}
  local t = view.ref.type
  local meta = {}
  if t == "playlist" then
    meta = { h.author, h.trackCount and noctalia.trp("lib.songs", h.trackCount), h.privacy and tr("lib.privacy." .. h.privacy) }
  elseif t == "album" then
    meta = { format.artists(h), h.year and tostring(h.year), h.trackCount and noctalia.trp("lib.songs", h.trackCount), h.durationMs and format.duration(h.durationMs) }
  elseif t == "artist" then
    meta = { h.subscribersText }
  elseif t == "podcast" then
    meta = { h.author }
  end
  local metaText = {}
  for i = 1, 4 do
    if meta[i] and meta[i] ~= "" then
      table.insert(metaText, meta[i])
    end
  end

  local info = {
    ui.label({ text = format.name(h) ~= "" and format.name(h) or (view.title or ""), fontSize = 20, fontWeight = "semibold", color = "on_surface", maxLines = 2 }),
    ui.label({ text = table.concat(metaText, " · "), fontSize = 13, color = "on_surface_variant", maxLines = 1 }),
  }
  if h.description and h.description ~= "" then
    table.insert(info, ui.label({ text = h.description, fontSize = 12, color = "on_surface_variant", maxLines = 3 }))
  end
  local buttons = {}
  if COLLECTIONS[t] and can("player:control") then
    table.insert(buttons, ui.button({ text = tr("lib.play"), glyph = "player-play-filled", variant = "primary", controlSize = "sm", onClick = function()
      playItem(view.ref, nil)
    end }))
    if t ~= "podcast" then
      table.insert(buttons, ui.button({ text = tr("lib.shuffle"), glyph = "arrows-shuffle", variant = "outline", controlSize = "sm", onClick = function()
        playItem(view.ref, nil, true)
      end }))
    end
  end
  if COLLECTIONS[t] and can("queue:write") then
    table.insert(buttons, ui.button({ text = tr("lib.add_to_queue"), glyph = "playlist-add", variant = "ghost", controlSize = "sm", onClick = function()
      enqueue({ type = t, id = view.ref.id, title = format.name(h) }, false)
    end }))
  end
  if #buttons > 0 then
    table.insert(info, ui.spacer({ height = 4 }))
    table.insert(info, ui.row({ gap = 8, align = "center" }, buttons))
  end
  local headerItem = { id = view.ref.id, type = t, thumbnailUrl = h.thumbnailUrl }
  return ui.row({ key = "dh", gap = 16, align = "center" }, {
    parts.art(fullArt(headerItem), 160, { radius = t == "artist" and 80 or 12, glyph = t == "artist" and "user" or "disc" }),
    ui.column({ gap = 6, flexGrow = 1 }, info),
  })
end

local function detailBody(view)
  local d = data[viewKey(view)]
  if not d or (not d.header and d.loading) then
    local out = { ui.row({ key = "dh-sk", gap = 16, align = "center" }, {
      ui.box({ width = 160, height = 160, radius = 12, fill = "surface_container_high" }),
      ui.column({ gap = 8 }, {
        ui.box({ width = 220, height = 18, radius = 4, fill = "surface_container_high" }),
        ui.box({ width = 140, height = 12, radius = 4, fill = "surface_container_high" }),
      }),
    }) }
    for _, r in ipairs(parts.skeletonRows(5)) do
      table.insert(out, r)
    end
    return out
  end
  if d.error and not d.header then
    return { errorState(d, view) }
  end
  local out = { detailHeader(view, d) }
  local t = view.ref.type
  if t == "artist" then
    for si, section in ipairs(d.sections or {}) do
      if section.items and #section.items > 0 then
        table.insert(out, ui.label({ key = "as" .. si, text = section.title, fontWeight = "semibold", color = "on_surface" }))
        if section.kind == "songs" or section.kind == "videos" or section.kind == "episodes" then
          for i, item in ipairs(section.items) do
            if i > 5 then
              break
            end
            for _, node in ipairs(listRow(item, i, { prefix = `s{si}-` })) do
              table.insert(out, node)
            end
          end
        else
          for _, r in ipairs(gridRows(section.items, `s{si}-`, GRID_COLS)) do
            table.insert(out, r)
          end
        end
      end
    end
    return out
  end
  if #d.items == 0 and not d.loading then
    table.insert(out, emptyState("music", tr("lib.empty.detail")))
    return out
  end
  local editable = t == "playlist" and d.header and d.header.editable
  for _, node in ipairs(listBody(view, d, {
    context = view.ref,
    playlistId = editable and view.ref.id or nil,
  })) do
    table.insert(out, node)
  end
  return out
end

local function filterChips(view)
  local chips = {}
  for _, f in ipairs(FILTERS) do
    table.insert(chips, ui.button({
      text = tr("lib.filter." .. f),
      variant = f == view.filter and "secondary" or "ghost",
      selected = f == view.filter,
      controlSize = "sm",
      onClick = function()
        if f ~= view.filter then
          stack[#stack] = { kind = "search", query = view.query, filter = f }
          ensureLoaded(stack[#stack])
          markDirty()
        end
      end,
    }))
  end
  return ui.row({ key = "chips", gap = 4 }, chips)
end

local function topResultCard(item)
  local buttons = {}
  if PLAYABLE[item.type] and can("player:control") then
    table.insert(buttons, ui.button({ text = tr("lib.play"), glyph = "player-play-filled", variant = "primary", controlSize = "sm", onClick = function()
      playItem(item)
    end }))
  end
  return ui.row({
    key = "top",
    gap = 16,
    padding = 12,
    radius = 12,
    align = "center",
    fill = "surface_container_high",
    onClick = function()
      if not openItem(item) and can("player:control") then
        playItem(item)
      end
    end,
  }, {
    parts.art(thumb(item), 88, { radius = item.type == "artist" and 44 or 10 }),
    ui.column({ gap = 4, flexGrow = 1 }, {
      ui.label({ text = format.name(item), fontSize = 18, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = format.subtitle(item), color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.row({ gap = 8 }, buttons),
  })
end

local function searchBody(view)
  local out = { filterChips(view) }
  local d = data[viewKey(view)]
  if not d or (#d.items == 0 and not d.topResult and d.loading) then
    for _, r in ipairs(GRID_FILTERS[view.filter] and parts.skeletonGrid(GRID_COLS, 2, CARD) or parts.skeletonRows(6)) do
      table.insert(out, r)
    end
    return out
  end
  if d.error and #d.items == 0 then
    table.insert(out, errorState(d, view))
    return out
  end
  if #d.items == 0 and not d.topResult then
    table.insert(out, emptyState("search", tr("lib.no_results", { query = view.query })))
    return out
  end
  if d.topResult then
    table.insert(out, topResultCard(d.topResult))
  end
  local body = GRID_FILTERS[view.filter] and gridBody(view, d) or listBody(view, d, { prefix = "sr" })
  for _, node in ipairs(body) do
    table.insert(out, node)
  end
  return out
end

local function suggestBody()
  local out = {}
  if not suggestions or suggestions.query ~= query then
    return parts.skeletonRows(4)
  end
  for i, q in ipairs(suggestions.queries or {}) do
    table.insert(out, ui.button({
      key = "sq" .. i,
      text = q,
      glyph = "search",
      variant = "ghost",
      contentAlign = "start",
      onClick = function()
        submitSearch(q)
      end,
    }))
  end
  for i, item in ipairs(suggestions.items or {}) do
    for _, node in ipairs(listRow(item, i, { prefix = "si" })) do
      table.insert(out, node)
    end
  end
  if #out == 0 then
    table.insert(out, emptyState("search", tr("lib.search_hint")))
  end
  return out
end

local function homeBody()
  if not can("library:read") then
    local req = S.get(S.SCOPE_REQUEST)
    local wait = type(req) == "table" and req.retryAt and math.max(0, req.retryAt - now()) or 0
    local text = tr("lib.no_library.body")
    if type(req) == "table" and req.status == "denied" and wait > 0 then
      text = tr("lib.no_library.denied", { time = format.wait(wait) })
    end
    return { emptyState("books", text, {
      ui.button({
        text = tr("lib.allow_library"),
        glyph = "lock-open",
        variant = "primary",
        enabled = not scopeRequestBusy and wait <= 0,
        onClick = "onAllowLibrary",
      }),
    }) }
  end
  if S.get(S.SIGNED_IN) == false then
    return { emptyState("user", tr("lib.signed_out")) }
  end
  return { emptyState("search", tr("lib.search_hint")) }
end

function onAllowLibrary()
  scopeRequestBusy = true
  markDirty()
  send("bridge.requestScopes", { scopes = { "library:read" } }, function(ok, result, err)
    scopeRequestBusy = false
    if not ok then
      failed(err, tr("lib.request_failed"))
    elseif result and result.status == "pending" then
      showFlash(tr("lib.approve_in_sonolith"))
    end
    markDirty()
  end)
end

---- Search input

function submitSearch(text)
  text = noctalia.string.trim(text or "")
  if text == "" or not can("search") then
    return
  end
  query = text
  suggestAt = nil
  local view = { kind = "search", query = text, filter = "all" }
  -- Replace a suggestion or search view instead of stacking them.
  local t = top()
  if t and (t.kind == "suggest" or t.kind == "search") then
    table.remove(stack)
  end
  push(view)
end

function onSearchChange(text)
  query = text or ""
  local t = top()
  if noctalia.string.trim(query) == "" then
    suggestAt = nil
    if t and t.kind == "suggest" then
      table.remove(stack)
      if #stack == 0 then
        stack = { defaultView() }
      end
    end
  else
    if not t or t.kind ~= "suggest" then
      table.insert(stack, { kind = "suggest" })
    end
    suggestAt = now() + SUGGEST_DEBOUNCE_MS
  end
  markDirty()
end

function onSearchSubmit(text)
  submitSearch(text)
end

local function fetchSuggestions()
  local q = noctalia.string.trim(query)
  if q == "" then
    return
  end
  lastSuggestAt = now()
  send("search.suggestions", { query = q }, function(ok, result)
    if ok and noctalia.string.trim(query) == q then
      suggestions = { query = query, queries = result.queries or {}, items = result.items or {} }
      markDirty()
    end
  end)
end

---- Rail

local function nowPlayingCard()
  local item = S.track()
  local player = S.get(S.PLAYER)
  local playing = type(player) == "table" and player.status == "playing"
  local a = S.get(S.ART)
  local path = type(a) == "table" and item and a.trackId == item.id and (a.thumb or a.path) or nil
  local children = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "arrow-left", size = 14, color = "primary" }),
      ui.label({ text = tr("np.title"), fontSize = 12, fontWeight = "semibold", color = "primary" }),
    }),
  }
  if item then
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      parts.art(path, 36, { radius = 6 }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = item.title or "", fontSize = 12, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
        ui.label({ text = format.artists(item), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      }),
      ui.button({
        glyph = playing and "player-pause-filled" or "player-play-filled",
        variant = "ghost",
        controlSize = "sm",
        visible = can("player:control"),
        onClick = "onToggle",
      }),
    }))
  end
  return ui.column({ key = "np", gap = 8, padding = 8, radius = 10, fill = "surface_container", onClick = "onNowPlaying" }, children)
end

local function rail()
  local children = { nowPlayingCard() }
  if can("search") then
    table.insert(children, ui.input({
      key = "search-" .. searchKey,
      value = query,
      placeholder = tr("lib.search_placeholder"),
      controlSize = "sm",
      submitOnEnter = true,
      onChange = "onSearchChange",
      onSubmit = "onSearchSubmit",
    }))
  end
  if can("library:read") then
    local signedIn = S.get(S.SIGNED_IN) ~= false
    local current = top()
    local currentTab = stack[1] and stack[1].kind == "tab" and stack[1].tab or nil
    local tabs = {}
    for _, t in ipairs(TABS) do
      local selected = currentTab == t.id and current ~= nil and current.kind ~= "suggest"
      table.insert(tabs, ui.button({
        key = "tab-" .. t.id,
        text = tr("lib.tab." .. t.id),
        glyph = t.glyph,
        variant = selected and "secondary" or "ghost",
        selected = selected,
        contentAlign = "start",
        controlSize = "sm",
        enabled = signedIn,
        onClick = function()
          selectTab(t.id)
        end,
      }))
    end
    table.insert(children, ui.column({ key = "tabs", gap = 2 }, tabs))
    if not signedIn then
      table.insert(children, ui.label({ text = tr("lib.signed_out"), fontSize = 11, color = "on_surface_variant", maxLines = 3 }))
    end
  end
  return ui.column({ key = "rail", width = 180, gap = 12, padding = 8, radius = 12, fill = "surface_container_high" }, children)
end

---- Content

local function contentHeader(view)
  local title, count = "", nil
  if view.kind == "tab" then
    title = tr("lib.tab." .. view.tab)
    local d = data[viewKey(view)]
    if d and #d.items > 0 then
      count = d.nextCursor and tr("lib.count_more", { count = #d.items }) or tostring(#d.items)
    end
  elseif view.kind == "search" then
    title = tr("lib.results_for", { query = view.query })
  elseif view.kind == "suggest" then
    title = tr("lib.suggestions")
  elseif view.kind == "detail" then
    title = view.title or ""
  elseif view.kind == "home" then
    title = tr("np.library")
  end
  local children = {}
  if #stack > 1 then
    local prev = stack[#stack - 1]
    local prevTitle = prev.kind == "tab" and tr("lib.tab." .. prev.tab)
      or prev.kind == "search" and tr("lib.search")
      or prev.title or tr("lib.back")
    table.insert(children, ui.button({ text = prevTitle, glyph = "arrow-left", variant = "ghost", controlSize = "sm", onClick = "onBack" }))
  end
  table.insert(children, ui.label({ text = title, fontSize = 16, fontWeight = "semibold", color = "on_surface", maxLines = 1, flexGrow = 1 }))
  if flash and now() < flash.untilMs then
    table.insert(children, ui.label({ text = flash.text, fontSize = 12, color = "primary", maxLines = 1 }))
  elseif count then
    table.insert(children, ui.label({ text = count, fontSize = 12, color = "on_surface_variant" }))
  end
  return ui.row({ key = "ch", gap = 8, align = "center", height = 32 }, children)
end

local function contentBody(view)
  if view.kind == "tab" then
    return tabBody(view)
  elseif view.kind == "detail" then
    return detailBody(view)
  elseif view.kind == "search" then
    return searchBody(view)
  elseif view.kind == "suggest" then
    return suggestBody()
  end
  return homeBody()
end

local function notConnected()
  return ui.column({ key = "nc", flexGrow = 1, align = "center", justify = "center", gap = 12 }, {
    ui.glyph({ name = "plug-connected-x", size = 36, color = "on_surface_variant" }),
    ui.label({ text = tr("lib.not_connected"), color = "on_surface_variant" }),
    ui.button({ text = tr("np.title"), glyph = "arrow-left", variant = "primary", onClick = "onNowPlaying" }),
  })
end

render = function()
  if not isOpen then
    return
  end
  dirty = false
  local root
  if not S.isConnected() then
    root = notConnected()
  else
    if #stack == 0 then
      stack = { defaultView() }
      ensureLoaded(stack[1])
    end
    local view = top()
    root = ui.row({ key = "main", gap = 16, flexGrow = 1, fill = "surface_container/0" }, {
      rail(),
      ui.column({ key = "content", gap = 12, flexGrow = 1 }, {
        contentHeader(view),
        -- A new key per view: each view starts scrolled to the top and keeps no stale nodes.
        ui.scroll({ key = "sc-" .. viewKey(view), flexGrow = 1, gap = 8 }, contentBody(view)),
      }),
    })
  end
  panel.render(ui.column({ gap = 0, padding = 16, flexGrow = 1, fill = "surface_container" }, { root }))
end

---- Lifecycle

function onOpen(_context)
  isOpen = true
  panel.setWantsSecondTicks(true) -- flash messages and cooldowns expire
  if S.isConnected() then
    loadEditablePlaylists()
    local view = top()
    if view then
      ensureLoaded(view)
    end
  end
  render()
end

function onClose()
  isOpen = false
  frameTicks = false
  openRow = nil
  art.clearQueue()
  -- Drop the not-yet-downloaded markers so the next open asks again.
  for id, v in pairs(thumbs) do
    if v == false then
      thumbs[id] = nil
    end
  end
end

function onFrameTick(_deltaMs)
  if suggestAt and now() >= suggestAt and now() - lastSuggestAt >= SUGGEST_GAP_MS then
    suggestAt = nil
    fetchSuggestions()
  end
  if dirty then
    render()
  end
  -- Keep ticking only while a debounced suggestion waits.
  if not dirty and not suggestAt then
    wantFrames(false)
  end
end

function update()
  if isOpen and flash and now() >= flash.untilMs then
    flash = nil
    markDirty()
  end
end

for _, key in ipairs({ S.TRACK, S.PLAYER, S.ART, S.SCOPES, S.SCOPE_REQUEST }) do
  noctalia.state.watch(key, markDirty)
end

noctalia.state.watch(S.CONN, function(conn)
  if type(conn) == "table" and conn.state == S.CONNECTED and isOpen then
    loadEditablePlaylists()
  end
  markDirty()
end)

-- Signing in or out changes what the library shows; start over (every hello republishes it, so compare).
local signedIn = S.get(S.SIGNED_IN)
noctalia.state.watch(S.SIGNED_IN, function(value)
  if value ~= signedIn then
    signedIn = value
    data = {}
    stack = {}
    editablePlaylists = nil
  end
  markDirty()
end)

