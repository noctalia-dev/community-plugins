--!nonstrict
local settings = require("./settings.luau")
local types = require("./types.luau")

local M = {}

function M.build(
  upBySource: types.BySource,
  pastBySource: types.BySource,
  filters: types.Filters,
  now: number
): ({ types.Contest }, { types.Contest })
  local maxDur = settings.hideLongerThanSeconds()
  local window = settings.pastWindowSeconds()
  local favorites = filters.favorites
  local saved = filters.saved

  local up: { types.Contest } = {}
  for _, list in pairs(upBySource) do
    for _, c in ipairs(list) do
      local tooLong = maxDur > 0 and c.dur > maxDur and not favorites[c.url]
      if c.start + c.dur > now and not tooLong then
        table.insert(up, c)
      end
    end
  end
  table.sort(up, function(a: types.Contest, b: types.Contest)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.name < b.name
  end)

  local past: { types.Contest } = {}
  for _, list in pairs(pastBySource) do
    for _, c in ipairs(list) do
      local ended = c.start + c.dur
      local tooLong = maxDur > 0 and c.dur > maxDur and not saved[c.url]
      if ended <= now and now - ended <= window and not tooLong then
        table.insert(past, c)
      end
    end
  end
  table.sort(past, function(a: types.Contest, b: types.Contest)
    if a.start ~= b.start then
      return a.start > b.start
    end
    return a.name < b.name
  end)

  return up, past
end

return M
