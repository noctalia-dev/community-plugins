--!nonstrict
local http = require("../lib/http.luau")
local parse = require("../lib/parse.luau")
local types = require("../lib/types.luau")

local M = { id = "AC" }

local URL = "https://atcoder.jp/contests/?lang=en"

local MAX_ROWS = 30

local function between(s: string, open: string, close: string, from: number): (string?, number)
  local a = string.find(s, open, from, true)
  if not a then
    return nil, from
  end
  local b = string.find(s, close, a + #open, true)
  if not b then
    return nil, from
  end
  return string.sub(s, a + #open, b - 1), b + #close
end

local function parseRows(section: string, suffix: string, oldest: number?): { types.Contest }
  local list: { types.Contest } = {}
  local pos = 1
  for _ = 1, MAX_ROWS do
    local row, nextPos = between(section, "<tr>", "</tr>", pos)
    if not row then
      break
    end
    pos = nextPos

    local time = between(row, "fixtime-full'>", "<", 1)
    local start = time and parse.parseIso(time)
    if start and oldest and start < oldest then
      break
    end
    local slug, afterHref = between(row, '<a href="/contests/', '"', 1)
    local title, afterTitle = between(row, ">", "</a>", afterHref)
    local length = between(row, '<td class="text-center">', "</td>", afterTitle)
    local h, m = string.match(length or "", "^(%d+):(%d+)$")
    if start and slug and title and h then
      table.insert(list, {
        src = M.id,
        name = parse.decodeEntities(title),
        start = start,
        dur = parse.num(h) * 3600 + parse.num(m) * 60,
        url = "https://atcoder.jp/contests/" .. slug .. suffix,
      })
    end
  end
  return list
end

function M.fetch(done: types.Done, opts: types.FetchOpts)
  http.request({ url = URL }, function(html: string?)
    if not html then
      return done(nil)
    end
    local upFrom = string.find(html, 'id="contest-table-action"', 1, true)
      or string.find(html, 'id="contest-table-upcoming"', 1, true)
    local recentFrom = string.find(html, 'id="contest-table-recent"', 1, true)
    if not upFrom and not recentFrom then
      return done(nil)
    end

    local up: { types.Contest } = {}
    if upFrom then
      up = parseRows(string.sub(html, upFrom, (recentFrom or #html + 1) - 1), "")
    end
    local past: { types.Contest } = {}
    if recentFrom then
      local oldest = os.time() - opts.pastWindowSeconds
      past = parseRows(string.sub(html, recentFrom), "/tasks", oldest)
    end
    return done(up, past)
  end)
end

return M
