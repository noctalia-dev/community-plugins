--!nonstrict
-- Shared helpers for every entry: state keys, countdown text, urgency colors,
-- category names, and opening links.

local M = {}

M.STATE_KEY = "ccfddl.state"
M.REQUEST_KEY = "ccfddl.request"
M.PANEL_ID = "samxu29/ccf-deadlines:panel"
M.SITE_URL = "https://ccfddl.com/"

-- ccfddl's `sub` codes (conference/types.yml).
M.CATEGORIES = {
  DS = "Architecture / Parallel / Storage",
  NW = "Networking",
  SC = "Security",
  SE = "Software Eng. / OS / PL",
  DB = "Database / Data Mining / IR",
  CT = "Theory",
  CG = "Graphics / Multimedia",
  AI = "Artificial Intelligence",
  HI = "Human-Computer Interaction",
  MX = "Interdisciplinary / Emerging",
}

function M.request(action, extra)
  local prev = noctalia.state.get(M.REQUEST_KEY)
  local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
  local payload = { nonce = nonce, action = action }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  noctalia.state.set(M.REQUEST_KEY, payload)
end

function M.nowSec()
  return math.floor(noctalia.nowMs() / 1000)
end

-- "41d", "5d 3h", "7h 12m", "12:04" (mm:ss under an hour).
function M.countdown(seconds, precise)
  if seconds <= 0 then
    return noctalia.tr("countdown.passed")
  end
  local d = seconds // 86400
  local h = (seconds % 86400) // 3600
  local m = (seconds % 3600) // 60
  local s = seconds % 60
  if d >= 10 and not precise then
    return `{d}d`
  end
  if d >= 1 then
    if precise then
      return string.format("%dd %02dh %02dm %02ds", d, h, m, s)
    end
    return `{d}d {h}h`
  end
  if h >= 1 then
    if precise then
      return string.format("%dh %02dm %02ds", h, m, s)
    end
    return `{h}h {m}m`
  end
  return string.format("%d:%02d", m, s)
end

-- Color role by remaining time.
function M.urgencyColor(seconds, urgentDays)
  urgentDays = urgentDays or 3
  if seconds <= urgentDays * 86400 then
    return "error"
  elseif seconds <= 14 * 86400 then
    return "tertiary"
  end
  return "primary"
end

function M.rankColor(rank)
  if rank == "A" then
    return "error"
  elseif rank == "B" then
    return "tertiary"
  elseif rank == "C" then
    return "secondary"
  end
  return "outline"
end

function M.openUrl(url)
  -- Links come from downloaded data: only plain http(s) URLs, no spaces or control characters.
  if type(url) ~= "string" or not url:match("^https?://[^%s%c]+$") then
    return
  end
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.no_xdg_open"))
    return
  end
  noctalia.runAsync({ "xdg-open", url })
end

-- Label for a deadline row: "NeurIPS 2026" plus the round comment if any.
function M.itemTitle(item)
  return `{item.title} {item.year}`
end

function M.kindLabel(item)
  if item.kind == "abstract" then
    return noctalia.tr("kind.abstract")
  end
  return noctalia.tr("kind.paper")
end

return M
