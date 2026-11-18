--!nonstrict
local http = require("../lib/http.luau")
local types = require("../lib/types.luau")

local M = { id = "CF" }

local MAX_OBJECTS = 45

local function trim(body: string): string
  local i = 1
  local count = 0
  while true do
    local j = string.find(body, '{"id":', i, true)
    if not j then
      return body
    end
    count += 1
    if count == MAX_OBJECTS + 1 then
      return string.sub(body, 1, j - 2) .. "]}"
    end
    i = j + 1
  end
end

function M.fetch(done: types.Done, _opts: types.FetchOpts)
  http.request({ url = "https://codeforces.com/api/contest.list?gym=false" }, function(body: string?)
    local data: any = body and noctalia.json.decode(trim(body))
    if type(data) ~= "table" or data.status ~= "OK" then
      return done(nil)
    end
    local up: { types.Contest } = {}
    local past: { types.Contest } = {}
    for _, c in ipairs(data.result) do
      if c.phase == "BEFORE" or c.phase == "CODING" then
        table.insert(up, {
          src = M.id,
          name = c.name,
          start = c.startTimeSeconds,
          dur = c.durationSeconds,
          url = `https://codeforces.com/contests/{c.id}`,
        })
      elseif c.startTimeSeconds then
        table.insert(past, {
          src = M.id,
          name = c.name,
          start = c.startTimeSeconds,
          dur = c.durationSeconds,
          url = `https://codeforces.com/contest/{c.id}`,
        })
      end
    end
    return done(up, past)
  end)
end

return M
