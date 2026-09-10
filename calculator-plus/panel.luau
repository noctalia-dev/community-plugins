-- panel.luau
-- A popup panel that evaluates expressions with `qalc` and keeps a
-- session history. Clicking a history row copies its result.

local history = {}
local sessionExprs = {}
local currentInput = ""
local inputGen = 0
local lastLineCount = 0
local historyIndex = nil -- nil = not browsing; 1 = most recent, 2 = one before that, ...
local draftInput = ""
local scrollRev = 0  -- add near your other localslocal function historyRows()

local function historyRows()
	local rows = {}
	for i = 1, #history do
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
	panel.render(ui.column({ gap = 12, padding = 16, height = 480 }, {
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
    ui.scroll({ flexGrow = 1, gap = 8, stickToBottom = true, scrollToBottomRev = scrollRev }, historyRows()),
		ui.input({
			key = "expr-input-" .. inputGen,
      value = currentInput,
			placeholder = noctalia.tr("panel.placeholder"),
			controlSize = "lg",
			fontSize = 14,
			focus = true,
			onChange = "onInputChange",
			onSubmit = "onEvaluate",
		}),
		ui.label({
			text = noctalia.tr("panel.hint"),
			fontSize = 11,
			color = "on_surface_variant",
			textAlign = "center",
			opacity = 0.5,
		}),
	}))
end

local function evaluate(expr)
	table.insert(sessionExprs, expr)
	local body = table.concat(sessionExprs, "\n")
	local cmd = "qalc -t -f - <<'QALC_EOF'\n" .. body .. "\nQALC_EOF\n"

	noctalia.runAsync(cmd, function(result)
		local ok = result.exitCode == 0
		local lines = {}
		if ok then
			for line in (result.stdout .. "\n"):gmatch("(.-)\n") do
				if noctalia.string.trim(line) ~= "" then
					table.insert(lines, line)
				end
			end
		end

		local output, isErr

		if ok and #lines > lastLineCount then
			output = noctalia.string.trim(lines[#lines])
			isErr = false
		elseif ok then
			-- silent statement (bare assignment) - qalc prints nothing for these
			local name, value = expr:match("^%s*([%a_][%w_]*)%s*=%s*(.+)$")
			output = name and (name .. " = " .. noctalia.string.trim(value)) or expr
			isErr = false
		else
			local errText = noctalia.string.trim(result.stderr)
			output = errText ~= "" and errText or noctalia.tr("panel.error")
			isErr = true
		end

		if ok then lastLineCount = #lines end

    table.insert(history, { expr = expr, result = output, isError = isErr })
		currentInput = ""
		inputGen = inputGen + 1
		scrollRev = scrollRev + 1
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
  if expr == "exit" then
    panel.close()
    currentInput = ""
    inputGen = inputGen + 1
    return
  end
	if expr == "clear" then
    currentInput = ""
    inputGen = inputGen + 1
    onClear()
		return
	end
	evaluate(expr)
end

function onClear()
	history = {}
	sessionExprs = {}
  lastLineCount = 0
	scrollRev = scrollRev + 1
	render()
end

function onKey(chord, pressed)
  if not pressed or #history == 0 then return end

	if chord == "Up" or chord == "up" then
		if historyIndex == nil then
			draftInput = currentInput
			historyIndex = 1
		elseif historyIndex < #history then
			historyIndex = historyIndex + 1
		end
		currentInput = history[#history - historyIndex + 1].expr
		inputGen = inputGen + 1
		render()
	elseif chord == "Down" or chord == "down" then
		if historyIndex == nil then return end
		if historyIndex > 1 then
			historyIndex = historyIndex - 1
			currentInput = history[#history - historyIndex + 1].expr
		else
			historyIndex = nil
			currentInput = draftInput
		end
		inputGen = inputGen + 1
		render()
	end
end

function onInputChange(value)
	currentInput = value
	historyIndex = nil
end

function onCloseClicked()
	panel.close()
end

function onOpen(context)
  noctalia.log("onOpen called, capture test build")
	render()
end
