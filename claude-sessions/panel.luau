--!nonstrict
local shared = require("./shared.luau")
local CTX = tonumber(noctalia.getConfig("context_window")) or 1000000

local sessions = noctalia.state.get("sessions") or {}
local recent = noctalia.state.get("recent") or {}
local accounts = noctalia.state.get("accounts") or {}
local collapsed = {} -- account dir -> true when its section is folded (multi-account only)
local pickAccount = nil -- account a new session starts under (picker)
-- Hover: only the innermost interactive node under the pointer reports, so the card and its
-- buttons each report for the same key; count them so moving between them keeps it active.
local hoverCount = {} -- item key -> number of its nodes currently hovered
local dirty = false -- re-render on the next frame (coalesces enter/leave bursts)
local selected = nil -- item key picked with the keyboard
local showRecent = false
local showPicker = false
local armedKill, armedAt = nil, 0 -- kill needs a second click within 3s

local GROUPS = {
  { status = "waiting", title = "Needs you", glyph = "bell-ringing", color = "error" },
  { status = "busy", title = "Working", glyph = "loader-2", color = "primary" },
  { status = "idle", title = "Idle", glyph = "circle-check", color = "on_surface_variant" },
}
local LOOK = {}
for _, g in ipairs(GROUPS) do LOOK[g.status] = g end

local TOOL_GLYPH = {
  Bash = "terminal-2", Edit = "pencil", Write = "file-plus", Read = "file-text", NotebookEdit = "notebook",
  Grep = "search", Glob = "folder-search", Agent = "robot", Task = "robot", WebFetch = "world",
  WebSearch = "world-search", TodoWrite = "list-check", Skill = "sparkles", AskUserQuestion = "help-circle",
}
local MODE_GLYPH = { auto = "bolt", plan = "map", default = "shield-check", acceptEdits = "pencil-check", bypassPermissions = "alert-triangle" }

