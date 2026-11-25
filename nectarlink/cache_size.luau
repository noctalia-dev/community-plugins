--!nonstrict
-- Conservative retained-data estimate, not a measurement of Luau VM memory.
-- Includes strings and table overhead; stops traversing when the budget is exceeded.
local function size(value, limit)
  local bytes = 0
  local seen = {}
  local function visit(item, depth)
    if bytes > limit then
      return
    end
    if depth > 64 then
      bytes = limit + 1
      return
    end
    local kind = type(item)
    if kind == "string" then
      bytes = bytes + #item + 32
    elseif kind == "table" then
      if seen[item] then
        return
      end
      seen[item] = true
      bytes = bytes + 64
      for key, child in pairs(item) do
        visit(key, depth + 1)
        visit(child, depth + 1)
        if bytes > limit then
          break
        end
      end
    else
      bytes = bytes + 16
    end
  end
  visit(value, 0)
  return bytes
end
return size
