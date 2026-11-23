--!nonstrict
-- Choice lists of names the config defines (store.namedChoices), cached per store state.
local M = {}

-- Names the config defines, for choices: `base` first, then (by kind) curve names (beziers, springs), effect
-- presets and pools ("effect"), pools only ("pool"), outputs ("output": entries plus `extra`, the connected
-- ones), scratchpad and workspace names, or the submaps keybinds use. Unsaved edits count, and so do curves,
-- presets and pools from include files (`state.included`). Cached until those lists can have changed.
local namedCache = {}
-- presets, pools and curves can also come from include files (as of the last read)
local function includedNames(store, add, eid)
  local included = store.state and store.state.included
  for _, name in ipairs(included and included[eid] or {}) do add(name) end
end
local function entryNames(store, add, eid, field)
  for _, item in ipairs(store.entryItems(eid)) do
    if field then add(item.values and item.values[field]) else add(item.name) end
  end
  includedNames(store, add, eid)
end
function M.named(store, kind, base, extra)
  local c = namedCache
  if c.serial ~= store.serial or c.state ~= store.state or c.entries ~= store.entries or c.maps ~= store.maps
     or c.keybinds ~= store.keybinds or c.entryOps ~= #store.entryOps or c.mapOps ~= #store.mapOps then
    namedCache = { serial = store.serial, state = store.state, entries = store.entries, maps = store.maps, keybinds = store.keybinds,
                   entryOps = #store.entryOps, mapOps = #store.mapOps, lists = {} }
  end
  local cached = namedCache.lists[kind]
  if cached and cached.base == base and cached.extra == extra then return cached.list end
  local list, seen = {}, {}
  local function add(name)
    if type(name) == "string" and not seen[name] and (name ~= "" or #list == 0) then
      seen[name] = true
      table.insert(list, name)
    end
  end
  for _, choice in ipairs(base or {}) do add(choice) end
  if kind == "curve" then
    for _, eid in ipairs({ "beziers", "springs" }) do
      for _, row in ipairs(store.mapRows(eid)) do add(row[1]) end
      includedNames(store, add, eid)
    end
  elseif kind == "effect" then
    entryNames(store, add, "effect_preset")
    entryNames(store, add, "effect_pool")
  elseif kind == "pool" then
    entryNames(store, add, "effect_pool")
  elseif kind == "output" then
    entryNames(store, add, "output")
    for _, name in ipairs(extra or {}) do add(name) end
  elseif kind == "scratchpad" then
    entryNames(store, add, "scratchpad", "name")
  elseif kind == "workspace" then
    entryNames(store, add, "workspace", "name")
  elseif kind == "submap" then
    for _, row in ipairs((store.keybinds or {}).rows or {}) do add(row.opts and row.opts.submap) end
  end
  namedCache.lists[kind] = { base = base, extra = extra, list = list }
  return list
end

return M
