#!/usr/bin/env lua5.4

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local dir = source:match("^(.*)/") or "."
  if dir:match("/tests$") or dir == "tests" then
    return dir .. "/.."
  end
  return dir
end

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error((message or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function assert_tables_eq(actual, expected, message)
  if #actual ~= #expected then
    error((message or "assert_tables_eq") .. ": length " .. tostring(#actual) .. " != " .. tostring(#expected))
  end
  for index, value in ipairs(expected) do
    if actual[index] ~= value then
      error((message or "assert_tables_eq") .. ": index " .. index .. " expected " .. tostring(value) .. ", got " .. tostring(actual[index]))
    end
  end
end

local logic = dofile(plugin_root() .. "/group_logic.luau")

local groups = {
  { name = "zeta" },
  { name = "alpha" },
  { name = "beta" },
}

logic.apply_group_order(groups, { "beta", "alpha" })
assert_tables_eq({ groups[1].name, groups[2].name, groups[3].name }, { "beta", "alpha", "zeta" }, "known order first")

logic.apply_group_order(groups, {})
assert_tables_eq({ groups[1].name, groups[2].name, groups[3].name }, { "alpha", "beta", "zeta" }, "unknown groups sort alphabetically")

local reordered, order = logic.reorder_groups({
  { name = "a" },
  { name = "b" },
  { name = "c" },
}, "c", 1)
assert(reordered ~= nil, "reorder_groups should succeed")
assert_tables_eq(order, { "c", "a", "b" }, "move to front")

reordered, order = logic.reorder_groups({
  { name = "a" },
  { name = "b" },
  { name = "c" },
}, "a", 4)
assert_tables_eq(order, { "b", "c", "a" }, "move to back")

assert(logic.reorder_groups({ { name = "a" } }, "missing", 1) == nil, "unknown group is rejected")
assert(logic.reorder_groups({ { name = "a" } }, "a", nil) == nil, "missing index is rejected")

assert_eq(logic.normalize_group_order({ "b", "", "a", "b", "a" })[1], "b", "dedupe keeps first occurrence")
assert_eq(#logic.normalize_group_order({ "b", "", "a", "b", "a" }), 2, "dedupe drops blanks and duplicates")

assert_eq(logic.clamp_interval(0), 1, "interval floor")
assert_eq(logic.clamp_interval(120), 60, "interval ceiling")
assert_eq(logic.clamp_interval(5), 5, "interval passthrough")

local traffic = { up = 1, down = 2, upTotal = 3, downTotal = 4 }
assert(logic.traffic_changed(traffic, { up = 1, down = 2, upTotal = 3, downTotal = 4 }) == false, "identical traffic is unchanged")
assert(logic.traffic_changed(traffic, { up = 9, down = 2, upTotal = 3, downTotal = 4 }) == true, "changed traffic is detected")

print("mihomo-control group_logic tests: ok")
