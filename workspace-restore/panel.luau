--!nonstrict
-- Workspace Restore panel. One column per screen, left to right. Each
-- workspace is a card: the apps saved for it, an Add app button, and two
-- settings (Restore at login, Auto-add new apps). Actions are verbs on
-- outlined buttons; settings are checkbox chips, filled when on. The add
-- picker lists open windows and installed apps. wsr.py does all the work.

local shared = require("./shared.luau")

local tr = noctalia.tr

local PANEL_W = 1200 -- matches width in plugin.toml
local CHROME = 16 -- the panel's own inner padding, on each side
local PAD = 16
local COL_GAP = 16
local ICON = 18
local PICK_ROWS = 7 -- matches per picker column, so the panel never scrolls
-- Narrower cards stack the two settings instead of putting them side by side.
local SETTINGS_ROW_MIN_W = 330
-- A restore waits up to 45 s for launched apps, then 15 s for late windows.
local RESTORE_WATCH_S = 75

local data = nil
local open = false
local busy = false -- a layout edit is running
local drafts = {} -- keyword_key -> text typed but not saved yet
local adding = nil -- workspace the add picker is open for
local query = ""
local candidates = nil
-- Icons are looked up on the second ticks, never while rendering: the first
-- lookup after the bar starts loads the icon theme and can overrun the
-- callback's CPU budget. Until then an app shows a placeholder glyph.
local iconCache = {} -- id -> path, or false when there is none
local iconWanted = {} -- ids rendered without a cached icon
local iconTries = {}
local iconsChanged = false -- looked up last tick, not drawn yet
local ICON_BUDGET_MS = 15
local requestedAt = nil -- os.time() of the last restore click
local watchLeft = 0
local tick = 0

