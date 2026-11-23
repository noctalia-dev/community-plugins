--!nonstrict
-- Global search over settings, pages, rules and keybinds. Field text is lower-cased by the helper.
local M = {}

local LIMIT = 40
M.LIMIT = LIMIT  -- results shown at most

local function words(query)
  local result = {}
  for word in string.gmatch(string.lower(query), "%S+") do table.insert(result, word) end
  return result
end

-- Every word must appear literally; fuzzyScore only ranks the label.
local function matches(text, terms)
  for _, term in ipairs(terms) do
    if not string.find(text, term, 1, true) then return false end
  end
  return true
end

local function score(query, label)
  local value = noctalia.fuzzyScore and noctalia.fuzzyScore(query, label) or nil
  return tonumber(value) or 0
end

-- Returns { { kind = "field"|"page"|"entry"|"keybind", ... , score } } best first, and whether it was cut.
function M.run(store, query)
  local terms = words(query)
  if #terms == 0 then return {}, false end
  local results = {}
  local meta = store.meta
  for name, page in pairs(meta.pages) do
    local text = string.lower(name .. " " .. (page.help or ""))
    if matches(text, terms) then
      table.insert(results, { kind = "page", page = name, score = score(query, name) + 1000 })
    end
  end
  for _, item in ipairs(store.searchIndex or {}) do
    local fid, text = item[1], item[2]
    local field = meta.fields[fid]  -- an index from another meta may name fields this one lacks
    if field and matches(text, terms) then
      table.insert(results, { kind = "field", id = fid, score = score(query, field.label) })
    end
  end
  for eid, editor in pairs(meta.editors) do
    for index, entry in ipairs(store.entryItems(eid)) do
      local title = store.entryTitle(eid, index, entry)
      if matches(string.lower(title .. " " .. editor.page), terms) then
        table.insert(results, { kind = "entry", editor = eid, index = index, title = title,
                                score = score(query, title) + 500 })
      end
    end
  end
  if store.keybinds then
    for index, row in ipairs(store.keybinds.rows) do
      if matches(string.lower(row.key .. " " .. row.action .. " " .. (row.group or "")), terms) then
        table.insert(results, { kind = "keybind", index = index, score = score(query, row.key .. " " .. row.action) + 400 })
      end
    end
  end
  table.sort(results, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return (a.id or a.page or a.title or "") < (b.id or b.page or b.title or "")
  end)
  local cut = #results > LIMIT
  while #results > LIMIT do table.remove(results) end
  return results, cut
end

-- Where a field lives: page and group for settings, editor for rule fields.
local places = { meta = nil, fields = {} }  -- field id -> { page, group }, built once per meta
function M.locate(meta, fid)
  local eid = string.match(fid, "^([%w_]+):")
  if eid then return meta.editors[eid] and { editor = eid, page = meta.editors[eid].page } or nil end
  if places.meta ~= meta then
    places = { meta = meta, fields = {} }
    for page, info in pairs(meta.pages) do
      for _, group in ipairs(info.groups or {}) do
        for _, id in ipairs(group.fields) do
          places.fields[id] = places.fields[id] or { page = page, group = group.title }
        end
      end
    end
  end
  return places.fields[fid]
end

return M
