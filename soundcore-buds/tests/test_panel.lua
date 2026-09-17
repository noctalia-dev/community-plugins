-- Panel assertions. Runs after stubs + panel.luau.
-- The panel reads the snapshot left by the service run, so this file is
-- concatenated after the service tests in run.sh.
print("== panel ==")
onOpen(nil)
assert(captured.panelTree, "panel rendered nothing")

local function collectKeys(node, acc)
	acc = acc or {}
	if type(node) ~= "table" or node._kind == nil then return acc end
	if node.props ~= nil and node.props.key ~= nil then acc[node.props.key] = node._kind end
	for _, child in ipairs(node.children or {}) do
		collectKeys(child, acc)
	end
	return acc
end

local function kinds(node, acc)
	acc = acc or {}
	if type(node) ~= "table" or node._kind == nil then return acc end
	acc[node._kind] = (acc[node._kind] or 0) + 1
	for _, child in ipairs(node.children or {}) do
		kinds(child, acc)
	end
	if node.props ~= nil and type(node.props.onClick) == "function" then
		acc["clickable"] = (acc["clickable"] or 0) + 1
	end
	return acc
end

local keys = collectKeys(captured.panelTree)
assert(keys["touch-leftSinglePress"] == "select", "touch select kind")
local touchSelects = 0
for key, kind in pairs(keys) do
	if kind == "select" and string.sub(key, 1, 6) == "touch-" then touchSelects += 1 end
end
assert(touchSelects == 8, "expected 8 touch selects, got " .. tostring(touchSelects))
assert(keys["sound-autoPowerOff"], "missing auto-off select")
assert(keys["cancel-Adaptive"], "missing Adaptive sub button")
assert(keys["cancel-Manual"], "missing Manual sub button")
assert(keys["cancel-MultiScene"], "missing MultiScene sub button")
assert(keys["mode-0"] and keys["mode-1"] and keys["mode-2"], "missing top mode buttons")
assert(keys["mode-3"] == nil, "legacy Adaptive top button must be gone")
local k = kinds(captured.panelTree)
assert((k["toggle"] or 0) >= 1, "expected touch-tone toggle")
assert((k["slider"] or 0) >= 1, "expected ANC slider in Manual, got " .. tostring(k["slider"] or 0))
assert((k["progress"] or 0) == 3, "expected 3 battery rows, got " .. tostring(k["progress"] or 0))
watchers["sankity/soundcore-buds:command"]({ action = "set-cancel-mode", value = "MultiScene", nonce = "pc1" })
local keys2 = collectKeys(captured.panelTree)
assert(keys2["sound-multiSceneNoiseCanceling"], "scenario select under MultiScene")
assert(keys2["anc-strength"] == nil, "ANC slider hidden outside Manual")
assert(keys["find-left"], "missing find-left button")
assert(keys["find-right"], "missing find-right button")
assert(keys["touch-reset"], "missing touch-reset button")


-- stale snapshot shows the refresh button promised by the busy hint
local staleSnap = captured.state["sankity/soundcore-buds:snapshot"]
staleSnap.stale = true
watchers["sankity/soundcore-buds:snapshot"](staleSnap)
local staleKeys = collectKeys(captured.panelTree)
assert(staleKeys["refresh-stale"], "missing stale refresh button")
staleSnap.stale = false
watchers["sankity/soundcore-buds:snapshot"](staleSnap)
-- mode-gated toggles: ANC shows both, Transparency only wind, Normal neither
local gatedSnap = captured.state["sankity/soundcore-buds:snapshot"]
gatedSnap.topMode = 0
watchers["sankity/soundcore-buds:snapshot"](gatedSnap)
local normalKeys = collectKeys(captured.panelTree)
assert(normalKeys["mode-wind"] == nil and normalKeys["mode-wind-nc"] == nil, "wind hidden in Normal")
assert(normalKeys["mode-rtanc"] == nil, "rt-anc hidden in Normal")
gatedSnap.topMode = 2
watchers["sankity/soundcore-buds:snapshot"](gatedSnap)
local transKeys = collectKeys(captured.panelTree)
assert(transKeys["mode-wind"], "wind visible in Transparency")
assert(transKeys["transparency-FullyTransparent"], "transparency variant buttons")
assert(transKeys["mode-rtanc"] == nil, "rt-anc hidden in Transparency")
gatedSnap.topMode = 1
watchers["sankity/soundcore-buds:snapshot"](gatedSnap)
local ancKeys = collectKeys(captured.panelTree)
assert(ancKeys["mode-wind-nc"], "wind visible in ANC")
assert(ancKeys["mode-rtanc"], "rt-anc visible in ANC")
onCloseClicked()

print("== panel keyboard ==")
local lastCommand = nil
watchers["sankity/soundcore-buds:command"] = function(cmd) lastCommand = cmd end
onKey("o", true)
assert(lastCommand ~= nil and lastCommand.action == "set-noise" and lastCommand.value == 0, "o -> off")
onKey("t", true)
assert(lastCommand.value == 2, "t -> transparency")
onKey("a", true)
assert(lastCommand.value == 3, "a -> adaptive")
onKey("n", true)
assert(lastCommand.value == 1, "n -> anc")
onKey("r", true)
assert(lastCommand.action == "refresh", "r -> refresh")
lastCommand = nil
onKey("n", false)
assert(lastCommand == nil, "key release must not send")
onKey("x", true)
assert(lastCommand == nil, "unlisted key must not send")
onKey("f", true)
assert(lastCommand == nil, "first f arms only, must not send")
onKey("f", true)
assert(lastCommand ~= nil and lastCommand.action == "find" and lastCommand.value == "left", "second f -> find left")
print("PANEL TESTS PASSED")
