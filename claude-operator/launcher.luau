--!nonstrict
-- /co launcher provider: live sessions first (activate = jump to the terminal), then
-- Remote Control sessions elsewhere (open on claude.ai), then recent ones (resume). Once
-- you type, every saved session in the service's index is searched too (resume).
-- Ported from claude-sessions (lfdominguez, MIT).
local shared = require("./shared.luau")
local GLYPH = { waiting = "bell-ringing", busy = "loader-2", idle = "circle-check" }
local byId = {}

-- Copies of the service's state, kept current by watches: onQuery runs on every
-- keystroke, and a state.get copies the whole value (the index is ~190 KB) each time.
local S = {}
for _, k in ipairs({ "sessions", "elsewhere", "recent", "accounts", "index" }) do
  S[k] = noctalia.state.get(k) or {}
  noctalia.state.watch(k, function(v) S[k] = v or {} end)
end

function onQuery(text)
  local q = noctalia.string.trim(text or "")
  local results = {}
  byId = {}
  local function add(id, entry, title, subtitle, glyph, base)
    local score = base
    if q ~= "" then
      local s = noctalia.fuzzyScore(q, title .. " " .. subtitle)
      if not s then return end
      score = base + s
    end
    byId[id] = entry
    results[#results + 1] = { id = id, title = title, subtitle = subtitle, glyph = glyph, score = score }
  end
  local multi = shared.multiAccount(S.accounts)
  local function acct(dir) return multi and (shared.accountLabel(S.accounts, dir) .. " · ") or "" end
  for _, s in ipairs(S.sessions) do
    local d = s.d or {}
    add("live:" .. s.pid, s, d.title or s.name,
      `{acct(s.account)}{s.status}{s.remote and " · remote" or ""} · {shared.projectPath(s.cwd)}`, GLYPH[s.status] or "headset", 1000)
  end
  for _, r in ipairs(S.elsewhere) do
    add("remote:" .. r.id, r, r.title, `{acct(r.account)}{r.category == "need_input" and "waiting" or "remote"} · elsewhere`,
      r.category == "need_input" and "bell-ringing" or "world", 900)
  end
  local listed = {}
  for _, r in ipairs(S.recent) do
    listed[r.sessionId] = true
    add("recent:" .. r.sessionId, r, r.title ~= "" and r.title or r.prompt,
      `{acct(r.account)}resume · {shared.projectPath(r.cwd)} · {shared.ago(r.mtime)} ago`, "history", 0)
  end
  if q ~= "" then
    for _, s in ipairs(S.sessions) do listed[s.sessionId] = true end
    for _, x in ipairs(S.index) do
      if not listed[x.id] and not x.empty and x.cwd ~= "" then
        local title = x.title ~= "" and x.title or x.prompt
        add("saved:" .. x.id, { account = x.account, cwd = x.cwd, sessionId = x.id }, title,
          `{acct(x.account)}resume · {shared.projectPath(x.cwd)} · {shared.ago(x.mtime)} ago`, "archive", -100)
      end
    end
  end
  launcher.setResults(text, results)
end

function onActivate(id)
  local e = byId[id]
  if not e then return end
  if string.sub(id, 1, 7) == "remote:" then shared.open(e.url)
  elseif string.sub(id, 1, 5) == "live:" then shared.focus(e)
  else shared.resume(e.account, e.cwd, e.sessionId) end
end
