--!nonstrict
local types = require("./types.luau")

local M = {}

M.list = {
  { id = "CF", name = "Codeforces", icon = "icons/cf.png" },
  { id = "LC", name = "LeetCode", icon = "icons/lc.png" },
  { id = "AC", name = "AtCoder", icon = "icons/ac.png" },
  { id = "CC", name = "CodeChef", icon = "icons/cc.png" },
} :: { types.Platform }

M.icons = {} :: { [string]: string }
for _, p in ipairs(M.list) do
  M.icons[p.id] = p.icon
end

return M
