--!nonstrict
-- Live tab: plan limits, then every running session grouped by what it needs from
-- you, Remote Control sessions on other machines, and recently closed sessions to
-- resume. Click a card to jump to its terminal; hover (or select) it for actions.
-- Card design from claude-sessions (lfdominguez, MIT).
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local M = {}
M.nav = kit.nav()

local GROUPS = {
  { status = "waiting", title = "Needs you", pill = "need you", glyph = "bell-ringing", color = "error" },
  { status = "busy", title = "Working", pill = "working", glyph = "loader-2", color = "primary" },
  { status = "idle", title = "Idle", pill = "idle", glyph = "circle-check", color = "on_surface_variant" },
}
local LOOK = {}
for _, g in ipairs(GROUPS) do LOOK[g.status] = g end

local TOOL_GLYPH = {
  Bash = "terminal-2", Edit = "pencil", Write = "file-plus", Read = "file-text", NotebookEdit = "notebook",
  Grep = "search", Glob = "folder-search", Agent = "robot", Task = "robot", WebFetch = "world",
  WebSearch = "world-search", TodoWrite = "list-check", Skill = "sparkles", AskUserQuestion = "help-circle",
}
local MODE_GLYPH = { auto = "bolt", plan = "map", default = "shield-check", acceptEdits = "pencil-check", bypassPermissions = "alert-triangle" }

-- Only the innermost hovered node reports, so a card and its buttons each report for the
-- same key; counting them keeps the card active while the pointer moves between them.
local hoverCount = {}
local showRecent, showPicker = false, false
local expanded = {} -- card key -> true while its last-reply preview is open
local armedKill, armedAt = nil, 0 -- stopping a session takes a second click within 3 s

function M.opened()
  hoverCount, showPicker, armedKill = {}, false, nil
end

-- Lamps of sessions that need you blink with the panel's second tick.
local function blinkOff() return os.time() % 2 == 1 end

local function hoverHandler(ctx, key)
  return function(entered)
    local on = entered == true or entered == "true"
    hoverCount[key] = math.max(0, (hoverCount[key] or 0) + (on and 1 or -1))
    ctx.markDirty()
  end
end

-- The tree must not change shape on hover (adding nodes under the pointer re-fires
-- enter/leave and the actions flicker), so actions are always laid out and only fade in.
local function isActive(key) return (hoverCount[key] or 0) > 0 or M.nav:selectedKey() == key end

local function cardAction(glyph, tooltip, fn, opts)
  opts = opts or {}
  return ui.button({ glyph = glyph, text = opts.text, tooltip = tooltip, variant = opts.variant or "ghost",
    controlSize = "sm", height = 24, width = opts.text and nil or 26, glyphSize = 13, fontSize = 11, onClick = fn })
end

local function actionsRow(ctx, key, actions)
  local active = isActive(key)
  for _, a in ipairs(actions) do
    a.props.opacity = active and 1 or 0
    a.props.enabled = active
    a.props.onHover = hoverHandler(ctx, key)
  end
  return ui.row({ gap = 2, align = "center", height = 24 }, actions)
end

local LAMP = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.5", remote = "secondary", recent = "on_surface/0.18" }

-- A card is a line on the board: a lamp down its left edge (blinking while it needs
-- you), then its body. Every prop is set on every render: the host keeps a prop that a
-- later render leaves out.
local function cardShell(ctx, key, status, body, onActivate)
  local active = isActive(key)
  local selected = M.nav:selectedKey() == key
  local waiting = status == "waiting"
  return ui.row({
    key = key, gap = 10, padding = 10, radius = 10, align = "stretch",
    opacity = (status == "idle" or status == "recent") and not active and 0.75 or 1,
    fill = waiting and "error/0.07" or active and "on_surface/0.10" or "on_surface/0.04",
    border = waiting and "error/0.5" or selected and "primary/0.6" or "#00000000",
    borderWidth = (waiting or selected) and 1 or 0,
    onHover = hoverHandler(ctx, key),
    onClick = onActivate,
  }, {
    ui.box({ width = 4, radius = 2, fill = LAMP[status] or LAMP.idle, opacity = waiting and blinkOff() and 0.3 or 1 }),
    ui.column({ gap = 5, flexGrow = 1 }, body),
  })
end

