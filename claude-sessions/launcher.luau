--!nonstrict
local shared = require("./shared.luau")
local GLYPH = { waiting = "bell-ringing", busy = "loader-2", idle = "circle-check" }
local byId = {}

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
  local multi = shared.multiAccount()
  local function acct(dir) return multi and (shared.accountLabel(dir) .. " · ") or "" end
  for _, s in ipairs(noctalia.state.get("sessions") or {}) do
    local d = s.d or {}
    add("live:" .. s.pid, s, d.title or s.name, `{acct(s.account)}{s.status}{s.remote and " · remote" or ""} · {shared.projectPath(s.cwd)}`, GLYPH[s.status] or "brain", 1000)
  end
  for _, r in ipairs(noctalia.state.get("elsewhere") or {}) do
    add("remote:" .. r.id, r, r.title, `{acct(r.account)}{r.category == "need_input" and "waiting" or "remote"} · elsewhere`,
      r.category == "need_input" and "bell-ringing" or "world", 900)
  end
  for _, r in ipairs(noctalia.state.get("recent") or {}) do
    add("recent:" .. r.sessionId, r, r.title ~= "" and r.title or r.prompt,
      `{acct(r.account)}resume · {shared.projectPath(r.cwd)} · {shared.ago(r.mtime)} ago`, "history", 0)
  end
  launcher.setResults(text, results)
end

function onActivate(id)
  local e = byId[id]
  if not e then return end
  if string.sub(id, 1, 7) == "remote:" then noctalia.runAsync({ "xdg-open", e.url })
  elseif string.sub(id, 1, 5) == "live:" then shared.focus(e) else shared.resume(e.account, e.cwd, e.sessionId) end
end
