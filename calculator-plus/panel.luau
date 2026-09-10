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
local scrollRev = 0
local isEvaluating = false
local hoveredRow = nil

local notifyOnCopy = noctalia.getConfig("notify_on_copy")
local heldChord = nil
local heldElapsedMs = 0
local REPEAT_DELAY_MS = noctalia.getConfig("repeat_delay_ms")       -- pause before repeat kicks in
local REPEAT_INTERVAL_MS = noctalia.getConfig("repeat_interval_ms") -- how fast it repeats after that

local ROW_GAP = 8
local ROW_RADIUS = 8
local ROW_PADDING = 8

local function pushHistory(expr, result, isErr)
	table.insert(history, { expr = expr, result = result, isError = isErr })
	scrollRev = scrollRev + 1
end

local function historyRows()
	if #history == 0 then
		return {
			ui.label({
				text = noctalia.tr("panel.empty"),
				fontSize = 12,
				color = "on_surface_variant",
				opacity = 0.5,
				textAlign = "center",
			}),
		}
	end

	local rows = {}
	for i = 1, #history do
		local h = history[i]
		local key = "h" .. i
		table.insert(
			rows,
			ui.row({
				key = key,
				align = "center",
				gap = ROW_GAP,
				padding = ROW_PADDING,
				radius = ROW_RADIUS,
				fill = (hoveredRow == key) and "surface_variant/0.6" or "surface_variant/0.4",
				onClick = function()
					noctalia.copyToClipboard(h.result, "text/plain")
          if notifyOnCopy then
            noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.copied", { value = h.result }))
          end
				end,
				onHover = "onRowHover",
			}, {
				ui.column({ gap = 2, flexGrow = 1 }, {
					ui.label({ text = h.expr, fontSize = 11, color = "on_surface_variant" }),
					ui.label({
						text = h.result,
						fontSize = 15,
						fontWeight = "bold",
						color = h.isError and "#e05555" or "primary",
					}),
				}),
				ui.button({
					key = "more-" .. i,
					glyph = "dots-vertical",
					variant = "ghost",
					controlSize = "sm",
					onRightClick = function() onRowMenuClick(i) end,
				}),
			})
		)
	end

	if isEvaluating then
		table.insert(rows, ui.label({
			key = "evaluating",
			text = noctalia.tr("panel.evaluating"),
			fontSize = 11,
			color = "on_surface_variant",
			opacity = 0.6,
		}))
	end

	return rows
end

local function header()
	return ui.row({ align = "center", justify = "space_between" }, {
		ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
		ui.button({
			glyph = "trash",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("panel.clear"),
			onClick = "onClear",
			enabled = #history > 0,
		}),
		ui.button({
      glyph = "x", 
      variant = "ghost", 
      controlSize = "sm", 
			tooltip = noctalia.tr("panel.close"),
      onClick = "onCloseClicked"
    }),
	})
end

local function inputBar()
	local children = {}

	if historyIndex ~= nil then
		table.insert(children, ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = "history", size = 12, color = "on_surface_variant" }),
			ui.label({
				text = noctalia.tr("panel.browsing", { index = historyIndex, total = #history }),
				fontSize = 11,
				color = "on_surface_variant",
				opacity = 0.7,
			}),
		}))
	end

	table.insert(children, ui.input({
		key = "expr-input-" .. inputGen,
		value = currentInput,
		placeholder = isEvaluating and noctalia.tr("panel.evaluating") or noctalia.tr("panel.placeholder"),
		controlSize = "lg",
		fontSize = 14,
		focus = true,
		enabled = not isEvaluating,
		onChange = "onInputChange",
		onSubmit = "onEvaluate",
	}))

	return ui.column({ gap = 4 }, children)
end

local function render()
	panel.render(ui.column({ gap = 0, padding = 16, height = 480 }, {
		header(),
		ui.scroll({ flexGrow = 1, gap = ROW_GAP, stickToBottom = true, scrollToBottomRev = scrollRev }, historyRows()),
		inputBar(),
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

	isEvaluating = true
	render()

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

		pushHistory(expr, output, isErr)
		currentInput = ""
		historyIndex = nil
		inputGen = inputGen + 1
		isEvaluating = false
		render()
	end)
end

function onInputChange(value)
	currentInput = value
	historyIndex = nil
end

function onEvaluate()
	if isEvaluating then return end

	local expr = noctalia.string.trim(currentInput)
	if expr == "" then
		return
	end
	if expr == "exit" then
    panel.close()
    currentInput = ""
   -- inputGen = inputGen + 1
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


local function stepHistory(chord)
	if #history == 0 or isEvaluating then return end

	if chord == "up" then
		if historyIndex == nil then
			draftInput = currentInput
			historyIndex = 1
		elseif historyIndex < #history then
			historyIndex = historyIndex + 1
		end
		currentInput = history[#history - historyIndex + 1].expr
		inputGen = inputGen + 1
		render()
	elseif chord == "down" then
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

function onKey(chord, pressed)
	if chord ~= "up" and chord ~= "down" then return end

	if pressed then
		heldChord = chord
		heldElapsedMs = 0
		panel.setNeedsFrameTick(true)
		stepHistory(chord)
	elseif heldChord == chord then
		heldChord = nil
		panel.setNeedsFrameTick(false)
	end
end

function onFrameTick(deltaMs)
	if heldChord == nil then return end

	heldElapsedMs = heldElapsedMs + deltaMs
	if heldElapsedMs >= REPEAT_DELAY_MS then
		heldElapsedMs = heldElapsedMs - REPEAT_INTERVAL_MS
		stepHistory(heldChord)
	end
end

function onRowHover(state, key)
	hoveredRow = (state == "true") and key or nil
	render()
end

function onRowMenuClick(index)
	panel.openContextMenu({
		items = {
			{ id = "rerun", label = noctalia.tr("panel.rerun") },
			{ id = "copyExpr", label = noctalia.tr("panel.copy_expr") },
			{ kind = "separator" },
			{ id = "delete", label = noctalia.tr("panel.delete") },
		},
		onActivate = "onRowMenuAction",
		context = index,
	})
end

function onRowMenuAction(actionId, index)
	local h = history[index]
	if not h then return end

	if actionId == "rerun" then
		evaluate(h.expr)
	elseif actionId == "copyExpr" then
    noctalia.copyToClipboard(h.expr, "text/plain")
    if notifyOnCopy then
      noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.copied", { value = h.expr }))
    end
	elseif actionId == "delete" then
		table.remove(history, index)
		render()
	end
end

function onCloseClicked()
	panel.close()
end

function onOpen(context)
  heldChord = nil
	render()
end