local function titleRow(ctx, key, line, title, age, ageColor, previewable)
  local kids = {}
  if line then kids[#kids + 1] = ui.label({ text = line, fontSize = 10, fontWeight = "bold", color = "on_surface_variant" }) end
  kids[#kids + 1] = ui.label({ text = title, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1 })
  kids[#kids + 1] = ui.label({ text = age, fontSize = 11, color = ageColor })
  if previewable then
    kids[#kids + 1] = ui.button({ glyph = expanded[key] and "chevron-up" or "chevron-down", variant = "ghost",
      controlSize = "sm", height = 22, width = 24, glyphSize = 13,
      tooltip = expanded[key] and "Hide Claude's last reply" or "Show Claude's last reply",
      onHover = hoverHandler(ctx, key),
      onClick = function() expanded[key] = not expanded[key] or nil; ctx.render() end })
  end
  return ui.row({ gap = 8, align = "center" }, kids)
end

-- Claude's last reply, and the questions of a pending AskUserQuestion.
local function preview(s, d)
  local rows = {}
  if s.status == "waiting" and type(d.question) == "table" then
    for _, q in ipairs(d.question) do
      rows[#rows + 1] = ui.label({ text = q.question or "", fontSize = 12, fontWeight = "bold", color = "error", maxLines = 3 })
      if type(q.options) == "table" and #q.options > 0 then
        rows[#rows + 1] = kit.muted(table.concat(q.options, "  ·  "), 11, { maxLines = 2 })
      end
    end
  end
  if d.reply and d.reply ~= "" then
    rows[#rows + 1] = ui.markdown({ text = d.reply .. (d.replyCut and "\n\n*…cut short; open the transcript for the rest*" or "") })
  end
  if #rows == 0 then rows[1] = kit.muted("No reply yet", 11) end
  -- Its own (empty) click target, so reading or clicking the reply does not jump away.
  return ui.column({ gap = 6, padding = 10, radius = 8, fill = "on_surface/0.05", onClick = function() end }, rows)
end

local function whereRow(cwd, branch, actions)
  local where = { ui.glyph({ name = "folder", size = 12, color = "on_surface_variant" }),
    ui.label({ text = shared.projectPath(cwd), fontSize = 11, color = "on_surface_variant", maxLines = 1 }) }
  if branch then
    where[#where + 1] = ui.glyph({ name = "git-branch", size = 12, color = "on_surface_variant" })
    where[#where + 1] = ui.label({ text = branch, fontSize = 11, color = "on_surface_variant", maxLines = 1 })
  end
  where[#where + 1] = ui.spacer({ flexGrow = 1 })
  where[#where + 1] = actions
  return ui.row({ gap = 5, align = "center" }, where)
end

-- transcript: the path the service resolved (a session that moved dirs is filed under
-- the dir it started in); the encoded cwd is only a fallback.
local function commonActions(ctx, account, cwd, sid, transcript)
  return {
    cardAction("terminal-2", "Open a shell here", function() shared.launch(cwd); ctx.close() end),
    cardAction("folder-open", "Open in file manager", function() shared.open(cwd); ctx.close() end),
    cardAction("copy", "Copy resume command", function()
      noctalia.copyToClipboard(shared.resumeCommand(account, cwd, sid), "text/plain")
      noctalia.notify("Copied", shared.resumeCommand(account, cwd, sid))
    end),
    cardAction("file-text", "Open transcript", function() shared.open(transcript or shared.transcript(account, cwd, sid)); ctx.close() end),
  }
end

local function contextChip(used, max)
  local p = math.min(1, used / (max or 200000))
  return kit.chip("stack-2", shared.tokens(used), ui.progress({ progress = p, width = 36, height = 4,
    fill = p >= 0.9 and "error" or p >= 0.7 and "tertiary" or "primary", track = "on_surface/0.14" }))
end

-- ── Cards ───────────────────────────────────────────────────────────────────

local function liveCard(ctx, s, key, line)
  local look = LOOK[s.status] or LOOK.idle
  local d = s.d or {}
  local tool = d.tool and string.match(d.tool, "^([^:]+)") or nil
  local toolArg = d.tool and string.match(d.tool, "^[^:]+: (.*)$") or nil

  local body = {
    titleRow(ctx, key, line, d.title or s.name, s.since > 0 and shared.ago(s.since) or "", look.color, true),
  }
  if s.status == "waiting" then
    body[#body + 1] = kit.iconLine("alert-circle", s.waitingFor ~= "" and s.waitingFor or "Needs your input", "error", 12)
  elseif s.status == "busy" and tool then
    body[#body + 1] = kit.iconLine(TOOL_GLYPH[tool] or "tool", tool .. (toolArg and toolArg ~= "" and ("  " .. toolArg) or ""), "primary", 12)
  end
  if d.todos then
    local t = d.todos
    body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = "list-check", size = 12, color = "on_surface_variant" }),
      ui.label({ text = `{t.done}/{t.total}`, fontSize = 11, fontWeight = "bold" }),
      ui.progress({ progress = t.total > 0 and t.done / t.total or 0, width = 60, height = 4 }),
      ui.label({ text = t.current or "", fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
    })
  end
  if d.prompt and d.prompt ~= "" then body[#body + 1] = kit.iconLine("message-circle", d.prompt) end

  local chips = { kit.chip("terminal", s.terminal or "terminal") }
  if s.remote then chips[#chips + 1] = kit.chip("device-mobile", "remote") end
  if d.model then chips[#chips + 1] = kit.chip("cpu", d.model) end
  if d.mode then chips[#chips + 1] = kit.chip(MODE_GLYPH[d.mode] or "shield", d.mode) end
  if d.context then chips[#chips + 1] = contextChip(d.context, d.contextMax) end
  if d.cost then chips[#chips + 1] = kit.chip("coin", shared.money(d.cost, ctx.rates())) end
  if (d.agents or 0) > 0 then chips[#chips + 1] = kit.chip("robot", tostring(d.agents)) end
  -- Claude sessions running inside this one (e.g. a hook's Agent SDK review).
  if (s.helpers or 0) > 0 then chips[#chips + 1] = kit.chip("git-fork", s.helpers == 1 and "1 helper" or `{s.helpers} helpers`) end
  if s.status ~= "busy" and d.turnMs then chips[#chips + 1] = kit.chip("clock", shared.dur(d.turnMs / 1000)) end
  body[#body + 1] = ui.row({ gap = 4, align = "center" }, chips)
  body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
    kit.timeline(s.timeline, 4),
    kit.muted("last hour", 9),
  })
  if expanded[key] then body[#body + 1] = preview(s, d) end

  local actions = commonActions(ctx, s.account, s.cwd, s.sessionId, s.transcript)
  if s.remote then
    table.insert(actions, 1, cardAction("external-link", "Open on claude.ai (Remote Control)", function()
      shared.open(s.remote); ctx.close()
    end))
  end
  local armed = armedKill == s.pid and noctalia.nowMs() - armedAt < 3000
  actions[#actions + 1] = cardAction("power", armed and "Click again to stop" or "Stop this session", function()
    if armed then
      noctalia.runAsync({ "kill", "-TERM", tostring(s.pid) })
      armedKill = nil
    else
      armedKill, armedAt = s.pid, noctalia.nowMs()
    end
    ctx.render()
  end, { text = armed and "Stop?" or nil, variant = armed and "destructive" or "ghost" })

  table.insert(body, 2, whereRow(s.cwd, d.branch, actionsRow(ctx, key, actions)))
  return cardShell(ctx, key, s.status, body, function() shared.focus(s); ctx.close() end)
end

local function remoteCard(ctx, r, key)
  local waiting = r.category == "need_input"
  local function open() shared.open(r.url); ctx.close() end
  local body = {
    titleRow(ctx, key, nil, r.title, r.since > 0 and shared.ago(r.since) or "", waiting and "error" or "secondary", false),
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "world", size = 12, color = "on_surface_variant" }),
      ui.label({ text = r.branch and `elsewhere · {r.branch}` or "elsewhere", fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
      ui.spacer({ flexGrow = 1 }),
      actionsRow(ctx, key, {
        cardAction("external-link", "Open on claude.ai", open),
        cardAction("copy", "Copy link", function()
          noctalia.copyToClipboard(r.url, "text/plain")
          noctalia.notify("Copied", r.url)
        end),
      }),
    }),
  }
  if waiting then
    body[#body + 1] = kit.iconLine("alert-circle", r.needs ~= "" and r.needs or "Needs your input", "error", 12)
  elseif (r.detail or "") ~= "" then
    body[#body + 1] = kit.iconLine("info-circle", r.detail)
  end
  local chips = { kit.chip("device-mobile", "remote") }
  if r.model then chips[#chips + 1] = kit.chip("cpu", r.model) end
  if r.mode then chips[#chips + 1] = kit.chip(MODE_GLYPH[r.mode] or "shield", r.mode) end
  if r.context then chips[#chips + 1] = contextChip(r.context, r.maxContext) end
  body[#body + 1] = ui.row({ gap = 4, align = "center" }, chips)
  return cardShell(ctx, key, waiting and "waiting" or "remote", body, open)
end

local function recentCard(ctx, r, key)
  local function resume() shared.resume(r.account, r.cwd, r.sessionId); ctx.close() end
  local body = {
    titleRow(ctx, key, nil, r.title ~= "" and r.title or r.prompt, shared.ago(r.mtime), "on_surface_variant", false),
  }
  local actions = commonActions(ctx, r.account, r.cwd, r.sessionId, r.transcript)
  table.insert(actions, 1, cardAction("player-play", "Resume", resume))
  body[#body + 1] = whereRow(r.cwd, nil, actionsRow(ctx, key, actions))
  if r.title ~= "" and r.prompt ~= "" then body[#body + 1] = kit.iconLine("message-circle", r.prompt) end
  if shared.multiAccount(ctx.S.accounts) then body[#body + 1] = ui.row({ gap = 4 }, { kit.chip("user-circle", shared.accountLabel(ctx.S.accounts, r.account)) }) end
  return cardShell(ctx, key, "recent", body, resume)
end

-- ── Sections ────────────────────────────────────────────────────────────────

local function sectionHeader(text, count, color, onClick, glyph)
  local kids = {}
  if glyph then kids[#kids + 1] = ui.glyph({ name = glyph, size = 12, color = color }) end
  kids[#kids + 1] = ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "bold", color = color })
  kids[#kids + 1] = ui.label({ text = tostring(count), fontSize = 10, color = "on_surface_variant" })
  kids[#kids + 1] = ui.separator({ orientation = "horizontal", color = "outline_variant", opacity = 0.5, flexGrow = 1 })
  return ui.row({ gap = 6, align = "center", paddingH = 2, paddingV = onClick and 4 or 0, onClick = onClick }, kids)
end

-- One meter per plan window: used and projected, and where it is heading. Click the
-- strip for the full picture on the Usage tab.
local function limitsStrip(ctx, limits)
  if not limits or #(limits.windows or {}) == 0 then return nil end
  local meters = {}
  for _, w in ipairs(limits.windows) do
    local p = shared.pace(w)
    local color = shared.paceColor(p.status, "primary")
    meters[#meters + 1] = ui.column({ gap = 4, flexGrow = 1 }, {
      ui.row({ gap = 4, align = "center" }, {
        ui.label({ text = w.label, fontSize = 11, fontWeight = "bold" }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 12, fontWeight = "bold", color = color }),
      }),
      kit.paceBar(p, color, 5),
      ui.label({ text = shared.paceShort(w, p), fontSize = 10, maxLines = 1,
        color = color == "primary" and "on_surface_variant" or color }),
    })
  end
  local strip = { ui.row({ gap = 16, align = "start" }, meters) }
  if limits.stale then
    strip[#strip + 1] = kit.iconLine("clock-exclamation",
      `limits from {shared.ago(limits.updated)} ago` .. (limits.error and ` · {limits.error}` or ""), "tertiary")
  end
  return ui.column({ key = "limits-strip", gap = 6, padding = 10, radius = 10, fill = "on_surface/0.04",
    opacity = limits.stale and 0.75 or 1, tooltip = "Open Usage for details", onClick = function() ctx.setTab("usage") end }, strip)
end

local function countPill(g, n)
  return ui.row({ gap = 5, align = "center", paddingH = 9, paddingV = 4, radius = 10, fill = g.color .. "/0.14" }, {
    ui.glyph({ name = g.glyph, size = 12, color = g.color }),
    ui.label({ text = `{n} {g.pill}`, fontSize = 11, fontWeight = "bold", color = g.color }),
  })
end

local function picker(ctx)
  local seen, dirs, pinnedDir = {}, {}, {}
  local function add(d) if d and d ~= "" and not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end end
  -- Pinned projects first (pin them from the Sessions tab), then where you worked last.
  for _, p in ipairs(type(ctx.S.pins) == "table" and ctx.S.pins or {}) do pinnedDir[p] = true; add(p) end
  for _, s in ipairs(ctx.S.sessions) do add(s.cwd) end
  for _, r in ipairs(ctx.S.recent) do add(r.cwd) end
  add(shared.workRoot())
  local rows = { ui.label({ text = "START CLAUDE IN…", fontSize = 10, fontWeight = "bold", color = "primary" }) }
  for i, d in ipairs(dirs) do
    if i > 10 then break end
    local key = "dir:" .. d
    rows[#rows + 1] = ui.row({
      key = key, gap = 8, align = "center", paddingH = 8, paddingV = 6, radius = 8,
      fill = (hoverCount[key] or 0) > 0 and "on_surface/0.10" or "on_surface/0.04",
      onHover = hoverHandler(ctx, key),
      onClick = function() shared.launch(d, shared.claudeArgv(nil)); ctx.close() end,
    }, {
      ui.glyph({ name = pinnedDir[d] and "pinned" or "folder-plus", size = 14, color = "primary" }),
      ui.label({ text = shared.projectPath(d), fontSize = 12, maxLines = 1, flexGrow = 1 }),
    })
  end
  return ui.column({ gap = 4, padding = 10, radius = 10, fill = "primary/0.06", border = "primary/0.3", borderWidth = 1 }, rows)
end

function M.render(ctx)
  local S = ctx.S
  M.nav:begin()
  local by = { waiting = {}, busy = {}, idle = {} }
  for _, s in ipairs(S.sessions) do table.insert(by[s.status] or by.idle, s) end

  local toolbar = {}
  for _, g in ipairs(GROUPS) do
    if #by[g.status] > 0 then toolbar[#toolbar + 1] = countPill(g, #by[g.status]) end
  end
  toolbar[#toolbar + 1] = ui.spacer({ flexGrow = 1 })
  toolbar[#toolbar + 1] = ui.button({ glyph = showPicker and "x" or "plus", text = "New session", variant = showPicker and "secondary" or "ghost",
    controlSize = "sm", onClick = function() showPicker = not showPicker; ctx.render() end })

  local content = {}
  if showPicker then content[#content + 1] = picker(ctx) end
  local strip = limitsStrip(ctx, S.accounts[1] and S.accounts[1].limits)
  if strip then content[#content + 1] = strip end

  local lineNo = 0
  for _, g in ipairs(GROUPS) do
    if #by[g.status] > 0 then
      content[#content + 1] = sectionHeader(g.title, #by[g.status], g.color)
      for _, s in ipairs(by[g.status]) do
        local key = "live:" .. s.pid
        M.nav:add(key, function() shared.focus(s); ctx.close() end)
        lineNo += 1
        content[#content + 1] = liveCard(ctx, s, key, `L{lineNo}`)
      end
    end
  end
  if #S.elsewhere > 0 then
    content[#content + 1] = sectionHeader("Elsewhere", #S.elsewhere, "secondary", nil, "world")
    for _, r in ipairs(S.elsewhere) do
      local key = "remote:" .. r.id
      M.nav:add(key, function() shared.open(r.url); ctx.close() end)
      content[#content + 1] = remoteCard(ctx, r, key)
    end
  end
  if #S.sessions == 0 and #S.elsewhere == 0 then
    content[#content + 1] = kit.notice("moon", "No Claude sessions running")
  end
  if #S.recent > 0 then
    content[#content + 1] = sectionHeader("Recent", #S.recent, "on_surface_variant",
      function() showRecent = not showRecent; ctx.render() end, showRecent and "chevron-down" or "chevron-right")
    if showRecent then
      for _, r in ipairs(S.recent) do
        local key = "recent:" .. r.sessionId
        M.nav:add(key, function() shared.resume(r.account, r.cwd, r.sessionId); ctx.close() end)
        content[#content + 1] = recentCard(ctx, r, key)
      end
    end
  end

  return ui.column({ gap = 10, flexGrow = 1 }, {
    ui.row({ gap = 6, align = "center" }, toolbar),
    ui.scroll({ key = "live-scroll", flexGrow = 1, gap = 8, revealKey = M.nav.reveal }, content),
    ui.row({ gap = 12, align = "center" }, {
      kit.iconLine("pointer", "Click a card to jump to it · hover or select it for actions"),
      kit.iconLine("keyboard", "↑↓ ⏎"),
    }),
  })
end

return M
