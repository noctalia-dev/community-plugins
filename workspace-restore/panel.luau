--!nonstrict
-- Workspace Restore panel. One column per screen, left to right. Each
-- workspace is a card: the apps saved for it, an Add app button, and two
-- settings (Restore at login, Auto-add new apps). Actions are verbs on
-- outlined buttons; settings are checkbox chips, filled when on. The add
-- picker lists open windows and installed apps. wsr.py does all the work.

local shared = require("./shared.luau")

local tr = noctalia.tr

-- A workspace is a number or, for a named workspace, "name:<name>".
-- As a wsr.py argument: quoted, since names can have spaces.
local function wsArg(id)
  return shared.quote(tostring(id))
end

local wsLabel = shared.wsLabel

local function wsLabels(ids)
  local out = {}
  for i, id in ipairs(ids or {}) do
    out[i] = wsLabel(id)
  end
  return table.concat(out, ", ")
end

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
-- Height left for the columns: max_height in plugin.toml minus header,
-- legend and footer.
local BODY_MAX_H = 1100 - 330
local SCROLLBAR_W = 14
local MAX_COLS = 3 -- screens side by side before the next row
local DRAG_TYPE = "wsr-workspace"
-- App and card states. Fixed colours: the palette has no green or orange.
local COLOR = {
  here = "#5cc26a", -- open here, as saved
  elsewhere = "#f0a33a", -- saved here, open on another workspace
  closed = "on_surface_variant", -- saved here, not open
  unsaved = "#5aa9f0", -- open here, not on the list
}

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
local renumbering = false -- the Change numbers mode is on
local numbers = {} -- workspace id -> number typed in that mode
local names = {} -- workspace id -> name typed in that mode
local expanded = {} -- workspace id -> shown in full though nothing needs doing

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
  shared.run("set-tick " .. (on and "1" or "0") .. " " .. wsArg(ws.id), function()
    refresh()
  end)
end