local function tokens(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  return `{math.floor(n / 1000)}k`
end

local function money(c) return string.format("$%.2f", c) end

local function iconLine(glyph, text, color, size)
  return ui.row({ gap = 6, align = "center" }, {
    ui.glyph({ name = glyph, size = (size or 11) + 1, color = color or "on_surface_variant" }),
    ui.label({ text = text, fontSize = size or 11, color = color or "on_surface_variant", maxLines = 1, flexGrow = 1 }),
  })
end

local function chip(glyph, text, extra)
  local kids = {
    ui.glyph({ name = glyph, size = 11, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 10, color = "on_surface_variant" }),
  }
  if extra then kids[#kids + 1] = extra end
  return ui.row({ gap = 4, align = "center", paddingH = 6, paddingV = 2, radius = 6, fill = "on_surface/0.06" }, kids)
end

local function action(glyph, tooltip, fn, variant)
  return ui.button({ glyph = glyph, tooltip = tooltip, variant = variant or "ghost", controlSize = "sm", onClick = fn })
end

-- Compact icon button for card actions.
local function cardAction(glyph, tooltip, fn, opts)
  opts = opts or {}
  return ui.button({ glyph = glyph, text = opts.text, tooltip = tooltip, variant = opts.variant or "ghost",
    controlSize = "sm", height = 24, width = 26, glyphSize = 13, fontSize = 11, onClick = fn })
end

-- ── Items (live + recent), in display order, for keyboard navigation ────────

local function multi() return #accounts > 1 end

local function liveGroups(account)
  local by = { waiting = {}, busy = {}, idle = {} }
  for _, s in ipairs(sessions) do
    if account == nil or s.account == account then
      local list = by[s.status] or by.idle
      list[#list + 1] = s
    end
  end
  return by
end

-- Sections in display order: one per account when there are several, else a single one.
local function sections()
  if not multi() then return { { account = nil, info = accounts[1] } } end
  local out = {}
  for _, a in ipairs(accounts) do out[#out + 1] = { account = a.dir, info = a } end
  return out
end

local function items()
  local out = {}
  for _, sec in ipairs(sections()) do
    if not (sec.account and collapsed[sec.account]) then
      local by = liveGroups(sec.account)
      for _, g in ipairs(GROUPS) do
        for _, s in ipairs(by[g.status]) do out[#out + 1] = { key = "live:" .. s.pid, live = s } end
      end
    end
  end
  if showRecent then
    for _, r in ipairs(recent) do out[#out + 1] = { key = "recent:" .. r.sessionId, recent = r } end
  end
  return out
end

local function activate(item)
  if item.live then shared.focus(item.live.pid) else shared.resume(item.recent.account, item.recent.cwd, item.recent.sessionId) end
  panel.close()
end

local function hoverHandler(key)
  return function(entered)
    local on = entered == true or entered == "true"
    hoverCount[key] = math.max(0, (hoverCount[key] or 0) + (on and 1 or -1))
    dirty = true
  end
end

local function hovered(key) return (hoverCount[key] or 0) > 0 end

-- The tree must be identical whether or not the card is hovered: adding/removing nodes under the
-- pointer makes the host send leave/enter again and the actions flicker. So the action buttons are
-- always laid out (on the folder line) and only fade in, and become clickable, when the card is active.
local function isActive(key) return hovered(key) or selected == key end

local function actionsRow(key, actions)
  local active = isActive(key)
  for _, a in ipairs(actions) do
    a.props.opacity = active and 1 or 0
    a.props.enabled = active
    a.props.onHover = hoverHandler(key)
  end
  return ui.row({ gap = 2, align = "center", height = 24 }, actions)
end

local function cardShell(key, status, main, onActivate)
  local active = isActive(key)
  local kids = { ui.row({ gap = 12, align = "start" }, main) }
  return ui.column({
    key = key, gap = 4, padding = 10, radius = 10,
    opacity = status == "idle" and not active and 0.7 or 1,
    fill = active and "on_surface/0.10" or "on_surface/0.04",
    border = status == "waiting" and "error/0.5" or (selected == key and "primary/0.6" or nil),
    borderWidth = (status == "waiting" or selected == key) and 1 or nil,
    onHover = hoverHandler(key),
    onClick = onActivate,
  }, kids)
end

local function badge(glyph, color)
  return ui.column({ width = 34, height = 34, radius = 9, fill = color .. "/0.15", align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = 18, color = color }),
  })
end

local function whereRow(cwd, branch, actions)
  local where = { ui.glyph({ name = "folder", size = 12, color = "on_surface_variant" }),
    ui.label({ text = shared.projectPath(cwd), fontSize = 11, color = "on_surface_variant", maxLines = 1 }) }
  if branch and branch ~= "HEAD" then
    where[#where + 1] = ui.glyph({ name = "git-branch", size = 12, color = "on_surface_variant" })
    where[#where + 1] = ui.label({ text = branch, fontSize = 11, color = "on_surface_variant", maxLines = 1 })
  end
  if actions then
    where[#where + 1] = ui.spacer({ flexGrow = 1 })
    where[#where + 1] = actions
  end
  return ui.row({ gap = 5, align = "center" }, where)
end

local function commonActions(account, cwd, sid)
  return {
    cardAction("terminal-2", "Open a shell here", function() shared.launch(cwd); panel.close() end),
    cardAction("folder-open", "Open in file manager", function() noctalia.runAsync({ "xdg-open", cwd }); panel.close() end),
    cardAction("copy", "Copy resume command", function()
      noctalia.copyToClipboard(shared.resumeCommand(account, cwd, sid), "text/plain")
      noctalia.notify("Copied", shared.resumeCommand(account, cwd, sid))
    end),
    cardAction("file-text", "Open transcript", function() noctalia.runAsync({ "xdg-open", shared.transcript(account, cwd, sid) }); panel.close() end),
  }
end

-- ── Live session card ───────────────────────────────────────────────────────

local function liveCard(s)
  local look = LOOK[s.status] or LOOK.idle
  local d = s.d or {}
  local key = "live:" .. s.pid
  local tool = d.tool and string.match(d.tool, "^([^:]+)") or nil
  local toolArg = d.tool and string.match(d.tool, "^[^:]+: (.*)$") or nil

  local body = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = d.title or s.name, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1, flexGrow = 1 }),
      ui.label({ text = s.since > 0 and shared.ago(s.since) or "", fontSize = 11, color = look.color }),
    }),
  }
  if s.status == "waiting" then
    body[#body + 1] = iconLine("alert-circle", s.waitingFor ~= "" and s.waitingFor or "Needs your input", "error", 12)
  elseif s.status == "busy" and tool then
    body[#body + 1] = iconLine(TOOL_GLYPH[tool] or "tool", tool .. (toolArg and toolArg ~= "" and ("  " .. toolArg) or ""), "primary", 12)
  end
  if d.todos then
    local t = d.todos
    body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "list-check", size = 12, color = "on_surface_variant" }),
      ui.label({ text = `{t.done}/{t.total}`, fontSize = 11, fontWeight = "bold", color = "on_surface" }),
      ui.progress({ progress = t.total > 0 and t.done / t.total or 0, width = 60, height = 4 }),
      ui.label({ text = t.current or "", fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
    })
  end
  if d.prompt and d.prompt ~= "" then body[#body + 1] = iconLine("message-circle", d.prompt) end

  local chips = {}
  chips[#chips + 1] = chip("terminal", s.terminal or "terminal")
  if d.model then chips[#chips + 1] = chip("cpu", d.model) end
  if d.mode then chips[#chips + 1] = chip(MODE_GLYPH[d.mode] or "shield", d.mode) end
  if d.context then
    local p = math.min(1, d.context / CTX)
    chips[#chips + 1] = chip("stack-2", tokens(d.context),
      ui.progress({ progress = p, width = 36, height = 4, fill = p > 0.8 and "error" or "primary" }))
  end
  if d.cost then chips[#chips + 1] = chip("coin", money(d.cost)) end
  if (d.agents or 0) > 0 then chips[#chips + 1] = chip("robot", tostring(d.agents)) end
  if s.status ~= "busy" and d.turnMs then chips[#chips + 1] = chip("clock", shared.dur(d.turnMs / 1000)) end
  if #chips > 0 then body[#body + 1] = ui.row({ gap = 4, align = "center" }, chips) end

  local actions = commonActions(s.account, s.cwd, s.sessionId)
  local armed = armedKill == s.pid and noctalia.nowMs() - armedAt < 3000
  actions[#actions + 1] = cardAction("power", "Stop this session (click twice)", function()
      if armed then
        noctalia.runAsync({ "kill", "-TERM", tostring(s.pid) })
        armedKill = nil
      else
        armedKill, armedAt = s.pid, noctalia.nowMs()
      end
      render()
    end, { text = armed and "Kill?" or nil, variant = armed and "destructive" or "ghost" })

  table.insert(body, 2, whereRow(s.cwd, d.branch, actionsRow(key, actions)))
  return cardShell(key, s.status, {
    badge(look.glyph, look.color),
    ui.column({ gap = 5, flexGrow = 1 }, body),
  }, function() shared.focus(s.pid); panel.close() end)
end

-- ── Recent (closed) session card ────────────────────────────────────────────

local function recentCard(r)
  local key = "recent:" .. r.sessionId
  local body = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = r.title ~= "" and r.title or r.prompt, fontSize = 12, fontWeight = "bold", color = "on_surface", maxLines = 1, flexGrow = 1 }),
      ui.label({ text = shared.ago(r.mtime), fontSize = 11, color = "on_surface_variant" }),
    }),
  }
  if r.title ~= "" and r.prompt ~= "" then body[#body + 1] = iconLine("message-circle", r.prompt) end
  if multi() then body[#body + 1] = ui.row({ gap = 4 }, { chip("user-circle", shared.accountLabel(r.account)) }) end
  local actions = commonActions(r.account, r.cwd, r.sessionId)
  table.insert(actions, 1, cardAction("player-play", "Resume", function() shared.resume(r.account, r.cwd, r.sessionId); panel.close() end))
  table.insert(body, 2, whereRow(r.cwd, nil, actionsRow(key, actions)))
  return cardShell(key, "idle", {
    badge("history", "secondary"),
    ui.column({ gap = 4, flexGrow = 1 }, body),
  }, function() shared.resume(r.account, r.cwd, r.sessionId); panel.close() end)
end

-- ── New-session picker ──────────────────────────────────────────────────────

local function picker()
  local seen, dirs = {}, {}
  local function addDir(d) if d and d ~= "" and not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end end
  for _, s in ipairs(sessions) do addDir(s.cwd) end
  for _, r in ipairs(recent) do addDir(r.cwd) end
  addDir(shared.workRoot())
  local rows = { ui.label({ text = "START CLAUDE IN…", fontSize = 10, fontWeight = "bold", color = "primary" }) }
  if multi() then
    pickAccount = pickAccount or accounts[1].dir
    local choices = { ui.label({ text = "Account", fontSize = 11, color = "on_surface_variant" }) }
    for _, a in ipairs(accounts) do
      choices[#choices + 1] = ui.button({ text = a.label, glyph = "user-circle", controlSize = "sm",
        variant = pickAccount == a.dir and "primary" or "ghost", tooltip = a.email or a.dir,
        onClick = function() pickAccount = a.dir; render() end })
    end
    rows[#rows + 1] = ui.row({ gap = 4, align = "center" }, choices)
  end
  for i, d in ipairs(dirs) do
    if i > 10 then break end
    rows[#rows + 1] = ui.row({
      key = "dir:" .. d, gap = 8, align = "center", paddingH = 8, paddingV = 6, radius = 8,
      fill = hovered("dir:" .. d) and "on_surface/0.10" or "on_surface/0.04",
      onHover = hoverHandler("dir:" .. d),
      onClick = function() shared.launch(d, shared.claudeArgv(multi() and pickAccount or nil)); panel.close() end,
    }, {
      ui.glyph({ name = "folder-plus", size = 14, color = "primary" }),
      ui.label({ text = shared.projectPath(d), fontSize = 12, color = "on_surface", maxLines = 1, flexGrow = 1 }),
    })
  end
  return ui.column({ gap = 4, padding = 10, radius = 10, fill = "primary/0.06", border = "primary/0.3", borderWidth = 1 }, rows)
end

-- ── Layout ──────────────────────────────────────────────────────────────────

local function sectionHeader(text, count, color, onClick, glyph)
  local kids = {}
  if glyph then kids[#kids + 1] = ui.glyph({ name = glyph, size = 12, color = color }) end
  kids[#kids + 1] = ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "bold", color = color })
  kids[#kids + 1] = ui.label({ text = tostring(count), fontSize = 10, color = "on_surface_variant" })
  kids[#kids + 1] = ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.2, flexGrow = 1 })
  return ui.row({ gap = 6, align = "center", paddingH = 2, paddingV = onClick and 4 or 0, onClick = onClick }, kids)
end

-- Plan usage windows (5h / 7d / Fable 7d), one meter each.
local function limitsStrip(limits)
  if not limits or #limits.windows == 0 then return nil end
  local meters = {}
  for _, w in ipairs(limits.windows) do
    local p = math.max(0, math.min(100, w.percent)) / 100
    local color = p >= 0.9 and "error" or p >= 0.7 and "secondary" or "primary"
    local mins = w.resetsAt and math.floor((w.resetsAt - noctalia.nowMs()) / 60000) or -1
    local left = mins >= 1440 and `{mins // 1440}d {mins % 1440 // 60}h` or mins >= 0 and `{mins // 60}h {mins % 60}m` or nil
    meters[#meters + 1] = ui.column({ gap = 3, flexGrow = 1 }, {
      ui.row({ gap = 4, align = "center" }, {
        ui.label({ text = w.label, fontSize = 11, fontWeight = "bold", color = "on_surface" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = `{math.floor(w.percent + 0.5)}%`, fontSize = 11, fontWeight = "bold", color = color }),
      }),
      ui.progress({ progress = p, height = 5, fill = color }),
      ui.label({ text = left and `resets in {left}` or "", fontSize = 10, color = "on_surface_variant" }),
    })
  end
  local age = limits.updated and (noctalia.nowMs() - limits.updated) or 0
  local strip = { ui.row({ gap = 14, align = "start" }, meters) }
  if age > 15 * 60000 then
    strip[#strip + 1] = iconLine("clock", `limits updated {shared.dur(age / 1000)} ago (refresh when a session redraws its status line)`)
  end
  return ui.column({ gap = 6, padding = 10, radius = 10, fill = "on_surface/0.04" }, strip)
end

local function countPills(by)
  local pills = {}
  for _, g in ipairs(GROUPS) do
    if #by[g.status] > 0 then
      pills[#pills + 1] = ui.row({ gap = 4, align = "center", paddingH = 8, paddingV = 3, radius = 10, fill = g.color .. "/0.15" }, {
        ui.glyph({ name = g.glyph, size = 12, color = g.color }),
        ui.label({ text = tostring(#by[g.status]), fontSize = 11, fontWeight = "bold", color = g.color }),
      })
    end
  end
  return pills
end

local function accountHeader(a, by)
  local folded = collapsed[a.dir]
  local kids = {
    ui.glyph({ name = folded and "chevron-right" or "chevron-down", size = 14, color = "on_surface_variant" }),
    ui.row({ width = 26, height = 26, radius = 13, fill = "secondary/0.18", align = "center", justify = "center" }, {
      ui.glyph({ name = "user-circle", size = 16, color = "secondary" }),
    }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = a.label, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ text = a.email or a.dir, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
    }),
  }
  for _, p in ipairs(countPills(by)) do kids[#kids + 1] = p end
  return ui.row({ key = "acct:" .. a.dir, gap = 8, align = "center", paddingH = 4, paddingV = 4,
    onClick = function() collapsed[a.dir] = not collapsed[a.dir]; render() end }, kids)
end

local function countPill(g, n)
  return ui.row({ gap = 4, align = "center", paddingH = 8, paddingV = 3, radius = 10, fill = g.color .. "/0.15" }, {
    ui.glyph({ name = g.glyph, size = 12, color = g.color }),
    ui.label({ text = tostring(n), fontSize = 11, fontWeight = "bold", color = g.color }),
  })
end

function render()
  local by = liveGroups()
  local total = 0
  for _, s in ipairs(sessions) do total += (s.d and s.d.cost or 0) end

  local header = {
    ui.row({ width = 28, height = 28, radius = 8, fill = "primary/0.15", align = "center", justify = "center" }, {
      ui.glyph({ name = "brain", size = 16, color = "primary" }),
    }),
    ui.column({ gap = 0 }, {
      ui.label({ text = "Claude Sessions", fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = total > 0 and `{money(total)} across live sessions` or "", fontSize = 10, color = "on_surface_variant",
        visible = total > 0 }),
    }),
    ui.spacer({ flexGrow = 1 }),
  }
  for _, g in ipairs(GROUPS) do
    if #by[g.status] > 0 then header[#header + 1] = countPill(g, #by[g.status]) end
  end
  header[#header + 1] = action(showPicker and "x" or "plus", "New session (n)", function() showPicker = not showPicker; render() end,
    showPicker and "secondary" or "ghost")
  header[#header + 1] = action("x", "Close", function() panel.close() end)

  local content = {}
  if showPicker then content[#content + 1] = picker() end
  for _, sec in ipairs(sections()) do
    local secBy = liveGroups(sec.account)
    if sec.account then content[#content + 1] = accountHeader(sec.info, secBy) end
    if not (sec.account and collapsed[sec.account]) then
      local strip = limitsStrip(sec.info and sec.info.limits)
      if strip then content[#content + 1] = strip end
      local any = false
      for _, g in ipairs(GROUPS) do
        local list = secBy[g.status]
        if #list > 0 then
          any = true
          content[#content + 1] = sectionHeader(g.title, #list, g.color)
          for _, s in ipairs(list) do content[#content + 1] = liveCard(s) end
        end
      end
      if sec.account and not any then
        content[#content + 1] = iconLine("moon", "No sessions running", "on_surface_variant")
      end
    end
  end
  if #sessions == 0 and not multi() then
    content[#content + 1] = ui.column({ gap = 8, align = "center", justify = "center", paddingV = 40 }, {
      ui.glyph({ name = "moon", size = 36, color = "on_surface_variant" }),
      ui.label({ text = "No Claude sessions running", color = "on_surface_variant" }),
    })
  end
  if #recent > 0 then
    content[#content + 1] = sectionHeader("Recent", #recent, "on_surface_variant",
      function() showRecent = not showRecent; render() end, showRecent and "chevron-down" or "chevron-right")
    if showRecent then
      for _, r in ipairs(recent) do content[#content + 1] = recentCard(r) end
    end
  end

  panel.render(ui.column({ gap = 10, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, header),
    ui.scroll({ flexGrow = 1, gap = 8 }, content),
    ui.row({ gap = 12, align = "center" }, {
      iconLine("pointer", "Click to jump (kitty: exact tab)"),
      iconLine("keyboard", "↑↓ ⏎ · 1-9"),
      iconLine("plus", "n new"),
      iconLine("history", "r recent"),
    }),
  }))
end

function onKey(chord, pressed)
  if not pressed then return end
  local list = items()
  if chord == "n" then showPicker = not showPicker
  elseif chord == "r" then showRecent = not showRecent
  elseif chord == "up" or chord == "down" then
    local idx = 0
    for i, it in ipairs(list) do if it.key == selected then idx = i end end
    idx = chord == "down" and math.min(#list, idx + 1) or math.max(1, idx - 1)
    selected = list[idx] and list[idx].key or nil
  elseif chord == "Return" then
    for _, it in ipairs(list) do if it.key == selected then activate(it) return end end
  else
    local n = tonumber(chord)
    if n and list[n] then activate(list[n]) return end
  end
  render()
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("recent", function(v) recent = v or {}; render() end)
noctalia.state.watch("accounts", function(v) accounts = v or {}; render() end)
function onOpen(_ctx)
  sessions = noctalia.state.get("sessions") or {}
  recent = noctalia.state.get("recent") or {}
  accounts = noctalia.state.get("accounts") or {}
  hoverCount, selected, showPicker, armedKill = {}, nil, false, nil
  noctalia.state.set("command", { action = "refresh", at = noctalia.nowMs() })
  panel.setWantsSecondTicks(true)
  panel.setNeedsFrameTick(true)
  render()
end
function onClose() panel.setWantsSecondTicks(false); panel.setNeedsFrameTick(false) end
function onFrameTick(_deltaMs)
  if dirty then dirty = false; render() end
end
function update() render() end
render()