-- Children lists with optional entries: nil or false entries are dropped,
-- since a nil inside a table literal would cut the list short.
local function compact(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v ~= nil and v ~= false then
      out[#out + 1] = v
    end
  end
  return out
end

local function refresh()
  shared.status(function(d)
    if d ~= nil then
      data = d
    end
    render()
  end)
end

-- True from the click until the restore's report is written. The status
-- says when the restore holds its lock; the click time covers the moment
-- before it starts.
local function restoring()
  if data ~= nil and data.restoring == true then
    return true
  end
  if requestedAt == nil then
    return false
  end
  local last = data and data.last_restore and tonumber(data.last_restore.time) or 0
  if last >= requestedAt or os.time() - requestedAt > 10 then
    requestedAt = nil
    return false
  end
  return true
end

local function saveKeyword(key)
  local text = drafts[key]
  if text == nil then
    return
  end
  drafts[key] = nil
  shared.run("set-keyword " .. shared.quote(key) .. " " .. shared.quote(text), function()
    refresh()
  end)
end

local function flushDrafts()
  for key in pairs(drafts) do
    saveKeyword(key)
  end
end

-- Settings flip on screen right away; the status read afterwards confirms.
local function setTick(ws, on)
  ws.ticked = on
  render()
  shared.run("set-tick " .. (on and "1" or "0") .. " " .. ws.id, function()
    refresh()
  end)
end

local function setAutoAdd(ws, on)
  ws.auto_add = on
  render()
  shared.run("set-auto-add " .. (on and "1" or "0") .. " " .. ws.id, function()
    refresh()
  end)
end

-- Edits fail when the layout changed under the panel, e.g. auto-add.
local function edit(args)
  busy = true
  render()
  shared.run(args, function(result)
    busy = false
    if result == nil or result.ok ~= true then
      noctalia.notifyError(tr("ui.title"), tr("ui.edit-failed"))
    elseif result.note ~= nil then
      noctalia.notify(tr("ui.title"), tr("ui.already-listed"))
    end
    refresh()
  end)
end

local function startRestore(args)
  flushDrafts()
  shared.restore(args)
  requestedAt = os.time()
  watchLeft = RESTORE_WATCH_S
  noctalia.notify(tr("ui.title"), tr("ui.restoring-notify"))
  render()
end

local function openPicker(ws)
  flushDrafts()
  adding = ws
  query = ""
  candidates = nil
  render()
  shared.run("candidates --ws " .. ws.id, function(d)
    if adding == ws then
      candidates = d or { windows = {}, apps = {}, unsaved_here = 0 }
      render()
    end
  end)
end

local function closePicker()
  adding = nil
  render()
end

local function appIcon(id)
  local path = nil
  if id ~= nil and id ~= "" then
    path = iconCache[id]
    if path == nil then
      iconWanted[id] = true
    end
  end
  if path then
    return ui.image({ path = path, width = ICON, height = ICON, fit = "contain" })
  end
  return ui.glyph({ name = "app-window", size = ICON, color = "on_surface_variant" })
end

-- Looks up wanted icons within ICON_BUDGET_MS. An id stays wanted until its
-- lookup returns, so one cut short by the CPU budget is tried again (the
-- theme is loaded by then); after two tries it keeps the placeholder.
local function resolveIcons()
  local started = noctalia.nowMs()
  local changed = false
  for id in pairs(iconWanted) do
    if iconCache[id] == nil then
      iconTries[id] = (iconTries[id] or 0) + 1
      iconCache[id] = iconTries[id] <= 2 and noctalia.appIconPath(id, 32) or false
      changed = true
    end
    iconWanted[id] = nil
    if noctalia.nowMs() - started > ICON_BUDGET_MS then
      break
    end
  end
  return changed
end

-- --- main view ---------------------------------------------------------------

local function screenTitle(sc)
  if sc.builtin then
    return tr("ui.screen-builtin")
  end
  if (sc.model or "") ~= "" then
    return (((sc.make or "") .. " " .. sc.model):gsub("^%s+", ""))
  end
  return tostring(sc.desc)
end

local function screenSubtitle(sc)
  local text = tostring(sc.connector or "")
  if not sc.connected then
    text = text .. " · " .. tr("ui.not-connected")
  end
  return text
end

-- An app on the lists more than once: say where, then ask for a word from
-- this window's title so restoring can tell its windows apart.
local function keywordRows(rows, w)
  local key = w.keyword_key
  local value = drafts[key] or w.keyword or ""
  local app = tostring(w.label)
  local function note(text)
    rows[#rows + 1] = ui.row({ align = "start", gap = 6, paddingH = ICON + 8 }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
      ui.label({ text = text, fontSize = 10, color = "on_surface", maxLines = 3, flexGrow = 1 }),
    })
  end
  if value == "" then
    if w.twice_here then
      note(tr("ui.twice-here", { app = app }))
    end
    local also = w.also_on or {}
    if #also > 0 then
      local list = {}
      for _, id in ipairs(also) do
        list[#list + 1] = tostring(id)
      end
      note(tr("ui.also-on", { app = app, ws = table.concat(list, ", ") }))
    end
  end
  rows[#rows + 1] = ui.row({ paddingH = ICON + 8 }, {
    ui.label({ text = tr(value == "" and "ui.keyword-ask" or "ui.keyword-label"), fontSize = 10,
               color = "on_surface_variant", maxLines = 2, flexGrow = 1 }),
  })
  rows[#rows + 1] = ui.row({ align = "center", gap = 6, paddingH = ICON + 8 }, {
    ui.input({
      key = "kw-" .. key,
      value = value,
      placeholder = tr("ui.keyword-example", { title = tostring(w.title or app) }),
      controlSize = "sm",
      flexGrow = 1,
      tooltip = tr("ui.keyword-tooltip", { app = app }),
      onChange = function(text)
        drafts[key] = tostring(text or "")
      end,
      onSubmit = function()
        saveKeyword(key)
      end,
    }),
  })
end