local function setAutoAdd(ws, on)
  ws.auto_add = on
  render()
  shared.run("set-auto-add " .. (on and "1" or "0") .. " " .. wsArg(ws.id), function()
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

-- A workspace card dropped on a screen column: move it there now.
function onWorkspaceDropped(payload, desc)
  for _, ws in ipairs(data and data.workspaces or {}) do
    if tostring(ws.id) == payload then
      if ws.pinned then
        noctalia.notify(tr("ui.title"), tr("ui.pinned-no-move"))
      elseif (ws.screen or ws.monitor_desc) ~= desc then
        edit("move-workspace " .. wsArg(ws.id) .. " " .. shared.quote(desc))
      end
      return
    end
  end
end

-- The numbers typed in Change numbers mode, and the ones used twice.
-- pinned: new numbers that a workspace rule pins to another screen.
local function typedNumbers()
  local out, count, bad, pinned = {}, {}, {}, {}
  local pins = data.pins or {}
  for _, ws in ipairs(data.workspaces or {}) do
    -- The workspace using a saved number shares its id: count it once.
    -- Named workspaces have no number to change.
    if ws.borrowed or ws.named then
      continue
    end
    local text = numbers[ws.id] or tostring(ws.id)
    local n = tonumber(noctalia.string.trim(text))
    if n == nil or n < 1 or n % 1 ~= 0 then
      bad[#bad + 1] = text
    else
      out[ws.id] = n
      count[n] = (count[n] or 0) + 1
      local pin = pins[tostring(n)]
      if n ~= ws.id and pin ~= nil and pin ~= (ws.screen or ws.monitor_desc) then
        pinned[#pinned + 1] = { n = n, desc = pin }
      end
    end
  end
  local dupes = {}
  for n, c in pairs(count) do
    if c > 1 then
      dupes[#dupes + 1] = n
    end
  end
  table.sort(dupes)
  return out, dupes, bad, pinned
end

-- The name box shows a name only when the workspace has one.
local function shownName(ws)
  local name = tostring(ws.name or "")
  return name ~= tostring(ws.id) and name or ""
end

local function startRenumber()
  flushDrafts()
  renumbering = true
  numbers = {}
  names = {}
  render()
end

local function stopRenumber()
  renumbering = false
  numbers = {}
  names = {}
  render()
end

local function applyNumbers()
  local typed, dupes, bad, pinned = typedNumbers()
  if #dupes > 0 or #bad > 0 or #pinned > 0 then
    return
  end
  local changes = {}
  for _, ws in ipairs(data.workspaces or {}) do
    if ws.borrowed or ws.in_use or ws.named then
      continue
    end
    if typed[ws.id] ~= ws.id then
      changes[#changes + 1] = ws.id .. ":" .. typed[ws.id]
    end
    local name = names[ws.id]
    if name ~= nil and noctalia.string.trim(name) ~= shownName(ws) then
      changes[#changes + 1] = "--name " .. shared.quote(ws.id .. "=" .. noctalia.string.trim(name))
    end
  end
  renumbering = false
  numbers = {}
  names = {}
  if #changes == 0 then
    render()
    return
  end
  edit("renumber " .. table.concat(changes, " "))
end

local function openPicker(ws)
  flushDrafts()
  adding = ws
  query = ""
  candidates = nil
  render()
  shared.run("candidates --ws " .. wsArg(ws.id), function(d)
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

local function screenByDesc(desc)
  for _, sc in ipairs(data.screens or {}) do
    if sc.desc == desc then
      return sc
    end
  end
  return { desc = desc }
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
        list[#list + 1] = wsLabel(id)
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

-- "Workspace 4", or "Workspace 4 · Work" when it has a name.
local function workspaceTitle(ws)
  local name = tostring(ws.name or "")
  if ws.named or name == "" or name == tostring(ws.id) then
    return tr("ui.workspace", { name = wsLabel(ws.id) })
  end
  return tr("ui.workspace-named", { id = tostring(ws.id), name = name })
end

local function dot(color)
  return ui.column({ width = 8, height = 8, radius = 4, fill = color }, {})
end

-- One app row: state dot, icon, name with its state tag below, then buttons.
local function appRow(key, color, icon, name, nameTooltip, tag, tagTooltip, buttons)
  local children = {
    dot(color),
    appIcon(icon),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.row({ tooltip = nameTooltip }, { ui.label({ text = name, fontSize = 12, maxLines = 1 }) }),
      ui.row({ tooltip = tagTooltip }, { ui.label({ text = tag, fontSize = 10, color = color, maxLines = 1 }) }),
    }),
  }
  for _, b in ipairs(buttons) do
    children[#children + 1] = b
  end
  return ui.row({ key = key, align = "center", gap = 8 }, children)
end

local function appRows(rows, ws, i, w)
  local state = w.state or "closed"
  local tag, tip = tr("ui.state-here"), tr("ui.state-here-tooltip")
  if state == "elsewhere" then
    tag = tr("ui.state-elsewhere", { ws = wsLabel(w.open_on) })
    tip = tr("ui.state-elsewhere-tooltip", { ws = wsLabel(w.open_on) })
  elseif state == "closed" then
    tag, tip = tr("ui.state-closed"), tr("ui.state-closed-tooltip")
  end
  rows[#rows + 1] = appRow("app-" .. ws.id .. "-" .. i, COLOR[state], w.icon, tostring(w.label or w.class),
    tostring(w.command or ""), tag, tip, {
      ui.button({ glyph = "x", variant = "outline", controlSize = "xs", tooltip = tr("ui.remove"),
                  enabled = not busy, onClick = function()
                    flushDrafts()
                    edit("remove-window " .. wsArg(ws.id) .. " " .. i .. " " .. shared.quote(w.class))
                  end }),
    })
  if w.keyword_key ~= nil then
    keywordRows(rows, w)
  end
end

-- A window open here that the list doesn't have. If its saved spot on
-- another workspace is empty it probably moved here: offer to move that
-- spot, or add it as a second one.
local function unsavedRow(rows, ws, o)
  local from = o.from
  local buttons = {}
  if from ~= nil then
    buttons[#buttons + 1] = ui.button({ text = tr("ui.move-here"), variant = "outline", controlSize = "xs",
      enabled = not busy, tooltip = tr("ui.move-app-tooltip", { app = tostring(o.label), ws = wsLabel(from.ws) }),
      onClick = function()
        edit("move-window " .. wsArg(ws.id) .. " " .. wsArg(from.ws) .. " " .. from.index .. " " .. shared.quote(from.class))
      end })
  end
  buttons[#buttons + 1] = ui.button({ text = tr("ui.add"), glyph = "plus", variant = "outline", controlSize = "xs",
    tooltip = tr(from ~= nil and "ui.add-also-tooltip" or "ui.add-suggestion",
                 { app = tostring(o.label), ws = from and wsLabel(from.ws) or "" }),
    enabled = not busy,
    onClick = function() edit("add-window " .. wsArg(ws.id) .. " --address " .. shared.quote(o.address)) end })
  local tag = from ~= nil and tr("ui.state-saved-on", { ws = wsLabel(from.ws) }) or tr("ui.state-unsaved")
  -- The key changes with the buttons: a row keeping its key while gaining
  -- a button was drawn twice.
  rows[#rows + 1] = appRow("sug-" .. o.address .. (from and "-move" or ""), COLOR.unsaved, o.icon, tostring(o.label), tostring(o.title or ""),
    tag, tr("ui.state-unsaved-tooltip"), buttons)
end

local function setting(key, text, on, tooltip, onClick)
  return ui.button({ key = key, text = text, glyph = on and "checkbox" or "square",
                     variant = on and "primary" or "outline", controlSize = "sm", tooltip = tooltip,
                     onClick = onClick })
end

-- Nothing to do on this workspace: every saved app is open here, nothing
-- unsaved is open, it's on its screen and needs no title word. Such a card
-- shrinks to one line unless the user expanded it.
local function settled(ws)
  local windows = ws.windows or {}
  if renumbering or ws.borrowed or ws.in_use or ws.now_on ~= nil or #windows == 0
      or #(ws.unsaved_open or {}) > 0 then
    return false
  end
  for _, w in ipairs(windows) do
    if w.state ~= "here" or (w.keyword_key ~= nil and (w.keyword or "") == "") then
      return false
    end
  end
  return true
end

-- The drag grip, or a pin for a workspace a rule pins to its screen.
local function handle(ws)
  if ws.pinned then
    return ui.row({ width = 18, height = 22, align = "center", justify = "center", tooltip = tr("ui.pinned-tooltip") }, {
      ui.glyph({ name = "pin", size = 14, color = "on_surface_variant" }),
    })
  end
  return ui.dragSource({ key = "grip-" .. ws.id, dragType = DRAG_TYPE, payload = tostring(ws.id), previewAncestor = 2,
                         enabled = not busy and not renumbering and not ws.in_use, width = 18, height = 22,
                         align = "center", justify = "center", tooltip = tr("ui.drag-tooltip") }, {
    ui.glyph({ name = "grip-vertical", size = 14, color = "on_surface_variant" }),
  })
end

local function compactCard(ws, width)
  local icons = {}
  for _, w in ipairs(ws.windows or {}) do
    icons[#icons + 1] = ui.row({ tooltip = tostring(w.label or w.class) }, { appIcon(w.icon) })
  end
  return ui.row({ key = "ws-" .. ws.id, gap = 8, padding = 8, radius = 10, width = width, align = "stretch",
                  fill = "surface_container/0.85", border = "outline_variant/0.6", borderWidth = 1 }, {
    ui.column({ width = 4, radius = 2, fill = COLOR.here, tooltip = tr("ui.edge-here-tooltip") }, {}),
    ui.row({ align = "center", gap = 8, flexGrow = 1 }, compact(
      handle(ws),
      ui.label({ text = workspaceTitle(ws), fontSize = 13, fontWeight = "bold", maxLines = 1 }),
      ui.row({ align = "center", gap = 4, flexGrow = 1 }, icons),
      ws.ticked and ui.label({ text = tr("ui.at-login-short"), fontSize = 10, color = "primary" }),
      ui.button({ glyph = "chevron-down", variant = "outline", controlSize = "xs", tooltip = tr("ui.more"),
                  onClick = function()
                    expanded[ws.id] = true
                    render()
                  end })
    )),
  })
end

local function workspaceCard(ws, sc, width)
  local windows = ws.windows or {}
  local title = ui.label({ text = workspaceTitle(ws), fontSize = 14, fontWeight = "bold", maxLines = 1,
                          flexGrow = 1 })
  if renumbering and not ws.in_use and not ws.named then
    title = ui.row({ align = "center", gap = 6, flexGrow = 1 }, {
      ui.input({ key = "num-" .. ws.id, value = numbers[ws.id] or tostring(ws.id), width = 56,
                 controlSize = "sm", tooltip = tr("ui.number-tooltip"),
                 onChange = function(text)
                   numbers[ws.id] = tostring(text or "")
                   render()
                 end,
                 onSubmit = applyNumbers }),
      ui.input({ key = "name-" .. ws.id, value = names[ws.id] or shownName(ws), placeholder = tr("ui.name-placeholder"),
                 controlSize = "sm", flexGrow = 1, tooltip = tr("ui.name-tooltip"),
                 onChange = function(text)
                   names[ws.id] = tostring(text or "")
                 end,
                 onSubmit = applyNumbers }),
    })
  end
  local rows = {
    ui.row({ align = "center", gap = 8 }, compact(
      handle(ws),
      title,
      not renumbering and not ws.in_use and #windows > 0 and (ws.in_place == true and ui.row({ align = "center", gap = 4, tooltip = tr("ui.in-place-tooltip") }, {
        ui.glyph({ name = "check", size = 14, color = "on_surface_variant" }),
        ui.label({ text = tr("ui.in-place"), fontSize = 11, color = "on_surface_variant" }),
      }) or ui.button({ text = tr("ui.restore-now"), glyph = "restore", variant = "outline", controlSize = "sm",
                        enabled = sc.connected == true and #windows > 0 and not restoring(),
                        tooltip = tr(sc.connected and "ui.restore-now-tooltip" or "ui.restore-not-connected"),
                        onClick = function() startRestore("--ws " .. wsArg(ws.id)) end })),
      settled(ws) and ui.button({ glyph = "chevron-up", variant = "outline", controlSize = "xs", tooltip = tr("ui.less"),
                                  onClick = function()
                                    expanded[ws.id] = nil
                                    render()
                                  end })
    )),
  }
  -- Another workspace is using this number: say where, and offer a free
  -- number for this one.
  if ws.in_use then
    rows[#rows + 1] = ui.row({ align = "start", gap = 6, tooltip = tr("ui.in-use-tooltip", { ws = tostring(ws.id) }) }, {
      ui.glyph({ name = "alert-triangle", size = 14, color = COLOR.elsewhere }),
      ui.label({ text = tr("ui.in-use", { ws = tostring(ws.id) }), fontSize = 10, color = "on_surface", maxLines = 2,
                 flexGrow = 1 }),
    })
    rows[#rows + 1] = ui.row({}, {
      ui.button({ text = tr("ui.new-number"), variant = "outline", controlSize = "xs", enabled = not busy,
                  tooltip = tr("ui.new-number-tooltip"),
                  onClick = function() edit("renumber-saved " .. wsArg(ws.id)) end }),
    })
  end
  -- A workspace rule pins it: it can't be dragged or saved elsewhere.
  if ws.pinned then
    rows[#rows + 1] = ui.row({ align = "center", gap = 6, tooltip = tr("ui.pinned-tooltip") }, {
      ui.glyph({ name = "pin", size = 12, color = "on_surface_variant" }),
      ui.label({ text = tr("ui.pinned", { screen = screenTitle(screenByDesc(ws.monitor_desc)) }), fontSize = 10,
                 color = "on_surface_variant", maxLines = 1 }),
    })
  end
  -- Cards sit on the screen their workspace is on now. Saved on another
  -- one: restoring moves it back there unless it's moved here.
  if ws.now_on ~= nil and not ws.pinned then
    local saved = screenTitle(screenByDesc(ws.monitor_desc))
    local here = screenTitle(sc)
    rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
      ui.row({ align = "center", gap = 6, flexGrow = 1, tooltip = tr("ui.saved-on-tooltip", { saved = saved }) }, {
        ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
        ui.label({ text = tr("ui.saved-on", { saved = saved }), fontSize = 10, color = "on_surface", maxLines = 1 }),
      }),
      ui.button({ text = tr("ui.move-here"), variant = "outline", controlSize = "xs", enabled = not busy,
                  tooltip = tr("ui.move-screen-tooltip", { screen = here }),
                  onClick = function() edit("set-monitor " .. wsArg(ws.id)) end }),
    })
  end
  for i, w in ipairs(windows) do
    appRows(rows, ws, i, w)
  end
  local unsaved = ws.unsaved_open or {}
  for _, o in ipairs(unsaved) do
    unsavedRow(rows, ws, o)
  end
  rows[#rows + 1] = ui.row({ align = "center", gap = 8 }, compact(
    ui.button({ text = tr("ui.add-app"), glyph = "plus", variant = "outline", controlSize = "sm",
                tooltip = tr("ui.add-app-tooltip"), enabled = not busy and not ws.in_use,
                onClick = function() openPicker(ws) end }),
    #windows == 0 and #unsaved == 0
      and ui.label({ text = tr("ui.no-apps"), fontSize = 11, color = "on_surface_variant" })
  ))
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
  -- Left edge, from the saved apps and the screen only (apps open here
  -- but not saved change nothing): orange when the workspace or a saved app
  -- is somewhere else, grey when a saved app is closed, green when all are
  -- open here, none when nothing is saved.
  local away, closed = ws.now_on ~= nil, false
  for _, w in ipairs(windows) do
    away = away or w.state == "elsewhere"
    closed = closed or w.state == "closed"
  end
  local edge, edgeTip = "outline_variant/0.6", tr("ui.edge-none-tooltip")
  if away then
    edge, edgeTip = COLOR.elsewhere, tr("ui.edge-away-tooltip")
  elseif closed then
    edge, edgeTip = COLOR.closed, tr("ui.edge-closed-tooltip")
  elseif #windows > 0 then
    edge, edgeTip = COLOR.here, tr("ui.edge-here-tooltip")
  end
  return ui.row({ key = "ws-" .. ws.id, gap = 8, padding = 10, radius = 10, width = width, align = "stretch",
                  fill = "surface_container/0.85", border = "outline_variant/0.6", borderWidth = 1 }, {
    ui.column({ width = 4, radius = 2, fill = edge, tooltip = edgeTip }, {}),
    ui.column({ gap = 4, flexGrow = 1 }, rows),
  })
