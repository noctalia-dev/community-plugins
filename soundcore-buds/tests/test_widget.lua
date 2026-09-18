-- Widget assertions. Runs after stubs + widget.luau.
print("== widget ==")
assert(captured.widgetTree, "widget rendered nothing")
assert(captured.visible == true, "widget should be visible when connected")
local tree = captured.widgetTree
assert(tree._kind == "row", "expected row container, got " .. tostring(tree._kind))
local img = tree.children[1]
assert(img._kind == "image", "first child should be image")
assert(img.props.path == "icons/pro-charging.svg", "icon path, got " .. tostring(img.props.path))
assert(captured.tooltip, "widget tooltip missing")
captured.state["sankity/soundcore-buds:snapshot"].stale = true
update()
local staleRow = false
for _, row in ipairs(captured.tooltip) do
	if row.key == "widget.stale" then staleRow = true end
end
assert(staleRow, "stale tooltip row missing")
captured.state["sankity/soundcore-buds:snapshot"].stale = false
captured.state["sankity/soundcore-buds:snapshot"].caseBattery.level = -1
update()
local caseRow = false
for _, row in ipairs(captured.tooltip) do
	if row.key == "panel.case" then caseRow = true end
end
assert(not caseRow, "unknown case battery must hide the case row")
captured.state["sankity/soundcore-buds:snapshot"].caseBattery.level = 80
captured.state["sankity/soundcore-buds:snapshot"].availableModes = {}
update()
local modeRow = false
for _, row in ipairs(captured.tooltip) do
	if row.key == "widget.mode" then modeRow = true end
end
assert(not modeRow, "model without modes must hide the mode row")
captured.state["sankity/soundcore-buds:snapshot"].connected = false
captured.state["sankity/soundcore-buds:snapshot"].hasBattery = false
update()
assert(captured.visible == false, "widget should hide when disconnected")
print("WIDGET TESTS PASSED")
