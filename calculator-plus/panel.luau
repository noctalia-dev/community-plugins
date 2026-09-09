-- panel.luau
-- A popup panel that evaluates expressions with `qalc` and keeps a
-- session history. Clicking a history row copies its result.

local history = {} -- { expr = string, result = string, isError = bool }
local currentInput = ""
local inputGen = 0 -- bump to force ui.input to reseed/clear/refocus

local function historyRows()
	local rows = {}
	for i = #history, 1, -1 do
		local h = history[i]
		table.insert(
			rows,
			ui.column({
				key = "h" .. i,
				gap = 2,
				padding = 8,
				radius = 8,
				fill = "surface_variant/0.4",
				onClick = function()
					noctalia.copyToClipboard(h.result, "text/plain")
					noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.copied", { value = h.result }))
				end,
			}, {
				ui.label({ text = h.expr, fontSize = 11, color = "on_surface_variant" }),
				ui.label({
					text = h.result,
					fontSize = 15,
					fontWeight = "bold",
					color = h.isError and "#e05555" or "primary",
				}),
			})
		)
	end
	return rows
end

local function render()
	panel.render(ui.column({ gap = 12, padding = 16 }, {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.button({
				glyph = "trash",
				variant = "ghost",
				controlSize = "sm",
				tooltip = noctalia.tr("panel.clear"),
				onClick = "onClear",
				enabled = #history > 0,
			}),
			ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
		}),
		ui.scroll({ flexGrow = 1, gap = 8 }, historyRows()),
		ui.input({
			key = "expr-input-" .. inputGen,
			placeholder = noctalia.tr("panel.placeholder"),
			focus = true,
			onChange = "onInputChange",
			onSubmit = "onEvaluate",
		}),
	}))
end

local function evaluate(expr)
	noctalia.runAsync({ "qalc", "-t", expr }, function(result)
		local ok = result.exitCode == 0 and noctalia.string.trim(result.stdout) ~= ""
		local output = ok and noctalia.string.trim(result.stdout)
			or (noctalia.string.trim(result.stderr) ~= "" and noctalia.string.trim(result.stderr) or noctalia.tr("panel.error"))
		table.insert(history, { expr = expr, result = output, isError = not ok })
		currentInput = ""
		inputGen = inputGen + 1
		render()
	end)
end

function onInputChange(value)
	currentInput = value
end

function onEvaluate()
	local expr = noctalia.string.trim(currentInput)
	if expr == "" then
		return
	end
	evaluate(expr)
end

function onClear()
	history = {}
	render()
end

function onCloseClicked()
	panel.close()
end

function onOpen(context)
	render()
end