end

-- An open workspace using a saved workspace's number. "ask": the signs
-- were mixed, so the panel asks whether it is the saved one.
local function borrowedCard(ws, width)
  local asking = ws.borrowed == "ask"
  local rows = {
    ui.label({ text = tr(asking and "ui.borrowed-ask" or "ui.borrowed", { ws = tostring(ws.id) }), fontSize = 14,
               fontWeight = "bold", maxLines = 2 }),
    ui.label({ text = tr(asking and "ui.borrowed-ask-hint" or "ui.borrowed-hint", { ws = tostring(ws.id) }),
               fontSize = 10, color = "on_surface_variant", maxLines = 3 }),
  }
  for _, o in ipairs(ws.unsaved_open or {}) do
    rows[#rows + 1] = appRow("bw-" .. o.address, COLOR.unsaved, o.icon, tostring(o.label), tostring(o.title or ""),
                             tr("ui.state-unsaved"), tr("ui.borrowed-app-tooltip", { ws = tostring(ws.id) }), {})
  end
  local function answer(state)
    edit("set-identity " .. wsArg(ws.id) .. " " .. state)
  end
  if asking then
    rows[#rows + 1] = ui.row({ align = "center", gap = 6 }, {
      ui.button({ text = tr("ui.borrowed-yes"), variant = "outline", controlSize = "sm", enabled = not busy,
                  onClick = function() answer("real") end }),
      ui.button({ text = tr("ui.borrowed-no"), variant = "outline", controlSize = "sm", enabled = not busy,
                  onClick = function() answer("borrowed") end }),
    })
  else
    rows[#rows + 1] = ui.button({ text = tr("ui.borrowed-mine"), variant = "outline", controlSize = "sm",
                                  enabled = not busy, tooltip = tr("ui.borrowed-mine-tooltip", { ws = tostring(ws.id) }),
                                  onClick = function() answer("real") end })
  end
  return ui.column({ key = "borrowed-" .. ws.id, gap = 4, padding = 10, radius = 10, width = width,
                     fill = "surface_container/0.85", border = COLOR.unsaved .. "99", borderWidth = 1 }, rows)
