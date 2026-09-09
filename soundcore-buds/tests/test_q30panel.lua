-- Q30 panel assertions. Runs after stubs + service + test_q30 + panel.luau.
print("== q30 panel ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-noise", value = 1, nonce = "qp0" })
onOpen(nil)
assert(captured.panelTree, "panel rendered nothing")

local function qkinds(node, acc)
	acc = acc or {}
	if type(node) ~= "table" or node._kind == nil then return acc end
	acc[node._kind] = (acc[node._kind] or 0) + 1
	for _, child in ipairs(node.children or {}) do
		qkinds(child, acc)
	end
	return acc
end

local function qkeys(node, acc)
	acc = acc or {}
	if type(node) ~= "table" or node._kind == nil then return acc end
	if node.props ~= nil and node.props.key ~= nil then acc[node.props.key] = node._kind end
	for _, child in ipairs(node.children or {}) do
		qkeys(child, acc)
	end
	return acc
end

local k = qkinds(captured.panelTree)
assert((k["progress"] or 0) == 1, "one headset battery row, got " .. tostring(k["progress"] or 0))
local keys = qkeys(captured.panelTree)
assert(keys["cancel-Transport"], "missing Transport button")
assert(keys["cancel-Indoor"], "missing Indoor button")
assert(keys["cancel-Outdoor"], "missing Outdoor button")
assert(keys["cancel-Adaptive"] == nil, "no Adaptive on Q30")
assert(keys["anc-strength"] == nil, "no ANC slider without manual ANC")
assert(keys["find-left"] == nil and keys["find-right"] == nil, "no find buttons on headset")
for key, _ in pairs(keys) do
	assert(string.sub(key, 1, 6) ~= "touch-", "no touch controls on Q30: " .. tostring(key))
end
onCloseClicked()
print("Q30 PANEL TESTS PASSED")
