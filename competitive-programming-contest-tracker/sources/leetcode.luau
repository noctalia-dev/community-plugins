--!nonstrict
local http = require("../lib/http.luau")
local types = require("../lib/types.luau")

local M = { id = "LC" }

local QUERY = '{"query":"{ topTwoContests { title titleSlug startTime duration } '
  .. 'pastContests(pageNo: 1, numPerPage: 10) { data { title titleSlug startTime duration } } }"}'

local function convert(list: any, into: { types.Contest })
  for _, c in ipairs(list or {}) do
    table.insert(into, {
      src = M.id,
      name = c.title,
      start = c.startTime,
      dur = c.duration,
      url = `https://leetcode.com/contest/{c.titleSlug}`,
    })
  end
end

function M.fetch(done: types.Done, _opts: types.FetchOpts)
  http.getJson({
    url = "https://leetcode.com/graphql",
    method = "POST",
    headers = { "Content-Type: application/json" },
    body = QUERY,
  }, function(data: any)
    if type(data) ~= "table" or type(data.data) ~= "table" then
      return done(nil)
    end
    local up: { types.Contest } = {}
    local past: { types.Contest } = {}
    convert(data.data.topTwoContests, up)
    convert(data.data.pastContests and data.data.pastContests.data, past)
    return done(up, past)
  end)
end

return M
