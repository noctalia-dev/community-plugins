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

local sample_connections = [[
{"downloadTotal":6694145524,"uploadTotal":123456,"connections":[
{"id":"a","metadata":{"host":"example.com"},"upload":1,"download":2,"chains":["DIRECT"]},
{"id":"b","metadata":{"host":"other.com"},"upload":3,"download":4,"chains":["Proxy"]}
],"memory":116858880}
]]
local summary = logic.parse_connections_summary(sample_connections)
assert(summary ~= nil, "connections summary parses")
assert_eq(summary.count, 2, "connection count")
assert_eq(summary.downloadTotal, 6694145524, "download total")
assert_eq(summary.uploadTotal, 123456, "upload total")
assert_eq(summary.memory, 116858880, "memory")
assert(logic.parse_connections_summary("") == nil, "empty body is rejected")
assert(logic.parse_connections_summary("{") == nil, "invalid body is rejected")

local sample_proxies = {
  proxies = {
    ["Node A"] = {
      history = { { delay = 42 } },
    },
    ["Node B"] = {
      history = { { delay = 0 } },
    },
    Selector = {
      type = "Selector",
      now = "Node A",
      hidden = false,
      testUrl = "http://example.test/generate_204",
      all = { "Node A", "Node B" },
    },
  },
}
local built = logic.build_groups_from_proxies(sample_proxies.proxies, "http://fallback.test")
assert_eq(#built, 1, "one proxy group")
assert_eq(built[1].name, "Selector", "group name")
assert_eq(built[1].members[1].delay, 42, "member delay from history")
assert_eq(built[1].members[2].delay, 0, "failed probe delay is kept")

local slim = {
  delays = { ["Node A"] = 42, ["Node B"] = 0 },
  groups = {
    {
      name = "Selector",
      type = "Selector",
      now = "Node A",
      hidden = false,
      testUrl = "http://example.test/generate_204",
      members = { "Node A", "Node B" },
    },
  },
}
local from_slim = logic.build_groups_from_slim_proxies(slim, "http://fallback.test")
assert_eq(#from_slim, 1, "slim projection yields one group")
assert_eq(from_slim[1].members[1].delay, 42, "slim member delay")

assert(logic.proxies_body_needs_external_decode(string.rep("x", logic.PROXIES_INLINE_DECODE_LIMIT)) == false, "at-limit body stays inline")
assert(logic.proxies_body_needs_external_decode(string.rep("x", logic.PROXIES_INLINE_DECODE_LIMIT + 1)) == true, "over-limit body uses jq")

print("mihomo-control group_logic tests: ok")
