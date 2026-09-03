local common = require("../common")

local normalized, extra = common.without_trailing_slash("/tmp/bridge///")
assert(normalized == "/tmp/bridge")
assert(extra == nil, "path normalization must return exactly one value")

local candidates = {}
table.insert(candidates, common.without_trailing_slash("/tmp/bridge/"))
assert(#candidates == 1)
assert(candidates[1] == "/tmp/bridge")

assert(common.terminal_action({ status = "success" }))
assert(common.terminal_action({ status = "error" }))
assert(common.terminal_action({ status = "unknown" }))
assert(not common.terminal_action({ status = "working" }))

print("runtime smoke tests passed")