local function appRows(rows, ws, i, w)
  rows[#rows + 1] = ui.row({ key = "app-" .. ws.id .. "-" .. i, align = "center", gap = 8 }, compact(
    appIcon(w.icon),
    ui.label({ text = tostring(w.label or w.class), fontSize = 12, maxLines = 1, flexGrow = 1,
               tooltip = tostring(w.command or "") }),
    not w.open and ui.label({ text = tr("ui.not-open"), fontSize = 10, color = "on_surface_variant",
                              tooltip = tr("ui.not-open-tooltip") }),
    ui.button({ glyph = "x", variant = "outline", controlSize = "xs", tooltip = tr("ui.remove"),
                enabled = not busy, onClick = function()
                  flushDrafts()
                  edit("remove-window " .. ws.id .. " " .. i .. " " .. shared.quote(w.class))
                end })
  ))
  if w.keyword_key ~= nil then
    keywordRows(rows, w)
  end
end

-- A setting of one workspace: a checkbox chip, filled with a tick when on.
local function setting(key, text, on, tooltip, onClick)
  return ui.button({ key = key, text = text, glyph = on and "checkbox" or "square",
                     variant = on and "primary" or "outline", controlSize = "sm", tooltip = tooltip,
                     onClick = onClick })
end

local function workspaceCard(ws, sc, width)
  local windows = ws.windows or {}
  local rows = {
    ui.row({ align = "center", gap = 8 }, compact(
      ui.label({ text = tr("ui.workspace", { name = tostring(ws.name) }), fontSize = 14, fontWeight = "bold",
                 maxLines = 1, flexGrow = 1 }),
      #windows > 0 and (ws.in_place == true and ui.row({ align = "center", gap = 4, tooltip = tr("ui.in-place-tooltip") }, {
        ui.glyph({ name = "check", size = 14, color = "on_surface_variant" }),
        ui.label({ text = tr("ui.in-place"), fontSize = 11, color = "on_surface_variant" }),
      }) or ui.button({ text = tr("ui.restore-now"), glyph = "restore", variant = "outline", controlSize = "sm",
                        enabled = sc.connected == true and #windows > 0 and not restoring(),
                        tooltip = tr(sc.connected and "ui.restore-now-tooltip" or "ui.restore-not-connected"),
                        onClick = function() startRestore("--ws " .. ws.id) end }))
    )),
  }
  for i, w in ipairs(windows) do
    appRows(rows, ws, i, w)
  end
  rows[#rows + 1] = ui.row({ align = "center", gap = 8 }, compact(
    ui.button({ text = tr("ui.add-app"), glyph = "plus", variant = "outline", controlSize = "sm",
                tooltip = tr("ui.add-app-tooltip"), enabled = not busy,
                onClick = function() openPicker(ws) end }),
    #windows == 0 and #(ws.unsaved_open or {}) == 0
      and ui.label({ text = tr("ui.no-apps"), fontSize = 11, color = "on_surface_variant" })
  ))
  -- Windows open on this workspace that its list doesn't have: one row each,
  -- by name, so it's clear what Add adds.
  local suggestions = ws.unsaved_open or {}
  if #suggestions > 0 then
    rows[#rows + 1] = ui.label({ text = tr("ui.open-not-listed"), fontSize = 11, color = "on_surface_variant" })
    for _, o in ipairs(suggestions) do
      rows[#rows + 1] = ui.row({ key = "sug-" .. o.address, align = "center", gap = 8 }, {
        appIcon(o.icon),
        ui.label({ text = tostring(o.label), fontSize = 12, color = "on_surface_variant", maxLines = 1,
                   flexGrow = 1, tooltip = tostring(o.title or "") }),
        ui.button({ text = tr("ui.add"), glyph = "plus", variant = "outline", controlSize = "xs",
                    tooltip = tr("ui.add-suggestion", { app = tostring(o.label) }), enabled = not busy,
                    onClick = function()
                      edit("add-window " .. ws.id .. " --address " .. shared.quote(o.address))
                    end }),
      })
    end
  end
  rows[#rows + 1] = ui.separator({})
  local login = setting("login-" .. ws.id, tr("ui.at-login"), ws.ticked == true, tr("ui.at-login-tooltip"),
                        function() setTick(ws, ws.ticked ~= true) end)
  local auto = setting("auto-" .. ws.id, tr("ui.auto-add"), ws.auto_add == true, tr("ui.auto-add-tooltip"),
                       function() setAutoAdd(ws, ws.auto_add ~= true) end)
  if width >= SETTINGS_ROW_MIN_W then
    rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, { login, auto })
  else
    rows[#rows + 1] = login
    rows[#rows + 1] = auto
  end
  return ui.column({ key = "ws-" .. ws.id, gap = 4, padding = 10, radius = 10, width = width,
                     fill = "surface_container/0.85", border = "outline_variant/0.6", borderWidth = 1 }, rows)
end

local function screenColumn(sc, workspaces, width)
  local children = {
    ui.row({ align = "center", gap = 8, paddingH = 2 }, {
      ui.glyph({ name = sc.builtin and "device-laptop" or "device-desktop", size = 18,
                 color = sc.connected and "primary" or "on_surface_variant" }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = screenTitle(sc), fontSize = 14, fontWeight = "bold", maxLines = 1 }),
        ui.label({ text = screenSubtitle(sc), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
      }),
    }),
  }
  for _, ws in ipairs(workspaces) do
    children[#children + 1] = workspaceCard(ws, sc, width)
  end
  if #workspaces == 0 then
    children[#children + 1] = ui.label({ text = tr("ui.no-workspaces"), fontSize = 11,
                                         color = "on_surface_variant" })
  end
  return ui.column({ key = "screen-" .. tostring(sc.desc), gap = 8, width = width }, children)
end

-- Saved apps that aren't open, once each: what Restore all now would open.
local function appsToOpen()
  local names, seen = {}, {}
  for _, ws in ipairs(data.workspaces or {}) do
    for _, w in ipairs(ws.windows or {}) do
      local name = tostring(w.label or w.class)
      if not w.open and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  return names
end

local function lastRestore()
  local r = data.last_restore or {}
  if r.time == nil then
    return nil
  end
  local parts = { tr("ui.last-restore", { ago = shared.ago(r.time) }) }
  local moved = tonumber(r.moved) or 0
  if #(r.launched or {}) > 0 then
    parts[#parts + 1] = tr("ui.opened", { apps = table.concat(r.launched, ", ") })
  end
  if moved > 0 then
    parts[#parts + 1] = noctalia.trp("ui.moved", moved)
  elseif #(r.launched or {}) == 0 and #(r.unmatched or {}) == 0 then
    parts[#parts + 1] = tr("ui.all-in-place")
  end
  if #(r.unmatched or {}) > 0 then
    parts[#parts + 1] = tr("ui.not-found", { apps = table.concat(r.unmatched, ", ") })
  end
  if #(r.skipped or {}) > 0 then
    parts[#parts + 1] = tr("ui.skipped", { ws = table.concat(r.skipped, ", ") })
  end
  return ui.label({ text = table.concat(parts, " · "), fontSize = 11, color = "on_surface_variant", maxLines = 3 })
end

local function mainView()
  local running = restoring()
  local toOpen = appsToOpen()
  local hasApps = false
  local allInPlace = true
  local outOfPlace = {}
  local byScreen = {}
  for _, ws in ipairs(data.workspaces or {}) do
    local list = byScreen[ws.monitor_desc] or {}
    byScreen[ws.monitor_desc] = list
    list[#list + 1] = ws
    hasApps = hasApps or #(ws.windows or {}) > 0
    if #(ws.windows or {}) > 0 and ws.in_place ~= true then
      allInPlace = false
      outOfPlace[#outOfPlace + 1] = tostring(ws.name)
    end
  end
  local screens = data.screens or {}
  local n = math.max(#screens, 1)
  local width = math.floor((PANEL_W - 2 * (CHROME + PAD) - COL_GAP * (n - 1)) / n)
  local columns = {}
  for _, sc in ipairs(screens) do
    columns[#columns + 1] = screenColumn(sc, byScreen[sc.desc] or {}, width)
  end

  local header = ui.row({ align = "center", gap = 10 }, compact(
    ui.glyph({ name = "layout-grid", size = 22, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("ui.title"), fontSize = 18, fontWeight = "bold" }),
      ui.label({ text = tr("ui.intro"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
    }),
    hasApps and not running and ui.row({ align = "center", gap = 4 }, compact(
      allInPlace and ui.glyph({ name = "check", size = 14, color = "on_surface_variant" }),
      ui.label({ text = allInPlace and tr("ui.all-in-place-note")
                   or (#outOfPlace == 1 and tr("ui.out-of-place-one", { ws = outOfPlace[1] })
                       or tr("ui.out-of-place-many", { ws = table.concat(outOfPlace, ", ") })),
                 fontSize = 11, color = "on_surface_variant", maxLines = 1 })
    )),
    ui.button({
      text = tr(running and "ui.restoring" or "ui.restore-all"),
      glyph = "restore",
      variant = "primary",
      controlSize = "md",
      enabled = hasApps and not running and not allInPlace,
      tooltip = allInPlace and tr("ui.all-in-place-tooltip") or #toOpen > 0 and tr("ui.restore-all-tooltip-open", { apps = table.concat(toOpen, ", ") })
        or tr("ui.restore-all-tooltip"),
      onClick = function() startRestore("--all") end,
    })
  ))

  return ui.column({ gap = 14, padding = PAD, flexGrow = 1, align = "stretch" }, compact(
    header,
    ui.row({ gap = COL_GAP, align = "start", flexGrow = 1 }, columns),
    lastRestore()
  ))
end

-- --- add picker ----------------------------------------------------------------

-- Best matches for the search text, at most PICK_ROWS, in list order when
-- nothing is typed.
local function search(items, text)
  local q = noctalia.string.trim(query)
  local scored = {}
  for _, item in ipairs(items or {}) do
    local score = q == "" and 0 or noctalia.fuzzyScore(q, text(item))
    if score ~= nil then
      scored[#scored + 1] = { item = item, score = score }
    end
  end
  if q ~= "" then
    table.sort(scored, function(a, b) return a.score > b.score end)
  end
  local out = {}
  for i = 1, math.min(#scored, PICK_ROWS) do
    out[i] = scored[i].item
  end
  return out
end

local function pickRow(key, icon, title, subtitle, savedHere, onAdd, listed)
  return ui.row({ key = key, align = "center", gap = 10, paddingH = 10, paddingV = 6, radius = 8,
                  fill = "surface_container/0.85", border = "outline_variant/0.6", borderWidth = 1 }, {
    appIcon(icon),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 12, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = subtitle, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
    listed and ui.button({ text = tr("ui.listed"), glyph = "check", variant = "outline", controlSize = "sm",
                           enabled = false, tooltip = tr("ui.listed-tooltip") })
      or ui.button({ text = tr(savedHere and "ui.add-again" or "ui.add"), glyph = "plus",
                     variant = savedHere and "outline" or "primary", controlSize = "sm",
                     tooltip = savedHere and tr("ui.add-again-tooltip") or nil, onClick = onAdd }),
  })
end

-- total: how many items the column has before searching, to say that
-- typing finds the ones not shown.
local function pickColumn(width, title, hint, extra, rows, total)
  local children = compact(
    ui.label({ text = title, fontSize = 14, fontWeight = "bold" }),
    ui.label({ text = hint, fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
    extra
  )
  if #rows == 0 then
    children[#children + 1] = ui.label({ text = tr("ui.no-matches"), fontSize = 11, color = "on_surface_variant" })
  end
  for _, r in ipairs(rows) do
    children[#children + 1] = r
  end
  if noctalia.string.trim(query) == "" and total > #rows then
    children[#children + 1] = ui.label({ text = noctalia.trp("ui.more", total - #rows), fontSize = 11,
                                         color = "on_surface_variant" })
  end
  return ui.column({ gap = 6, width = width }, children)
end

local function pickerView()
  local ws = adding
  local width = math.floor((PANEL_W - 2 * (CHROME + PAD) - COL_GAP) / 2)
  local function add(args)
    adding = nil
    edit(args)
  end
  local header = ui.row({ align = "center", gap = 10 }, {
    ui.button({ text = tr("ui.back"), glyph = "arrow-left", variant = "outline", controlSize = "sm",
                onClick = closePicker }),
    ui.label({ text = tr("ui.add-title", { name = tostring(ws.name) }), fontSize = 18, fontWeight = "bold",
               flexGrow = 1 }),
  })
  local searchBox = ui.input({ key = "pick-search", value = query, placeholder = tr("ui.search"), focus = true,
                               onChange = function(value)
                                 query = tostring(value or "")
                                 render()
                               end })
  if candidates == nil then
    return ui.column({ gap = 12, padding = PAD, flexGrow = 1, align = "stretch" }, {
      header, searchBox, ui.label({ text = tr("ui.loading"), color = "on_surface_variant" }) })
  end

  local addAll = nil
  local unsaved = tonumber(candidates.unsaved_here) or 0
  if unsaved > 0 and noctalia.string.trim(query) == "" then
    addAll = ui.button({ text = noctalia.trp("ui.add-all-open", unsaved), glyph = "plus", variant = "primary",
                         controlSize = "sm", onClick = function() add("add-open " .. ws.id) end })
  end
  local winRows = {}
  for _, w in ipairs(search(candidates.windows, function(w) return w.label .. " " .. w.title end)) do
    local where = w.ws == ws.id and tr("ui.on-this-workspace", { title = tostring(w.title) })
      or tr("ui.on-workspace", { ws = tostring(w.ws), title = tostring(w.title) })
    winRows[#winRows + 1] = pickRow("pw-" .. w.address, w.icon, tostring(w.label), where, w.saved_here == true,
      function() add("add-window " .. ws.id .. " --address " .. shared.quote(w.address)) end, w.listed == true)
  end
  local appRowsList = {}
  for _, a in ipairs(search(candidates.apps, function(a) return a.name .. " " .. a.id end)) do
    local about = (a.about or "") ~= "" and a.about or tostring(a.command)
    appRowsList[#appRowsList + 1] = pickRow("pa-" .. a.id, a.id, tostring(a.name), about, a.saved_here == true,
      function() add("add-window " .. ws.id .. " --desktop " .. shared.quote(a.id)) end)
  end

  return ui.column({ gap = 12, padding = PAD, flexGrow = 1, align = "stretch" }, {
    header,
    searchBox,
    ui.row({ gap = COL_GAP, align = "start", flexGrow = 1 }, {
      pickColumn(width, tr("ui.open-windows"), tr("ui.open-windows-hint"), addAll, winRows,
                 #(candidates.windows or {})),
      pickColumn(width, tr("ui.installed-apps"), tr("ui.installed-apps-hint"), nil, appRowsList,
                 #(candidates.apps or {})),
    }),
  })
end

-- --- lifecycle -----------------------------------------------------------------

function render()
  if not open then
    return
  end
  if adding ~= nil then
    panel.render(pickerView())
  elseif data == nil then
    panel.render(ui.column({ padding = PAD }, {
      ui.label({ text = tr("ui.loading"), color = "on_surface_variant" }) }))
  else
    panel.render(mainView())
  end
end

function onOpen()
  open = true
  render()
  refresh()
  panel.setWantsSecondTicks(true)
end

-- While a restore runs, re-read the status every 2 s to show its progress
-- and report.
-- Icon lookups and the redraw that shows them run in separate ticks, so
-- neither adds to the other's CPU budget.
function update()
  if iconsChanged then
    iconsChanged = false
    render()
  elseif next(iconWanted) ~= nil then
    iconsChanged = resolveIcons()
  end
  if watchLeft > 0 then
    watchLeft = watchLeft - 1
  end
  if watchLeft > 0 or restoring() then
    tick = tick + 1
    if tick % 2 == 0 then
      refresh()
    end
  end
end

function onClose()
  open = false
  adding = nil
  flushDrafts()
  panel.setWantsSecondTicks(false)
end

function onKey(chord, pressed)
  if pressed and tostring(chord or ""):lower() == "escape" then
    if adding ~= nil then
      closePicker()
    else
      panel.close()
    end
  end
end
