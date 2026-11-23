--!nonstrict
-- Shared by both frontends: navigation stack, loading, notices, the save bar and key handling.
-- shell.create(layout, options) returns ctx and the handlers an entry script exposes as globals.
-- layout(ctx, parts) builds the outer tree from parts = { page, route }: page = header, notices, content and
-- save bar in order.
local helper = require("./helper.luau")
local store = require("./store.luau")
local drafts = require("./drafts.luau")
local search = require("./search.luau")
local fields = require("../ui/fields.luau")
local kit = require("../ui/kit.luau")
local home = require("../pages/home.luau")
local form = require("../pages/form.luau")
local entries = require("../pages/entries.luau")
local maps = require("../pages/maps.luau")
local keybinds = require("../pages/keybinds.luau")
local desktop = require("../pages/desktop.luau")
local review = require("../pages/review.luau")
local about = require("../pages/about.luau")
local xkb = require("../pages/xkb.luau")
local files = require("../pages/files.luau")
local trymode = require("../pages/trymode.luau")
local teardown = require("./teardown.luau")

local M = {}

function M.create(layout, options)
  options = options or {}
  local stack = { { name = "home" } }
  local view = { gen = {}, invalid = {}, custom = {}, help = {}, expanded = {}, lastNumber = {}, query = "" }
  local loading = { meta = false, config = false, desktop = false }
  local notices = {}
  local draftChecked = false
  local firstLoad = true
  local ctx = { view = view, store = store, helper = helper, loading = loading, options = options,
                isApp = options.isApp == true }
  local epoch = 0
  local open = false  -- between onOpen and onClose: answers that arrive while closed notify instead

  function ctx.isOpen() return open end

  -- An answer for the user: a flash while the panel is open, else a notification (requests made with `always`).
  function ctx.tell(text, kind)
    if open then
      ctx.flash(text, kind)
      ctx.render()
    else
      noctalia.notify("Umbriel Settings", text)
    end
  end

  -- What the bar widget (Noctalia) and the window title and close prompt (app) show; also set by answers that
  -- arrive while the panel is closed, since only rendering publishes it otherwise.
  function ctx.publishPending()
    noctalia.state.set("umbriel.pending", store.pendingCount())
    noctalia.state.set("umbriel.trying", view.tryState and 1 or 0)
  end

  -- Input keys carry view.gen[key]. Keys that were never bumped read the epoch, so raising it replaces the
  -- text of every input, also of those still at their first generation.
  function ctx.resetInputs()
    epoch = epoch + 1
    local base = epoch * 1000000
    view.gen = setmetatable({}, { __index = function() return base end })
  end

  -- Inputs are uncontrolled: a page keys an input with ctx.gen(key) and calls ctx.bump(key) to replace its text.
  function ctx.gen(key) return tostring(view.gen[key] or 0) end
  function ctx.bump(key) view.gen[key] = (view.gen[key] or 0) + 1 end
  function ctx.clearSearch()
    view.query = ""
    ctx.bump("search")
  end

  function ctx.discardAll()
    store.discardAll()
    ctx.diagnostics = nil
    ctx.resetInputs()
  end
  if options.rebuildDefault == false then store.rebuild = false end

  local loadMeta  -- defined under "loading"; the error screen retries it

  local function route() return stack[#stack] end
  ctx.route = route
  function ctx.rootRoute() return stack[1] end

  local function body(current)
    if not store.meta then
      local content = { ctx.loadError and kit.notice(ctx.loadError, "error") or kit.loading() }
      if ctx.loadError and not loading.meta then
        table.insert(content, ui.row({ key = "retry-row" }, {
          ui.button({ key = "retry", text = "Try again", glyph = "refresh", variant = "primary", onClick = function()
            ctx.loadError = nil
            loadMeta()
            ctx.render()
          end }),
        }))
      end
      return { header = { kit.header(ctx, "Umbriel Settings", "Loading settings…") }, content = content }
    end
    local name = current.name
    if name == "home" then return home.render(ctx) end
    if name == "form" then return form.render(ctx, current) end
    if name == "entries" or name == "entry" or name == "pick-live" then
      return entries.render(ctx, current)
    end
    if name == "xkb" then return xkb.render(ctx, current) end
    if name == "map" then return maps.render(ctx, current) end
    if name == "keybinds" or name == "keybind" or name == "actions" then return keybinds.render(ctx, current) end
    if name == "folders" or name == "apps" or name == "appPicker" then return desktop.render(ctx, current) end
    if name == "about" then return about.render(ctx, current) end
    if name == "files" then return files.render(ctx, current) end
    if name == "customized" then return home.renderCustomized(ctx) end
    return review.render(ctx, current)
  end

  -- Live refresh: a page showing what Umbriel reports calls ctx.watchLive(events, onChange) while rendering;
  -- a `wait-live` long poll (`umbriel subscribe`) then runs until the page changes, and onChange (from the
  -- newest render) runs on each change. A failed poll stops until the page asks for other events.
  local liveWatch, livePoll, livePolls = nil, nil, 0
  function ctx.watchLive(events, onChange) liveWatch = { key = table.concat(events, ","), events = events,
                                                          onChange = onChange } end
  local function syncLivePoll()
    local wanted = liveWatch and liveWatch.key
    if (livePoll and livePoll.key) == wanted then return end
    livePoll = nil
    if not wanted then return end
    livePolls = livePolls + 1
    local id, events = livePolls, liveWatch.events
    livePoll = { key = wanted, id = id }
    local function ask()
      helper.call("wait-live", { events = events, timeout = 25 }, function(err, data)
        if not livePoll or livePoll.id ~= id then return end
        if err then return end  -- e.g. Umbriel not running: the Refresh buttons remain
        if data.event and liveWatch and liveWatch.key == wanted then liveWatch.onChange(data.event) end
        ask()
      end, { timeout = 35000 })
    end
    ask()
  end

  function ctx.render()
    -- Noctalia scales plugin radii only by UI scale, so the panel applies its corner roundness itself (watched:
    -- onConfigChanged). The app has no getSetting and scales radii in CSS.
    if not ctx.isApp then
      kit.setRadiusScale(noctalia.getSetting and noctalia.getSetting("shell.corner_radius_scale"))
    end
    local current = route()
    ctx.dropHandler = nil  -- set again by a page that draws drop zones
    liveWatch = nil  -- set again by a page that shows live data
    local parts = body(current)
    syncLivePoll()
    local noticeNodes = {}
    for index, notice in ipairs(notices) do
      table.insert(noticeNodes, kit.notice(notice.text, notice.kind, function()
        table.remove(notices, index)
        ctx.render()
      end, "flash-" .. index))
    end
    -- a page that sizes its content to the space (parts.fill, e.g. the display arrangement) doesn't scroll
    local content = parts.fill
      and ui.column({ key = "content-fill-" .. #stack .. "-" .. current.name, gap = 8, flexGrow = 1 }, parts.content)
      or ui.scroll({ key = "content-" .. #stack .. "-" .. current.name, gap = 8, flexGrow = 1,
                     revealKey = current.reveal }, parts.content or parts)
    local pending = store.pendingCount()
    local saveBar = nil
    -- Always shown once a config is loaded (quiet while nothing is unsaved): a bar that came and went would
    -- change the page height with every edit, and with it whether the page scrolls; the scrollbar then
    -- narrows or widens every row (Noctalia can't reserve its gutter for plugins).
    if store.meta and store.state and current.name ~= "review" then
      local dirty = pending > 0
      -- as tall as a two-line card (kit.navRow: border 1 + padding 6, two lines, 6 + 1 = 51 px in the app)
      saveBar = kit.rowCard({ key = "savebar", gap = 8, align = "center", paddingH = 12, height = 51,
                              radius = kit.RADIUS.md, fill = dirty and "primary_container" or nil }, {
        ui.glyph({ name = dirty and "pencil" or "check", size = kit.GLYPH.body, color = dirty and "primary" or kit.MUTED }),
        ui.label({ text = dirty and kit.plural(pending, "unsaved change") or "No unsaved changes", fontSize = kit.FONT.body,
                   color = not dirty and kit.MUTED or nil, flexGrow = 1 }),
        ui.button({ text = "Undo", glyph = "arrow-back-up", variant = "ghost", controlSize = "sm", tooltip = "Ctrl+Z",
                    enabled = store.canUndo(), onClick = function() ctx.undo() end }),
        kit.iconButton("arrow-forward-up", "Redo (Ctrl+Y)", function() ctx.redo() end, store.canRedo(), "redo"),
        ui.button({ text = "Discard", variant = "ghost", controlSize = "sm", enabled = dirty, onClick = function()
          ctx.discardAll()
          ctx.flash("All unsaved changes were discarded.", "info")
        end }),
        ui.button({ text = "Review & save", glyph = "device-floppy", variant = "primary", controlSize = "sm",
                    tooltip = "Ctrl+S", enabled = dirty, onClick = function() ctx.go({ name = "review" }) end }),
      })
    end
    local page = {}
    for _, child in ipairs(parts.header or {}) do table.insert(page, child) end
    for _, child in ipairs(noticeNodes) do table.insert(page, child) end
    local tryCard = store.meta and trymode.card(ctx)  -- Keep / Go back stay reachable from every page
    if tryCard then table.insert(page, tryCard) end
    table.insert(page, content)
    if saveBar then table.insert(page, saveBar) end
    panel.render(layout(ctx, { page = page, route = current }))
    ctx.publishPending()
    noctalia.state.set("umbriel.config", store.state and store.state.path or "")
  end

  -- Reverts the newest edit; inputs are rebuilt because they only take their text when created.
  function ctx.undo()
    if store.undo() then
      ctx.resetInputs()
      ctx.render()
    else
      ctx.flash("Nothing to undo.", "info")
    end
  end

  function ctx.redo()
    if store.redo() then
      ctx.resetInputs()
      ctx.render()
    else
      ctx.flash("Nothing to redo.", "info")
    end
  end

  -- Coalesce bursts (slider drags) into one render per frame.
  function ctx.renderSoon() panel.setNeedsFrameTick(true) end

  -- An entry added only to open it (a display tile without one) goes again when it is left untouched.
  function ctx.markProvisional()
    view.provisionalEntry = { serial = store.serial, step = store.history[#store.history] }
  end
  local function dropProvisional()
    local mark = view.provisionalEntry
    view.provisionalEntry = nil
    if mark and store.serial == mark.serial and store.history[#store.history] == mark.step then store.undo() end
  end

  -- Every navigation disarms "click again" confirmations; only replace keeps the notices.
  local function leave(keepNotices)
    view.confirmReset = nil
    view.confirm = nil
    view.kbRecording = nil
    dropProvisional()
    if not keepNotices then notices = {} end
  end
  function ctx.go(next)
    leave()
    table.insert(stack, next)
    ctx.render()
  end
  function ctx.replace(next)
    leave(true)
    stack[#stack] = next
    ctx.render()
  end
  function ctx.canGoBack() return #stack > 1 end
  function ctx.back()
    leave()
    if #stack > 1 then table.remove(stack) end
    ctx.render()
  end
  function ctx.home()
    leave()
    stack = { { name = "home" } }
    ctx.render()
  end

  function ctx.flash(text, kind)
    for _, notice in ipairs(notices) do
      if notice.text == text then ctx.render(); return end
    end
    table.insert(notices, { text = text, kind = kind or "info" })
    while #notices > 3 do table.remove(notices, 1) end
    ctx.render()
  end

  local function pageRoute(name, extra)
    local page = store.meta.pages[name]
    local kind = page and page.kind or "form"
    local next = { page = name }
    if kind == "form" then next.name = "form"
    elseif kind == "entries" then next.name = "entries"
    elseif kind == "map" then next.name = "map"
    elseif kind == "keybinds" then next.name = "keybinds"
    elseif kind == "userdirs" then next.name = "folders"
    else next.name = "apps" end
    for key, value in pairs(extra or {}) do next[key] = value end
    return next
  end

  -- Opens the page for a nav entry (form, entry list, map, keybinds, desktop). The app's sidebar opens
  -- pages as the root of the stack, so they have no back button.
  function ctx.openPage(name, extra)
    if ctx.isApp then
      leave()
      stack = { pageRoute(name, extra) }
      ctx.render()
    else
      ctx.go(pageRoute(name, extra))
    end
  end

  -- Opens the page (and group) holding a setting and scrolls to its row; `where` = search.locate's answer.
  function ctx.openField(fid, where)
    where = where or search.locate(store.meta, fid)
    if not where then return end
    if where.editor then
      ctx.openPage(where.page)
    else
      ctx.openPage(where.page, { group = where.group, reveal = fields.rowKey(fid) })
    end
  end

  function ctx.swatches()
    local result = {}
    for _, role in ipairs({ "primary", "secondary", "tertiary", "error", "surface", "on_surface" }) do
      local color = noctalia.getColor and noctalia.getColor(role)
      if color then table.insert(result, color) end
    end
    return result
  end

  -- ---------------------------------------------------------------- loading
  -- path switches configs (and remembers the choice); without it the current config is re-read.
  function ctx.reload(path, remember)
    loading.config = true
    ctx.render()
    local request = {}
    if path then request.config = path elseif store.state then request.config = store.state.path end
    local remembers = path and remember ~= false  -- set-config writes the choice: its answer must not get lost
    helper.call(remembers and "set-config" or "read", request, function(err, state)
      loading.config = false
      if not open then  -- answered after the panel closed: the next open reads the chosen config again
        if not err then store.load(state) end
        return
      end
      if ctx.changedDuringLoad then  -- the file changed while it was read (maybe half-written): read it again
        ctx.changedDuringLoad = false
        ctx.reload()
        return
      end
      if err then
        ctx.configError = err.error
        ctx.render()
        return
      end
      ctx.configError = nil
      local note = store.load(state)
      if note then table.insert(notices, { text = note, kind = "warning" }) end
      if not draftChecked then
        draftChecked = true
        local restored = drafts.restore()
        if restored then table.insert(notices, { text = restored, kind = "info" }) end
      end
      local parked = drafts.restoreParked()
      if parked then table.insert(notices, { text = parked, kind = "info" }) end
      ctx.render()
    end, { always = remembers })
  end

  function ctx.switchConfig()
    local path = noctalia.string.trim(view.pathDraft or "")
    if loading.config or path == "" or (store.state and path == store.state.path) then return end
    if store.hasConfigChanges() then
      ctx.flash("Save or discard your changes before opening another config.", "warning")
      return
    end
    ctx.reload(path)
  end

  function ctx.loadDesktop(force)
    if loading.desktop or (store.desktop and not force) then return end
    loading.desktop = true
    helper.call("desktop", {}, function(err, data)
      loading.desktop = false
      if err then
        ctx.desktopError = err.error
      else
        ctx.desktopError = nil
        local note = store.loadDesktop(data)
        if note then table.insert(notices, { text = note, kind = "info" }) end
        for _, part in ipairs({ data.userdirs, data.apps }) do  -- unreadable file: its edits can't be saved
          if part.error then table.insert(notices, { text = part.error .. " Fix the file, then reopen this page.",
                                                     kind = "error" }) end
        end
      end
      ctx.render()
    end)
  end

  function ctx.loadSearchIndex()
    if store.searchIndex or loading.search or not ctx.searchPath then return end
    loading.search = true
    helper.readJson(ctx.searchPath, function(err, data)
      loading.search = false
      if err then ctx.flash(err.error, "error"); return end
      store.searchIndex = data
      ctx.render()
    end)
  end

  -- Called while rendering, so a failed request is retried only after 30 s, never in a render loop.
  local kdeFailedAt = nil
  function ctx.loadKde()
    local now = noctalia.nowMs and noctalia.nowMs() or nil
    if ctx.kde == false and kdeFailedAt and now and now - kdeFailedAt > 30000 then ctx.kde = nil end
    if ctx.kde ~= nil then return end
    ctx.kde = false
    helper.call("kde-colors", {}, function(err, data)
      ctx.kde = (not err and data.available) and data or false
      kdeFailedAt = err and (noctalia.nowMs and noctalia.nowMs() or nil) or nil
      ctx.render()
    end)
  end

  function loadMeta()
    if loading.meta then return end
    loading.meta = true
    local dataDir = noctalia.pluginDataDir()
    helper.call("meta", { out_dir = dataDir and (dataDir .. "/cache") or nil }, function(err, paths)
      if err then
        loading.meta = false
        ctx.loadError = err.error
        ctx.render()
        return
      end
      ctx.searchPath = paths.search
      helper.readJson(paths.meta, function(readError, meta)
        loading.meta = false
        if readError then ctx.loadError = readError.error; ctx.render(); return end
        store.meta = meta
        ctx.loadError = nil
        ctx.render()
        if firstLoad and options.initialConfig then ctx.reload(options.initialConfig, false) else ctx.reload() end
        firstLoad = false
        ctx.loadDesktop()
      end)
    end)
  end

  -- ---------------------------------------------------------------- live outputs
  -- The connected outputs (`umbriel outputs --json`): {loading, error, outputs, names}, asked once per open (and
  -- again after ctx.forgetLiveOutputs()); outputs stay empty until Umbriel answers or when it can't.
  local liveOutputs = nil
  function ctx.connectedOutputs()
    if liveOutputs == nil then
      liveOutputs = { loading = true, outputs = {}, names = {} }
      helper.call("outputs", {}, function(err, data)
        if err then
          liveOutputs = { outputs = {}, names = {}, error = err.error or "Umbriel did not answer." }
        else
          local outputs, names = type(data.outputs) == "table" and data.outputs or {}, {}
          for _, output in ipairs(outputs) do
            if type(output) == "table" and type(output.name) == "string" then
              table.insert(names, output.name)
              if type(output.config_name) == "string" and output.config_name ~= "" then
                table.insert(names, output.config_name)
              end
            end
          end
          liveOutputs = { outputs = outputs, names = names }
        end
        ctx.render()
      end)
    end
    return liveOutputs
  end
  -- Their connector and monitor names, for output choices (the same table until they are asked again, so
  -- store.namedChoices can cache on it).
  function ctx.liveOutputs() return ctx.connectedOutputs().names end
  function ctx.forgetLiveOutputs() liveOutputs = nil end
  -- Asks again but keeps showing the current outputs until the answer arrives (live refresh).
  function ctx.refreshLiveOutputs()
    local shown = liveOutputs
    liveOutputs = nil
    ctx.connectedOutputs()
    if shown and not shown.loading and not shown.error and liveOutputs and liveOutputs.loading then
      liveOutputs.outputs, liveOutputs.names, liveOutputs.loading = shown.outputs, shown.names, nil
      liveOutputs.refreshing = true
    end
  end

  -- Busy flags of the live pickers (open windows/layers, XKB list, Run now): a dropped answer never clears them.
  function ctx.clearPickerBusy()
    view.kbRunning, view.xkbLoading = false, false
    if view.files and (view.files.loading or view.files.choosing) then view.files = nil end  -- listed again
    view.appCommandBusy, view.focusBusy = false, false
    if view.live and view.live.loading then view.live = nil end
    if liveOutputs and liveOutputs.loading then liveOutputs = nil end
    livePoll = nil  -- a closed panel dropped its answer: poll again
  end

  -- ---------------------------------------------------------------- entry points
  local handlers = {}

  function handlers.onOpen()
    open = true
    helper.generation = helper.generation + 1
    loading.meta, loading.config, loading.desktop, loading.search = false, false, false, false
    -- Answers to requests from before the panel closed are dropped, so their busy flags would stay set.
    view.titlebarLoading = false
    view.titlebar = nil  -- read again: it may have changed while the panel was closed
    ctx.clearPickerBusy()
    ctx.forgetLiveOutputs()  -- monitors may have changed while the panel was closed
    if ctx.kde == false and not kdeFailedAt then ctx.kde = nil end  -- its answer was dropped: ask again
    leave(true)  -- no "click again" confirmation survives a close
    view.sliding = {}
    for _, entry in ipairs(stack) do
      -- a save still running answers anyway (always) and clears its own flag
      if entry.state then entry.state.loading, entry.state.saving = false, ctx.saving and entry.state.saving end
    end
    notices = {}
    if not store.meta then
      loadMeta()
    elseif ctx.saving then
      ctx.changedDuringSave = true  -- read the file once that save is done (ctx.savingDone), not while it writes
    else
      ctx.reload()
      if not store.desktopChanges() then ctx.loadDesktop(true) end
    end
    ctx.render()
  end

  function handlers.onClose()
    open = false
    dropProvisional()
    drafts.save()
    helper.generation = helper.generation + 1
  end

  -- Noctalia tears the panel down (reload, disable, uninstall, shutdown): keep the edits as a draft, and stop
  -- title bars following Noctalia when the plugin itself goes away.
  function handlers.onExit(_, reason)
    if open then
      dropProvisional()
      drafts.save()
    end
    teardown.onExit(reason)
  end

  -- Noctalia: a shell setting read with getSetting changed (corner roundness); onOpen renders anyway.
  function handlers.onConfigChanged()
    if open then ctx.render() end
  end

  function handlers.onFrameTick()
    panel.setNeedsFrameTick(false)
    ctx.render()
  end

  function handlers.onKey(chord, pressed)
    if not pressed or not store.meta then return end
    if chord == "ctrl+f" then
      leave()
      stack = { { name = "home" } }
      ctx.bump("search")
      ctx.render()
    elseif chord == "ctrl+s" then
      if route().name == "review" then
        if route().saveNow then route().saveNow() end
      elseif store.pendingCount() > 0 then
        ctx.go({ name = "review" })
      end
    elseif chord == "alt+Left" then
      ctx.back()
    elseif chord == "ctrl+z" then
      ctx.undo()
    elseif chord == "ctrl+y" or chord == "ctrl+shift+z" then
      ctx.redo()
    elseif chord == "Escape" then  -- app only: in Noctalia, Escape always closes the panel
      if (view.query or "") ~= "" then
        ctx.clearSearch()
        ctx.render()
      elseif ctx.canGoBack() then
        ctx.back()
      elseif route().name ~= "home" then
        ctx.home()
      end
    end
  end

  -- Drop zones name a global too (Noctalia validates onDrop as a string); the page that drew them owns it.
  function handlers.onDrop(payload, value)
    if ctx.dropHandler then ctx.dropHandler(tostring(payload or ""), tostring(value or "")) end
  end

  -- The app re-reads the config when it changes on disk; unsaved edits are rebased by store.load.
  -- The app's file watch. kind "desktop": user-dirs.dirs or mimeapps.list; otherwise the config. While a save
  -- runs the change is most likely that save itself: re-read once it is done (ctx.savingDone).
  function handlers.onExternalChange(kind)
    if kind == "desktop" then
      if not store.desktop or loading.desktop then return end
      if store.desktopChanges() then
        ctx.flash("User folders or default apps changed on disk. Discard your folder and app edits to see the "
          .. "new version.", "warning")
      elseif not ctx.saving then
        ctx.loadDesktop(true)
      end
      return
    end
    if not (store.meta and store.state) then return end
    if ctx.saving then ctx.changedDuringSave = true
    elseif loading.config then ctx.changedDuringLoad = true
    else ctx.reload() end
  end

  function ctx.savingDone()
    ctx.saving = false
    if ctx.changedDuringSave then
      ctx.changedDuringSave = false
      ctx.reload()
    end
  end

  -- The app host calls this after a Lua error, which may have left a request's busy flag set forever.
  function handlers.onRecover()
    for name in pairs(loading) do loading[name] = false end
    ctx.saving, ctx.changedDuringSave = false, false
    ctx.clearPickerBusy()
    for _, entry in ipairs(stack) do
      if type(entry.state) == "table" then entry.state.saving, entry.state.loading = false, false end
    end
    ctx.render()
  end

  -- The app was started again (single instance) with a config path: open it unless unsaved edits of the
  -- current config would be lost.
  function handlers.onRelaunch(path)
    path = noctalia.string.trim(tostring(path or ""))
    if path == "" then return end
    if not store.meta then
      if firstLoad then options.initialConfig = path end
      return
    end
    if store.state and path == store.state.path then return end
    if store.hasConfigChanges() then
      ctx.flash("Save or discard your changes before opening " .. path .. ".", "warning")
      return
    end
    ctx.reload(path, false)
  end

  return ctx, handlers
end

return M
