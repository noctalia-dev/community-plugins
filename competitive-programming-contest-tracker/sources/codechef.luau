--!nonstrict
local http = require("../lib/http.luau")
local parse = require("../lib/parse.luau")
local types = require("../lib/types.luau")

local M = { id = "CC" }

local URL = "https://www.codechef.com/api/list/contests/all?sort_by=START&sorting_order=asc&offset=0&mode=all"

local function convert(data: any, key: string, into: { types.Contest })
  for _, c in ipairs(data[key] or {}) do
    local start = parse.parseIso(c.contest_start_date_iso or "")
    local minutes = tonumber(c.contest_duration)
    if start and minutes then
      table.insert(into, {
        src = M.id,
        name = c.contest_name,
        start = start,
        dur = minutes * 60,
        url = `https://www.codechef.com/{c.contest_code}`,
      })
    end
  end
end

function M.fetch(done: types.Done, _opts: types.FetchOpts)
  http.getJson({ url = URL }, function(data: any)
    if type(data) ~= "table" or data.status ~= "success" then
      return done(nil)
    end
    local up: { types.Contest } = {}
    local past: { types.Contest } = {}
    convert(data, "present_contests", up)
    convert(data, "future_contests", up)
    convert(data, "past_contests", past)
    return done(up, past)
  end)
end

return M
