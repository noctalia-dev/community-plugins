local Layouts = require("./layouts.luau")

local layouts = {}

local COLUMNS = 4
local COLUMN_GAP = 2
local selectedLayout = ""
local generation = 0
local isOpen = false
local loading = false
local failed = false

local render

local function onPick(entry, renderedGeneration)
	if not isOpen or generation ~= renderedGeneration then return end
	selectedLayout = entry.symbol
	noctalia.runAsync({ "mmsg", "dispatch", "setlayout," .. entry.name }, function() end, 3000)
	isOpen = false
	generation = generation + 1
	panel.close()
end

local function makeGrid(children)
	local rows = {}
	local row  = {}
	for i, child in ipairs(children) do
		table.insert(row, child)
		if #row >= COLUMNS or i == #children then
			while #row < COLUMNS do
				table.insert(row, ui.spacer({ flexGrow = 1 }))
			end
			table.insert(rows, ui.row({ gap = COLUMN_GAP, align = "stretch" }, row))
			row = {}
		end
	end
	return ui.column({ gap = COLUMN_GAP }, rows)
end

local function renderButtons(is_list_mode)
	local buttons = {}
	local renderedGeneration = generation
	for _, entry in ipairs(layouts) do
		if Layouts.visible(entry) then
			local isSelected = selectedLayout == entry.symbol
			local function pick() onPick(entry, renderedGeneration) end
			
			if is_list_mode then
				table.insert(buttons, ui.button({
					key       = entry.name,
					glyph     = Layouts.glyph(entry),
					text      = Layouts.label(entry),
					variant   = if isSelected then "primary" else "ghost",
					onClick   = pick,
				}))
			else
				table.insert(buttons, ui.column({
					key      = entry.name,
					gap      = 2,
					align    = "center",
					flexGrow = 1,
				}, {
					ui.button({
						key     = entry.name,
						glyph   = Layouts.glyph(entry),
						glyphSize = 18,
						variant = if isSelected then "primary" else "ghost",
						onClick = pick,
					}),
					ui.label({
						text      = Layouts.label(entry),
						fontSize  = 9,
						fontWeight = "bold",
						color     = if isSelected then "primary" else "on_surface_variant",
						textAlign = "center",
						maxLines  = 1,
					}),
				}))
			end
		end
	end
	return buttons
end

render = function()
	if not isOpen then return end
	
	local list_mode_raw = noctalia.getConfig("list_mode")
	local is_list_mode = (list_mode_raw == true) or (list_mode_raw == "true")
	local buttons = renderButtons(is_list_mode)
	
	local content
	if #buttons == 0 then
		local status = if loading then "layouts_loading" else
			if failed then "layouts_unavailable" else "layouts_empty"
		content = ui.column({ padding = 12 }, {
			ui.label({ text = noctalia.tr(status), maxLines = 3 }),
		})
	elseif is_list_mode then
		content = ui.column({ padding = 8, gap = 4 }, buttons)
	else
		content = ui.column({ padding = 12, gap = COLUMN_GAP }, {
			makeGrid(buttons)
		})
	end

	panel.render(ui.column({ flexGrow = 1 }, {
		ui.scroll({ flexGrow = 1 }, {
			content
		})
	}))
end

function onOpen(context)
	generation = generation + 1
	local openedGeneration = generation
	isOpen = true
	loading = true
	failed = false
	selectedLayout = ""
	render()
	Layouts.discover(function(result)
		if not isOpen or generation ~= openedGeneration then return end
		loading = false
		failed = result == nil
		if result then layouts = result end
		render()
	end)
	Layouts.query("all-monitors", function(data)
		if not isOpen or generation ~= openedGeneration then return end
		selectedLayout = Layouts.active(data)
		render()
	end)
end

function onClose()
	isOpen = false
	generation = generation + 1
end
