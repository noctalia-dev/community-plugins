--!nonstrict
-- Launcher provider: type the prefix (default `/totp`) and a service name; Enter copies the
-- current code. The code is computed again on activation, so it is never a stale one.

local store = require("./store.luau")
local totp = require("./totp.luau")
local copy = require("./copy.luau")
local match = require("./match.luau")

local tr = noctalia.tr

local function title(a)
  return a.issuer ~= "" and a.issuer or a.account
end

function onQuery(query)
  local s = store.current()
  local now = os.time()
  local shown = match.filter(s.accounts, query, function(a)
    return title(a) .. " " .. a.account
  end)
  local rows = {}
  for i, a in shown do
    local code, left = totp.code(a, now)
    table.insert(rows, {
      id = a.id,
      title = title(a),
      subtitle = (a.issuer ~= "" and a.account ~= "") and a.account or nil,
      badge = code and (totp.group(code) .. "  ·  " .. tr("common.seconds", { n = left })) or "—",
      glyph = "shield-lock",
      score = #shown - i, -- keep match order
    })
  end
  if #rows == 0 then
    local key = s.status == "error" and "launcher.error" or (#s.accounts == 0 and "launcher.empty" or "launcher.no_match")
    rows[1] = { id = "", title = tr(key), glyph = "mood-empty" }
  end
  launcher.setResults(query, rows)
end

function onActivate(id)
  for _, a in store.current().accounts do
    if a.id == id then
      copy.code(a)
      return
    end
  end
end
