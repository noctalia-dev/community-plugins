--!nonstrict
local store = require("./store.luau")
local types = require("./types.luau")

local M = {}

local FILE = "contests.json"

function M.load(): (types.BySource, types.BySource)
  local data = store.read(FILE)
  if type(data) ~= "table" then
    return {}, {}
  end
  return type(data.up) == "table" and data.up or {}, type(data.past) == "table" and data.past or {}
end

function M.save(upBySource: types.BySource, pastBySource: types.BySource)
  store.write(FILE, { up = upBySource, past = pastBySource })
end

return M
