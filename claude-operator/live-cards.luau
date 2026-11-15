--!nonstrict
-- The Live tab's cards: a running session, a Remote Control session elsewhere and a
-- recently closed one, each a line on the board with its lamp, chips and actions. Also
-- the board's interaction state the cards and the tab share: the hover counts, the
-- keyboard selection (`nav`), the open reply previews and the armed stop button.
-- Card design from claude-sessions (lfdominguez, MIT).
local shared = require("./shared.luau")
local actions = require("./actions.luau")
local kit = require("./kit.luau")
local M = {}
M.nav = kit.nav()

M.GROUPS = {
  { status = "waiting", title = "Needs you", pill = "need you", glyph = "bell-ringing", color = "error" },
  { status = "busy", title = "Working", pill = "working", glyph = "loader-2", color = "primary" },
  { status = "idle", title = "Idle", pill = "idle", glyph = "circle-check", color = "on_surface_variant" },
}
local LOOK = {}
for _, g in ipairs(M.GROUPS) do LOOK[g.status] = g end

local TOOL_GLYPH = {
  Bash = "terminal-2", Edit = "pencil", Write = "file-plus", Read = "file-text", NotebookEdit = "notebook",
  Grep = "search", Glob = "folder-search", Agent = "robot", Task = "robot", WebFetch = "world",
  WebSearch = "world-search", TodoWrite = "list-check", Skill = "sparkles", AskUserQuestion = "help-circle",
}
local MODE_GLYPH = { auto = "bolt", plan = "map", default = "shield-check", acceptEdits = "pencil-check", bypassPermissions = "alert-triangle" }

-- Only the innermost hovered node reports, so a card and its buttons each report for the
-- same key; counting them keeps the card active while the pointer moves between them.
local hoverCount = {}
local expanded = {} -- card key -> true while its last-reply preview is open
local armedKill, armedAt = nil, 0 -- stopping a session takes a second click within 3 s

-- The panel opened: nothing is hovered or armed any more.
function M.opened()
  hoverCount, armedKill = {}, nil
end

-- Lamps of sessions that need you blink with the panel's second tick.
local function blinkOff() return os.time() % 2 == 1 end

function M.hoverHandler(ctx, key)
  return function(entered)
    local on = entered == true or entered == "true"
    hoverCount[key] = math.max(0, (hoverCount[key] or 0) + (on and 1 or -1))
    ctx.markDirty()
  end
end

-- For rows that hover but are never selected, such as the picker's.
function M.hovering(key) return (hoverCount[key] or 0) > 0 end

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
    a.props.onHover = M.hoverHandler(ctx, key)
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
    onHover = M.hoverHandler(ctx, key),
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
      onHover = M.hoverHandler(ctx, key),
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
    cardAction("terminal-2", "Open a shell here", function() actions.launch(cwd); ctx.close() end),
    cardAction("folder-open", "Open in file manager", function() actions.open(cwd); ctx.close() end),
    cardAction("copy", "Copy resume command", function()
      noctalia.copyToClipboard(actions.resumeCommand(account, cwd, sid), "text/plain")
      noctalia.notify("Copied", actions.resumeCommand(account, cwd, sid))
    end),
    cardAction("file-text", "Open transcript", function() actions.open(transcript or shared.transcript(account, cwd, sid)); ctx.close() end),
  }
end

local function contextChip(used, max)
  local p = math.min(1, used / (max or 200000))
  return kit.chip("stack-2", shared.tokens(used), ui.progress({ progress = p, width = 36, height = 4,
    fill = p >= 0.9 and "error" or p >= 0.7 and "tertiary" or "primary", track = "on_surface/0.14" }))
end

-- ── Cards ───────────────────────────────────────────────────────────────────

function M.liveCard(ctx, s, key, line)
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
      actions.open(s.remote); ctx.close()
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
  return cardShell(ctx, key, s.status, body, function() actions.focus(s); ctx.close() end)
end

function M.remoteCard(ctx, r, key)
  local waiting = r.category == "need_input"
  local function open() actions.open(r.url); ctx.close() end
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

function M.recentCard(ctx, r, key)
  local function resume() actions.resume(r.account, r.cwd, r.sessionId); ctx.close() end
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

return M
