--!nonstrict
-- Search used by the panel and the launcher. Plain substring matches come first (in
-- their original order); fuzzy matching is only a fallback when nothing contains the
-- text, so "git" finds GitHub and not every name with a g, an i and a t in it.

local M = {}

function M.filter(items, query: string, text: (any) -> string)
  query = noctalia.string.trim(query or ""):lower()
  if query == "" then
    return table.clone(items)
  end
  local exact = {}
  for _, item in items do
    if text(item):lower():find(query, 1, true) then
      table.insert(exact, item)
    end
  end
  if #exact > 0 then
    return exact
  end
  local scored = {}
  for _, item in items do
    local score = noctalia.fuzzyScore(query, text(item))
    if score then
      table.insert(scored, { item = item, score = score })
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score
  end)
  local out = {}
  for _, s in scored do
    table.insert(out, s.item)
  end
  return out
end

return M