end

-- Where a workspace open on another screen is saved: a faded card, so
-- both places show at once.
local function ghostCard(ws, sc, width)
  local now = screenTitle(screenByDesc(ws.screen))
  return ui.column({ key = "ghost-" .. ws.id, gap = 4, padding = 10, radius = 10, width = width,
                     fill = "surface_container/0.25", border = COLOR.elsewhere .. "80", borderWidth = 1 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = workspaceTitle(ws), fontSize = 14, fontWeight = "bold",
                 color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      ui.button({ text = tr("ui.move-back-here"), variant = "outline", controlSize = "xs",
                  enabled = not busy and sc.connected == true,
                  tooltip = tr("ui.move-back-tooltip", { screen = screenTitle(sc) }),
                  onClick = function() edit("move-workspace " .. wsArg(ws.id) .. " " .. shared.quote(sc.desc)) end }),
    }),
    ui.label({ text = tr("ui.ghost", { now = now }), fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
  })
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
    if ws.ghost then
      children[#children + 1] = ghostCard(ws.ws, sc, width)
    elseif ws.borrowed then
      children[#children + 1] = borrowedCard(ws, width)
    elseif settled(ws) and not expanded[ws.id] then
      children[#children + 1] = compactCard(ws, width)
    else
      children[#children + 1] = workspaceCard(ws, sc, width)
    end
  end
  if #workspaces == 0 then
    children[#children + 1] = ui.label({ text = tr("ui.no-workspaces"), fontSize = 11,
                                         color = "on_surface_variant" })
  end
  return ui.dropZone({ key = "screen-" .. tostring(sc.desc), accepts = { DRAG_TYPE }, value = tostring(sc.desc),
                       onDrop = "onWorkspaceDropped", enabled = sc.connected == true and not busy,
                       direction = "column", gap = 8, width = width, radius = 10 }, children)
end

-- Saved apps that aren't open, once each: what Restore all now would open.
local function appsToOpen()
  local names, seen = {}, {}
  for _, ws in ipairs(data.workspaces or {}) do
    for _, w in ipairs(ws.in_use and {} or ws.windows or {}) do
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
  for _, a in ipairs(r.set_aside or {}) do
    parts[#parts + 1] = noctalia.trp("ui.set-aside", tonumber(a.count) or 0, { ws = wsLabel(a.ws), from = wsLabel(a.from) })
  end
  if #(r.in_use or {}) > 0 then
    parts[#parts + 1] = tr("ui.skipped-in-use", { ws = wsLabels(r.in_use) })
  end
  if #(r.skipped or {}) > 0 then
    parts[#parts + 1] = tr("ui.skipped", { ws = wsLabels(r.skipped) })
  end
  return ui.label({ text = table.concat(parts, " · "), fontSize = 11, color = "on_surface_variant", maxLines = 3 })
end

local function renumberControls()
  local _, dupes, bad, pinned = typedNumbers()
  local problem = nil
  if #pinned > 0 then
    problem = tr("ui.number-pinned", { n = tostring(pinned[1].n), screen = screenTitle(screenByDesc(pinned[1].desc)) })
  elseif #bad > 0 then
    problem = tr("ui.number-bad", { text = bad[1] })
  elseif #dupes > 0 then
    local list = {}
    for _, n in ipairs(dupes) do
      list[#list + 1] = tostring(n)
    end
    problem = tr("ui.number-twice", { n = table.concat(list, ", ") })
  end
  return ui.row({ align = "center", gap = 8 }, compact(
    problem and ui.label({ text = problem, fontSize = 11, color = "error", maxLines = 1 }),
    ui.button({ text = tr("ui.cancel"), variant = "outline", controlSize = "md", onClick = stopRenumber }),
    ui.button({ text = tr("ui.apply"), glyph = "check", variant = "primary", controlSize = "md",
                enabled = problem == nil and not busy, tooltip = tr("ui.apply-tooltip"),
                onClick = applyNumbers })
  ))
end

-- Rough height of each column's cards in px, to tell whether they fit.
local function cardHeight(ws)
  if ws.ghost then
    return 70
  end
  local apps = #(ws.windows or {}) + #(ws.unsaved_open or {})
  if ws.borrowed then
    return 110 + 30 * apps
  end
  if settled(ws) and not expanded[ws.id] then
    return 48
  end
  local notes = (ws.pinned and 18 or 0) + (ws.now_on and 34 or 0) + (ws.in_use and 60 or 0)
  return 140 + 34 * apps + notes
end

-- Rough height of the columns: each row of screens is as tall as its
-- tallest column.
local function bodyHeight(byScreen, screens)
  local total = 0
  for first = 1, #screens, MAX_COLS do
    local tallest = 0
    for i = first, math.min(first + MAX_COLS - 1, #screens) do
      local h = 40 -- screen title
      for _, ws in ipairs(byScreen[screens[i].desc] or {}) do
        h = h + cardHeight(ws) + 8
      end
      tallest = math.max(tallest, h)
    end
    total = total + tallest + (first > 1 and COL_GAP or 0)
  end
  return total
end

local function mainView()
  local running = restoring()
  local toOpen = appsToOpen()
  local hasApps = false
  local allInPlace = true
  local outOfPlace = {}
  local byScreen = {}
  for _, ws in ipairs(data.workspaces or {}) do
    local where = ws.screen or ws.monitor_desc
    local list = byScreen[where] or {}
    byScreen[where] = list
    list[#list + 1] = ws
    if ws.now_on ~= nil then
      local saved = byScreen[ws.monitor_desc] or {}
      byScreen[ws.monitor_desc] = saved
      saved[#saved + 1] = { ghost = true, ws = ws }
    end
    hasApps = hasApps or #(ws.windows or {}) > 0
    if #(ws.windows or {}) > 0 and ws.in_place ~= true and not ws.in_use then
      allInPlace = false
      outOfPlace[#outOfPlace + 1] = wsLabel(ws.id)
    end
  end
  -- At most MAX_COLS screens side by side; more go on further rows, so
  -- cards keep their width with many screens.
  local screens = data.screens or {}
  local n = math.max(math.min(#screens, MAX_COLS), 1)
  -- Scrolling columns leave room for the scrollbar on the right.
  local scrolls = bodyHeight(byScreen, screens) > BODY_MAX_H
  local width = math.floor((PANEL_W - 2 * (CHROME + PAD) - COL_GAP * (n - 1) - (scrolls and SCROLLBAR_W or 0)) / n)
  local screenRows = {}
  for first = 1, #screens, MAX_COLS do
    local cols = {}
    for i = first, math.min(first + MAX_COLS - 1, #screens) do
      cols[#cols + 1] = screenColumn(screens[i], byScreen[screens[i].desc] or {}, width)
    end
    screenRows[#screenRows + 1] = ui.row({ key = "screens-" .. first, gap = COL_GAP, align = "start" }, cols)
  end
  local body = ui.column({ gap = COL_GAP }, screenRows)

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
    renumbering and renumberControls() or ui.button({ text = tr("ui.change-numbers"), variant = "outline",
                                                      controlSize = "md", enabled = not busy and not running,
                                                      tooltip = tr("ui.change-numbers-tooltip"),
                                                      onClick = startRenumber }),
    not renumbering and ui.button({
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

  -- Fixed widths per legend column, so the two rows line up.
  local KEY_W = { 140, 220, 130, 130 }
  local function key(i, mark, text)
    return ui.row({ align = "center", gap = 5, width = KEY_W[i] }, {
      ui.row({ width = 8, align = "center", justify = "center" }, { mark }),
      ui.label({ text = text, fontSize = 10, color = "on_surface_variant", maxLines = 1 }) })
  end
  local function bar(color)
    return ui.column({ width = 4, height = 12, radius = 2, fill = color }, {})
  end
  local function heading(text)
    return ui.row({ width = 64 }, {
      ui.label({ text = text, fontSize = 10, fontWeight = "bold", color = "on_surface_variant", maxLines = 1 }) })
  end
  local legend = ui.column({ gap = 4 }, {
    ui.row({ align = "center", gap = 14 }, {
      heading(tr("ui.legend-apps")),
      key(1, dot(COLOR.here), tr("ui.legend-here")),
      key(2, dot(COLOR.elsewhere), tr("ui.legend-elsewhere")),
      key(3, dot(COLOR.closed), tr("ui.legend-closed")),
      key(4, dot(COLOR.unsaved), tr("ui.legend-unsaved")),
    }),
    ui.row({ align = "center", gap = 14 }, {
      heading(tr("ui.legend-edge")),
      key(1, bar(COLOR.here), tr("ui.legend-edge-here")),
      key(2, bar(COLOR.elsewhere), tr("ui.legend-edge-away")),
      key(3, bar(COLOR.closed), tr("ui.legend-edge-closed")),
      key(4, bar("outline_variant/0.6"), tr("ui.legend-edge-none")),
    }),
  })

  -- A state file that couldn't be read: say where its copy is.
  local broken = #(data.broken or {}) > 0
    and ui.label({ text = tr("ui.broken", { files = table.concat(data.broken, ", ") }), fontSize = 11,
                   color = "error", maxLines = 3 })

  return ui.column({ gap = 14, padding = PAD, flexGrow = 1, align = "stretch" }, compact(
    header,
    broken,
    legend,
    -- A scroll that grows with the panel keeps the panel at whatever height
    -- it had, so the columns only scroll when they're estimated not to fit,
    -- in a scroll of fixed height.
    scrolls
      and ui.column({ height = BODY_MAX_H }, { ui.scroll({ flexGrow = 1 }, { body }) })
      or body,
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
                         controlSize = "sm", onClick = function() add("add-open " .. wsArg(ws.id)) end })
  end
  local winRows = {}
  for _, w in ipairs(search(candidates.windows, function(w) return w.label .. " " .. w.title end)) do
    local where = w.ws == ws.id and tr("ui.on-this-workspace", { title = tostring(w.title) })
      or tr("ui.on-workspace", { ws = wsLabel(w.ws), title = tostring(w.title) })
    winRows[#winRows + 1] = pickRow("pw-" .. w.address, w.icon, tostring(w.label), where, w.saved_here == true,
      function() add("add-window " .. wsArg(ws.id) .. " --address " .. shared.quote(w.address)) end, w.listed == true)
  end
  local appRowsList = {}
  for _, a in ipairs(search(candidates.apps, function(a) return a.name .. " " .. a.id end)) do
    local about = (a.about or "") ~= "" and a.about or tostring(a.command)
    appRowsList[#appRowsList + 1] = pickRow("pa-" .. a.id, a.id, tostring(a.name), about, a.saved_here == true,
      function() add("add-window " .. wsArg(ws.id) .. " --desktop " .. shared.quote(a.id)) end)
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
