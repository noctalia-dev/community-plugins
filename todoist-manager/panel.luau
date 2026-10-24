--!nonstrict
-- panel.luau
-- Declarative panel: filter tiles, quick capture, task list.
-- The circle button expands a Complete/Reopen + Not now pair under the task,
-- while clicking the task body toggles its description inline (if any).
local state = require("./lib/state.luau")
local dates = require("./lib/dates.luau")

noctalia.setUpdateInterval(1000)

local PCOLOR = {
	[1] = "#e5484d", -- p1 / very urgent
	[2] = "#f5a524", -- p2
	[3] = "#3b82f6", -- p3
	[4] = "#8b8d98", -- p4 / natural
}
local MUTED = "#8b8d98"
local DANGER = "#e5484d"

local client = state.new("panel")

local snap = {}
local open = false
local mode = "list" -- "list" | "projects" | "edit"
local highlightId = nil
local confirmDeleteId = nil -- task id awaiting a delete confirmation
local actionId = nil -- task id whose complete/reopen pair is expanded
local actionHover = nil -- nil | "do" | "dismiss"
local expandedDescId = nil -- task id whose description is expanded inline

-- Row outline while the action pair is open, then the hovered action's tint.
local ACTION_OPEN = "outline/0.7"
local ACTION_DO = "#16A34A"
local ACTION_DISMISS = "#6B7280"

local statusText = nil
local statusKind = nil -- nil | "ok" | "err" | "warn"
local quickText = ""
local quickKey = 0

-- Undo state for task.complete. Captured before the row is removed so the
-- user has UNDO_TTL_MS to reverse the action via task.reopen.
-- Delete has no server-side restore, so undo is not offered for it.
local UNDO_TTL_MS = 5000
local undoTask = nil   -- full task object saved at complete time
local undoExpiry = nil -- noctalia.nowMs() + UNDO_TTL_MS

-- Edit form. Every keystroke lands in `edit`, so re-seeding an input (which
-- needs a new key) never loses in-progress text.
local editId = nil
local edit = nil
local editKey = 0
local editErr = nil

-- Forward declaration: callbacks defined above render() below.
local render
local defaultsSummary

local function view()
	return snap.view or "today"
end

local function projectName(id)
	for _, p in ipairs(snap.projects or {}) do
		if p.id == id then
			return p.name
		end
	end
	return nil
end

-- ui.select is 0-based for both selectedIndex and the onChange value; the
-- panel keeps 1-based indices and converts at the boundary.
local function selIdx(raw, n)
	local i = tonumber(raw)
	if i == nil then
		return 1
	end
	i = math.floor(i)
	if i < 0 then
		return 1
	end
	if i < n then
		return i + 1
	end
	return n
end

local function setStatus(kind, text)
	statusKind = kind
	statusText = text
	if open then
		render()
	end
end

local function errText(err)
	local kind = (type(err) == "table" and err.kind) or "server"
	local key = "err." .. tostring(kind)
	local s = noctalia.tr(key)
	-- todoist.tr falls back to the key itself when unknown
	if s == key then
		return noctalia.tr("err.server")
	end
	return s
end

-- ── actions ─────────────────────────────────────────────────────
local function openUrl(url)
	if type(url) ~= "string" or url == "" then
		return
	end
	if noctalia.commandExists("xdg-open") then
		noctalia.runAsync({ "xdg-open", url })
	else
		noctalia.copyToClipboard(url, "text/plain")
		setStatus("ok", noctalia.tr("ui.panel.link_copied"))
	end
end

local function goView(key)
	mode = "list"
	highlightId = nil
	actionId, actionHover = nil, nil
	expandedDescId = nil
	if client.send("tasks.fetch", { view = key }) then
		render()
	end
end

local function openProject(id)
	mode = "list"
	highlightId = nil
	actionId, actionHover = nil, nil
	expandedDescId = nil
	if client.send("tasks.fetch", { view = "project", project_id = id }) then
		render()
	end
end

local function submitQuick()
	local text = noctalia.string.trim(quickText)
	if text == "" or client.busy() then
		return
	end
	if client.send("task.create", { text = text }) then
		quickText = ""
		quickKey = quickKey + 1
		render()
	end
end

-- ── pieces ──────────────────────────────────────────────────────
local function header()
	return ui.row({ align = "center", gap = 6 }, {
		ui.label({
			text = noctalia.tr("ui.panel.title"),
			fontSize = 16,
			fontWeight = "bold",
			color = "primary",
			flexGrow = 1,
		}),
		ui.button({
			glyph = "refresh",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.refresh"),
			enabled = not client.busy(),
			onClick = function()
				if client.send("tasks.refresh", {}) then
					render()
				end
			end,
		}),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.settings"),
			onClick = function()
				noctalia.openSettings()
			end,
		}),
		ui.button({
			glyph = "x",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.close"),
			onClick = function()
				panel.close()
			end,
		}),
	})
end

local function tiles()
	local counts = snap.counts or {}
	local function tile(key, labelKey)
		local c = tonumber(counts[key]) or 0
		return ui.button({
			text = noctalia.tr(labelKey) .. (c > 0 and ("  " .. tostring(c)) or ""),
			variant = (mode == "list" and view() == key) and "primary" or "ghost",
			controlSize = "sm",
			onClick = function()
				goView(key)
			end,
		})
	end
	return ui.row({ gap = 6 }, {
		tile("overdue", "ui.panel.filter.overdue"),
		tile("today", "ui.panel.filter.today"),
		tile("p1", "ui.panel.filter.p1"),
	})
end

local function nav()
	local activeProjectId = nil
	local v = view()
	if mode == "list" and type(v) == "string" and v:match("^project:") then
		activeProjectId = v:sub(9)
	end
	local function tab(key, labelKey, active)
		return ui.button({
			text = noctalia.tr(labelKey),
			variant = active and "secondary" or "ghost",
			controlSize = "sm",
			onClick = function()
				if key == "__projects" then
					mode = "projects"
					render()
				else
					goView(key)
				end
			end,
		})
	end
	local items = {
		tab("today", "ui.panel.nav.today", mode == "list" and v == "today"),
		tab("inbox", "ui.panel.nav.inbox", mode == "list" and v == "inbox"),
		tab("__projects", "ui.panel.nav.projects", mode == "projects" or activeProjectId ~= nil),
		tab("completed", "ui.panel.nav.completed", mode == "list" and v == "completed"),
	}
	if activeProjectId then
		local name = projectName(activeProjectId)
		if name then
			items[#items + 1] = ui.label({
				text = "·  " .. name,
				fontSize = 12,
				color = MUTED,
				flexGrow = 1,
				maxLines = 1,
			})
		end
	end
	return ui.row({ gap = 6, align = "center" }, items)
end

-- ── undo ────────────────────────────────────────────────────────
local function clearUndo()
	undoTask = nil
	undoExpiry = nil
	render()
end

local function undoComplete()
	if undoTask == nil or client.busy() then
		return
	end
	local t = undoTask
	undoTask = nil
	undoExpiry = nil
	if client.send("task.reopen", { id = tostring(t.id) }) then
		render()
	end
end

-- Complete a task, or reopen it when it is already closed. Both are
-- idempotent server-side; an unknown outcome is resolved by refreshing rather
-- than by guessing.
local function toggleTask(t)
	if client.busy() then
		return
	end
	local id = tostring(t.id)
	local op = (t.checked == true) and "task.reopen" or "task.complete"
	-- Capture the task for undo before the row disappears (complete only;
	-- delete has no server-side restore so undo is not offered for it).
	if op == "task.complete" then
		undoTask = t
		undoExpiry = noctalia.nowMs() + UNDO_TTL_MS
	else
		-- Reopening cancels any pending undo for this task.
		undoTask = nil
		undoExpiry = nil
	end
	-- Collapse the pair first: this destroys the pressed button (the same shape
	-- as the delete confirmation) instead of flipping an `enabled` prop under
	-- the pointer. The reply then removes the row.
	if client.send(op, { id = id }) then
		actionId = nil
		actionHover = nil
		expandedDescId = nil
		render()
	end
end

-- Delete is idempotent, so re-sending is safe; the panel leaves that to the
-- service and only issues the op once.
local function deleteNow(id)
	if client.busy() then
		return
	end
	highlightId = id
	if client.send("task.delete", { id = id }) then
		confirmDeleteId = nil
		actionId = nil
		actionHover = nil
		expandedDescId = nil
		render()
	end
end

local function requestDelete(t)
	if client.busy() then
		return
	end
	local id = tostring(t.id)
	if noctalia.getConfig("confirm_delete") == false then
		deleteNow(id)
		return
	end
	confirmDeleteId = id
	actionId = nil
	actionHover = nil
	expandedDescId = nil
	render()
end

local function confirmRow(t)
	return ui.row({
		gap = 6,
		align = "center",
		key = "del" .. tostring(t.id),
		paddingV = 4,
		fill = true,
	}, {
		ui.label({ text = noctalia.tr("ui.panel.delete.confirm", { content = t.content }), flexGrow = 1, maxLines = 2, color = DANGER }),
		ui.button({
			text = noctalia.tr("ui.panel.delete.yes"),
			variant = "destructive",
			controlSize = "sm",
			onClick = function()
				deleteNow(tostring(t.id))
			end,
		}),
		ui.button({
			text = noctalia.tr("ui.panel.delete.no"),
			variant = "ghost",
			controlSize = "sm",
			onClick = function()
				confirmDeleteId = nil
				render()
			end,
		}),
	})
end

local openEdit -- defined with the edit form below; the row's pencil calls it

local function setActionHover(kind)
	if actionHover == kind then
		return
	end
	actionHover = kind
	render()
end

-- Named, not a closure: a closure gets a fresh generated callback name on every
-- render, and the reconciler answers a renamed hover prop by closing the hover
-- session, so the pointer's later leave would never fire and the tint would
-- stick. A named handler keeps its name across renders, so the session stays
-- open and the leave edge arrives.
function onActionHover(state, key)
	local kind = nil
	if state == "true" then
		local prefix = key:sub(1, 2)
		kind = (prefix == "do" and "do") or (prefix == "no" and "dismiss") or nil
	end
	setActionHover(kind)
end

-- Select a row to reveal its pair; select it again (or Not now) to collapse.
local function toggleAction(t)
	local id = tostring(t.id)
	if actionId == id then
		actionId = nil
	else
		actionId = id
	end
	actionHover = nil
	confirmDeleteId = nil
	render()
end

local function actionBar(t)
	local id = tostring(t.id)
	local closed = t.checked == true
	return ui.row({
		key = "aa" .. id,
		gap = 6,
		align = "center",
		paddingH = 6,
		paddingV = 2,
	}, {
		ui.button({
			key = "do" .. id,
			text = noctalia.tr(closed and "ui.panel.reopen" or "ui.panel.complete"),
			variant = "primary",
			controlSize = "sm",
			onHover = "onActionHover",
			onClick = function()
				toggleTask(t)
			end,
		}),
		ui.button({
			key = "no" .. id,
			text = noctalia.tr("ui.panel.action.not_now"),
			variant = "ghost",
			controlSize = "sm",
			onHover = "onActionHover",
			onClick = function()
				actionId = nil
				actionHover = nil
				render()
			end,
		}),
	})
end

local function hasDescription(t)
	return type(t.description) == "string" and noctalia.string.trim(t.description) ~= ""
end

local function toggleDescription(t)
	if not hasDescription(t) then
		return
	end
	local id = tostring(t.id)
	if expandedDescId == id then
		expandedDescId = nil
	else
		expandedDescId = id
	end
	render()
end

local function descriptionBlock(t)
	local id = tostring(t.id)
	return ui.row({
		key = "desc" .. id,
		paddingH = 32,
		paddingV = 2,
	}, {
		ui.label({
			text = t.description or "",
			color = MUTED,
			fontSize = 12,
			maxLines = 10,
		}),
	})
end

local function taskRow(t, border)
	local rowItems = {}

	local p = tonumber(t.p) or 4
	rowItems[#rowItems + 1] = ui.glyph({ name = "flag", size = 14, color = PCOLOR[p] or MUTED })
	local closed = t.checked == true
	rowItems[#rowItems + 1] = ui.button({
		key = "chk" .. tostring(t.id),
		glyph = closed and "circle-check" or "circle",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr(closed and "ui.panel.reopen" or "ui.panel.complete"),
		onClick = function()
			toggleAction(t)
		end,
	})

	local due = dates.formatDue(t.due)
	local metaParts = {}
	local pname = projectName(t.project_id)
	if pname then
		metaParts[#metaParts + 1] = pname
	end
	if due then
		metaParts[#metaParts + 1] = due.text
	end
	if tonumber(t.p) == 1 then
		metaParts[#metaParts + 1] = noctalia.tr("priority.p1")
	end
	if hasDescription(t) then
		local exp = expandedDescId == tostring(t.id)
		metaParts[#metaParts + 1] = exp and (noctalia.tr("ui.panel.edit.description") .. " ▴") or (noctalia.tr("ui.panel.edit.description") .. " ▾")
	end
	local sectionItems = {
		ui.label({ text = t.content, maxLines = 2 }),
	}
	if #metaParts > 0 then
		sectionItems[#sectionItems + 1] = ui.label({
			text = table.concat(metaParts, "  ·  "),
			fontSize = 11,
			color = (due and due.overdue) and DANGER or MUTED,
			maxLines = 1,
		})
	end
	rowItems[#rowItems + 1] = ui.column({ gap = 1, flexGrow = 1 }, sectionItems)

	rowItems[#rowItems + 1] = ui.button({
		glyph = "external-link",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr("ui.panel.open_in_todoist"),
		onClick = function()
			openUrl(t.url)
		end,
	})
	rowItems[#rowItems + 1] = ui.button({
		glyph = "link",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr("ui.panel.copy_link"),
		onClick = function()
			noctalia.copyToClipboard(t.url or "", "text/plain")
			setStatus("ok", noctalia.tr("ui.panel.link_copied"))
		end,
	})
	rowItems[#rowItems + 1] = ui.button({
		glyph = "pencil",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr("ui.panel.edit.open"),
		enabled = not client.busy(),
		onClick = function()
			openEdit(t)
		end,
	})
	rowItems[#rowItems + 1] = ui.button({
		glyph = "trash",
		variant = "ghost",
		controlSize = "sm",
		tooltip = noctalia.tr("ui.panel.delete.tooltip"),
		enabled = not client.busy(),
		onClick = function()
			requestDelete(t)
		end,
	})

	return ui.row({
		gap = 6,
		align = "center",
		key = "t" .. tostring(t.id),
		paddingV = 4,
		paddingH = 6,
		radius = 6,
		border = border,
		borderWidth = border and 1 or nil,
		onClick = function()
			toggleDescription(t)
		end,
	}, rowItems)
end

local function taskItem(t)
	local id = tostring(t.id)
	local expanded = actionId == id
	local border = nil
	if expanded then
		if actionHover == "do" then
			border = ACTION_DO
		elseif actionHover == "dismiss" then
			border = ACTION_DISMISS
		else
			border = ACTION_OPEN
		end
	end
	local children = { taskRow(t, border) }
	if expanded then
		children[#children + 1] = actionBar(t)
	end
	if expandedDescId == id and hasDescription(t) then
		children[#children + 1] = descriptionBlock(t)
	end
	return ui.column({ key = "ti" .. id, gap = 3 }, children)
end

local function undoRow()
	if undoTask == nil then
		return nil
	end
	return ui.row({
		key = "undo-row",
		gap = 6,
		align = "center",
		paddingV = 6,
		paddingH = 8,
		radius = 6,
		fill = "surface_variant/0.35",
	}, {
		ui.label({
			text = noctalia.tr("ui.panel.undo.completed", { content = undoTask.content }),
			flexGrow = 1,
			maxLines = 1,
			fontSize = 12,
		}),
		ui.button({
			text = noctalia.tr("ui.panel.undo.action"),
			variant = "secondary",
			controlSize = "sm",
			enabled = not client.busy(),
			onClick = undoComplete,
		}),
		ui.button({
			glyph = "x",
			variant = "ghost",
			controlSize = "sm",
			onClick = clearUndo,
		}),
	})
end

local function taskList()
	local tasks = snap.tasks or {}
	local rows = {}

	-- Undo toast: shown after a complete, auto-expires after UNDO_TTL_MS.
	local ur = undoRow()
	if ur ~= nil then
		rows[#rows + 1] = ur
	end

	if #tasks == 0 then
		rows[#rows + 1] = ui.label({
			text = snap.loading and noctalia.tr("ui.panel.loading") or noctalia.tr("ui.panel.tasks.empty"),
			color = MUTED,
		})
	else
		for _, t in ipairs(tasks) do
			if confirmDeleteId ~= nil and tostring(t.id) == confirmDeleteId then
				rows[#rows + 1] = confirmRow(t)
			else
				rows[#rows + 1] = taskItem(t)
			end
		end
	end

	-- Quick-add lives below the tasks inside the scroll so it floats down
	-- naturally as tasks are added and only scrolls away when the list is long.
	rows[#rows + 1] = ui.separator({ key = "qa-sep" })
	rows[#rows + 1] = ui.row({ key = "qa-row", gap = 6, align = "center" }, {
		ui.input({
			key = "quick" .. tostring(quickKey),
			value = "",
			placeholder = noctalia.tr("ui.panel.quick.placeholder"),
			flexGrow = 1,
			controlSize = "md",
			enabled = not client.busy(),
			onChange = function(text)
				quickText = text or ""
			end,
			onSubmit = function()
				submitQuick()
			end,
		}),
		ui.button({
			glyph = "plus",
			text = noctalia.tr("ui.panel.quick.add"),
			variant = "primary",
			controlSize = "md",
			enabled = (not client.busy()) and noctalia.string.trim(quickText) ~= "",
			onClick = function()
				submitQuick()
			end,
		}),
	})
	rows[#rows + 1] = ui.label({
		key = "qa-hint",
		text = noctalia.tr("ui.panel.quick.hint"),
		fontSize = 11,
		color = MUTED,
		maxLines = 2,
	})
	local summary = defaultsSummary()
	if summary then
		rows[#rows + 1] = ui.label({
			key = "qa-defaults",
			text = noctalia.tr("ui.panel.quick.defaults", { summary = summary }),
			fontSize = 11,
			color = MUTED,
			maxLines = 1,
		})
	end

	return ui.scroll({
		flexGrow = 1,
		fill = true,
		revealKey = highlightId,
	}, rows)
end

local function completedList()
	local tasks = snap.tasks or {}
	if #tasks == 0 then
		if snap.loading then
			return ui.label({ text = noctalia.tr("ui.panel.loading"), color = MUTED })
		end
		return ui.label({ text = noctalia.tr("ui.panel.tasks.completed_empty"), color = MUTED })
	end
	local rows = {}
	for _, t in ipairs(tasks) do
		-- Completed rows: circle (reopen), title + meta, open-in-Todoist only.
		-- No edit, no delete, no action expand — the task is already done.
		local p = tonumber(t.p) or 4
		local metaParts = {}
		local pname = projectName(t.project_id)
		if pname then metaParts[#metaParts + 1] = pname end
		if t.completed_at then
			-- Show date only, not full ISO timestamp.
			local d = tostring(t.completed_at):sub(1, 10)
			metaParts[#metaParts + 1] = d
		end
		local sectionItems = { ui.label({ text = t.content, maxLines = 2 }) }
		if #metaParts > 0 then
			sectionItems[#sectionItems + 1] = ui.label({
				text = table.concat(metaParts, "  ·  "),
				fontSize = 11,
				color = MUTED,
				maxLines = 1,
			})
		end
		rows[#rows + 1] = ui.row({
			gap = 6,
			align = "center",
			key = "ct" .. tostring(t.id),
			paddingV = 4,
			paddingH = 6,
			radius = 6,
		}, {
			ui.glyph({ name = "flag", size = 14, color = PCOLOR[p] or MUTED }),
			ui.button({
				key = "cchk" .. tostring(t.id),
				glyph = "circle-check",
				variant = "ghost",
				controlSize = "sm",
				tooltip = noctalia.tr("ui.panel.reopen"),
				enabled = not client.busy(),
				onClick = function()
					if client.busy() then return end
					if client.send("task.reopen", { id = tostring(t.id) }) then
						render()
					end
				end,
			}),
			ui.column({ gap = 1, flexGrow = 1 }, sectionItems),
			ui.button({
				glyph = "external-link",
				variant = "ghost",
				controlSize = "sm",
				tooltip = noctalia.tr("ui.panel.open_in_todoist"),
				onClick = function() openUrl(t.url) end,
			}),
		})
	end
	return ui.scroll({ flexGrow = 1, fill = true }, rows)
end

local function projectList()
	local projects = snap.projects or {}
	if #projects == 0 then
		return ui.label({ text = noctalia.tr("ui.panel.projects.empty"), color = MUTED })
	end
	local rows = {}
	for _, p in ipairs(projects) do
		rows[#rows + 1] = ui.button({
			text = (p.inbox and ("[Inbox]  " .. p.name) or p.name),
			variant = "ghost",
			contentAlign = "start",
			key = "p" .. tostring(p.id),
			onClick = function()
				openProject(p.id)
			end,
		})
	end
	return ui.scroll({ flexGrow = 1, fill = true }, rows)
end

-- ── edit form ───────────────────────────────────────────────────
local function findTask(id)
	if id == nil then
		return nil
	end
	id = tostring(id)
	for _, t in ipairs(snap.tasks or {}) do
		if tostring(t.id) == id then
			return t
		end
	end
	for _, v in pairs(snap.views or {}) do
		if type(v) == "table" and type(v.tasks) == "table" then
			for _, t in ipairs(v.tasks) do
				if tostring(t.id) == id then
					return t
				end
			end
		end
	end
	return nil
end

local function dueRaw(due)
	if type(due) ~= "table" then
		return ""
	end
	return due.string or due.date or ""
end

local function splitLabels(text)
	local out, seen = {}, {}
	for part in tostring(text or ""):gmatch("[^,]+") do
		local name = noctalia.string.trim(part)
		if name ~= "" and not seen[name] then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	return out
end

local function sameSet(a, b)
	local function key(list)
		local t = {}
		for _, v in ipairs(list or {}) do
			t[tostring(v)] = true
		end
		return t
	end
	local ka, kb = key(a), key(b)
	for k in pairs(ka) do
		if not kb[k] then
			return false
		end
	end
	for k in pairs(kb) do
		if not ka[k] then
			return false
		end
	end
	return true
end

local function projectOptions()
	local out = {}
	for _, p in ipairs(snap.projects or {}) do
		out[#out + 1] = { id = p.id, name = p.name or "" }
	end
	table.sort(out, function(a, b)
		local ai = a.id == snap.inbox_project_id
		local bi = b.id == snap.inbox_project_id
		if ai ~= bi then
			return ai
		end
		return a.name:lower() < b.name:lower()
	end)
	return out
end

local function knownLabelNames()
	local out = {}
	for _, l in ipairs(snap.labels or {}) do
		if type(l.name) == "string" and l.name ~= "" then
			out[#out + 1] = l.name
		end
	end
	return out
end

local function priorityLabels()
	return {
		noctalia.tr("priority.p1"),
		noctalia.tr("priority.p2"),
		noctalia.tr("priority.p3"),
		noctalia.tr("priority.p4"),
	}
end

openEdit = function(t)
	if t == nil or client.busy() then
		return
	end
	editId = tostring(t.id)
	actionId, actionHover = nil, nil
	expandedDescId = nil
	editKey = editKey + 1
	editErr = nil
	edit = {
		content = t.content or "",
		description = t.description or "",
		priority = tonumber(t.p) or 4,
		due = dueRaw(t.due),
		project_id = t.project_id,
		section_id = t.section_id,
		labelsText = table.concat(t.labels or {}, ", "),
	}
	mode = "edit"
	-- Populate the label and section pickers for this project.
	client.send("meta.load", { project_id = t.project_id })
	render()
end

local function closeEdit()
	editId = nil
	edit = nil
	editErr = nil
	mode = "list"
	render()
end

-- Re-read the task from the snapshot after a mutation. Returns false when it
-- is gone (deleted elsewhere), which the caller turns into a close.
local function reseedEdit()
	local t = findTask(editId)
	if t == nil then
		return false
	end
	edit.content = t.content or ""
	edit.description = t.description or ""
	edit.priority = tonumber(t.p) or 4
	edit.due = dueRaw(t.due)
	edit.project_id = t.project_id
	edit.section_id = t.section_id
	edit.labelsText = table.concat(t.labels or {}, ", ")
	-- Re-seed the inputs, which only happens on a new key.
	editKey = editKey + 1
	return true
end

-- Only the fields that actually differ are sent. Priority crosses the client
-- (1 = highest) / API (4 = highest) boundary here.
local function editDiff()
	local t = findTask(editId)
	if t == nil or edit == nil then
		return {}, false
	end
	local c = {}
	local content = noctalia.string.trim(edit.content or "")
	if content ~= (t.content or "") and content ~= "" then
		c.content = content
	end
	local desc = edit.description or ""
	if desc ~= (t.description or "") then
		c.description = desc
	end
	local p = tonumber(edit.priority) or 4
	if p ~= (tonumber(t.p) or 4) then
		c.priority = 5 - p
	end
	local due = edit.due or ""
	if due ~= dueRaw(t.due) then
		c.due_string = (due == "") and "no date" or due
	end
	if not sameSet(splitLabels(edit.labelsText), t.labels) then
		c.labels = splitLabels(edit.labelsText)
	end
	local moved = (edit.project_id ~= t.project_id)
		or ((edit.section_id or nil) ~= (t.section_id or nil))
	return c, moved
end

local function saveEdit()
	if edit == nil or editId == nil or client.busy() then
		return
	end
	if noctalia.string.trim(edit.content or "") == "" then
		editErr = noctalia.tr("ui.panel.edit.content_required")
		render()
		return
	end
	local c, moved = editDiff()
	if next(c) == nil then
		if moved then
			-- Only the project/section changed: Save cannot do that, Move can.
			editErr = noctalia.tr("ui.panel.edit.save_use_move")
			render()
			return
		end
		closeEdit()
		return
	end
	editErr = nil
	if client.send("task.update", { id = editId, changes = c }) then
		render()
	end
end

local function moveEdit()
	if edit == nil or editId == nil or client.busy() then
		return
	end
	local _, moved = editDiff()
	if not moved then
		editErr = noctalia.tr("ui.panel.edit.move_no_change")
		render()
		return
	end
	editErr = nil
	if client.send("task.move", { id = editId, project_id = edit.project_id, section_id = edit.section_id }) then
		render()
	end
end

local function editForm()
	if edit == nil then
		return ui.label({ text = "" })
	end

	-- NOTE: the "Edit task" heading is rendered outside this scroll in render(),
	-- so it stays pinned at the top while the user scrolls through the fields.
	local items = {}

	items[#items + 1] = ui.input({
		key = "ec" .. tostring(editKey),
		value = edit.content,
		placeholder = noctalia.tr("ui.panel.edit.content"),
		onChange = function(v)
			edit.content = v or ""
		end,
	})

	items[#items + 1] = ui.label({ text = noctalia.tr("ui.panel.edit.description") })
	items[#items + 1] = ui.input({
		key = "ed" .. tostring(editKey),
		value = edit.description,
		multiline = true,
		placeholder = noctalia.tr("ui.panel.edit.description_ph"),
		onChange = function(v)
			edit.description = v or ""
		end,
	})

	local popts = priorityLabels()
	local pidx = math.max(1, math.min(4, tonumber(edit.priority) or 4))
	items[#items + 1] = ui.row({ gap = 8 }, {
		ui.column({ flexGrow = 1 }, {
			ui.label({ text = noctalia.tr("ui.panel.edit.priority") }),
			ui.select({
				options = popts,
				selectedIndex = pidx - 1,
				onChange = function(v)
					edit.priority = selIdx(v, #popts)
					render()
				end,
			}),
		}),
		ui.column({ flexGrow = 2 }, {
			ui.label({ text = noctalia.tr("ui.panel.edit.due") }),
			ui.row({ gap = 4, align = "center" }, {
				ui.input({
					key = "edu" .. tostring(editKey),
					value = edit.due,
					placeholder = noctalia.tr("ui.panel.edit.due_ph"),
					flexGrow = 1,
					onChange = function(v)
						edit.due = v or ""
					end,
				}),
				ui.button({
					glyph = "x",
					variant = "ghost",
					controlSize = "sm",
					tooltip = noctalia.tr("ui.panel.edit.clear_due"),
					onClick = function()
						edit.due = ""
						editKey = editKey + 1
						render()
					end,
				}),
			}),
		}),
	})

	local projects = projectOptions()
	local psel = 1
	for i, p in ipairs(projects) do
		if p.id == edit.project_id then
			psel = i
			break
		end
	end
	local pnames = {}
	for i, p in ipairs(projects) do
		pnames[i] = (p.id == snap.inbox_project_id) and ("[Inbox]  " .. p.name) or p.name
	end
	if #pnames == 0 then
		pnames = { noctalia.tr("ui.panel.edit.no_project") }
	end

	local secs = (edit.project_id and snap.sections and snap.sections[edit.project_id]) or {}
	local sopts = { noctalia.tr("ui.panel.edit.no_section") }
	local ssel = 1
	for i, s in ipairs(secs) do
		sopts[#sopts + 1] = s.name
		if s.id == edit.section_id then
			ssel = i + 1
		end
	end

	items[#items + 1] = ui.row({ gap = 8 }, {
		ui.column({ flexGrow = 1 }, {
			ui.label({ text = noctalia.tr("ui.panel.edit.project") }),
			ui.select({
				options = pnames,
				selectedIndex = psel - 1,
				onChange = function(v)
					local i = selIdx(v, #projects)
					local picked = projects[i]
					if picked ~= nil then
						edit.project_id = picked.id
						-- A section belongs to one project: never carry it over.
						edit.section_id = nil
						client.send("meta.load", { project_id = picked.id })
						render()
					end
				end,
			}),
		}),
		ui.column({ flexGrow = 1 }, {
			ui.label({ text = noctalia.tr("ui.panel.edit.section") }),
			ui.select({
				options = sopts,
				selectedIndex = ssel - 1,
				enabled = #secs > 0,
				onChange = function(v)
					local i = selIdx(v, #sopts)
					edit.section_id = secs[i - 1] and secs[i - 1].id or nil
					render()
				end,
			}),
		}),
	})
	if #secs == 0 then
		items[#items + 1] = ui.label({
			text = noctalia.tr("ui.panel.edit.no_sections"),
			fontSize = 11,
			color = MUTED,
			maxLines = 1,
		})
	end

	items[#items + 1] = ui.label({ text = noctalia.tr("ui.panel.edit.labels") })
	items[#items + 1] = ui.input({
		key = "el" .. tostring(editKey),
		value = edit.labelsText,
		placeholder = noctalia.tr("ui.panel.edit.labels_ph"),
		onChange = function(v)
			edit.labelsText = v or ""
		end,
	})
	local known = knownLabelNames()
	if #known > 0 then
		items[#items + 1] = ui.label({
			text = noctalia.tr("ui.panel.edit.labels_known", { labels = table.concat(known, ", ") }),
			fontSize = 11,
			color = MUTED,
			maxLines = 2,
		})
	end

	if editErr then
		items[#items + 1] = ui.label({ text = editErr, color = DANGER, maxLines = 2 })
	end

	items[#items + 1] = ui.row({ gap = 6, align = "center" }, {
		ui.button({
			text = noctalia.tr("ui.panel.edit.save"),
			variant = "primary",
			controlSize = "sm",
			-- Text inputs are uncontrolled and do not re-render on every keystroke,
			-- so a diff-driven `enabled` would stay false while typing. Gate on the
			-- in-flight command only; the handlers no-op when nothing changed.
			enabled = not client.busy(),
			onClick = saveEdit,
		}),
		ui.button({
			text = noctalia.tr("ui.panel.edit.move"),
			variant = "secondary",
			controlSize = "sm",
			enabled = not client.busy(),
			onClick = moveEdit,
		}),
		ui.button({
			text = noctalia.tr("ui.panel.edit.cancel"),
			variant = "ghost",
			controlSize = "sm",
			enabled = not client.busy(),
			onClick = closeEdit,
		}),
	})

	return ui.scroll({ flexGrow = 1, fill = true }, {
		ui.column({ gap = 8 }, items),
	})
end

local function body()
	if snap.token_configured == false then
		return ui.label({ text = noctalia.tr("ui.panel.not_configured"), color = DANGER, maxLines = 3 })
	end
	if mode == "edit" then
		return editForm()
	end
	if mode == "projects" then
		return projectList()
	end
	if mode == "list" and view() == "completed" then
		return completedList()
	end
	return taskList()
end

local function footer()
	-- Resolve the status/error banner (shared by all modes).
	local banner = nil
	if snap.error then
		banner = ui.label({
			text = errText(snap.error),
			color = (snap.error.kind == "auth") and DANGER or MUTED,
			maxLines = 2,
		})
	elseif statusText then
		banner = ui.label({
			text = statusText,
			color = (statusKind == "err" and DANGER) or (statusKind == "warn" and "#f5a524") or MUTED,
			maxLines = 2,
		})
	end

	-- In edit mode there is no quick-add and no separator: the edit scroll
	-- needs every pixel. Only the banner (if any) is shown.
	if mode == "edit" then
		if banner then
			return banner
		end
		return nil
	end

	-- List / projects mode: separator + optional banner. Quick-add now lives
	-- inside the taskList() scroll so it is not duplicated here.
	local items = { ui.separator({}) }
	if banner then
		items[#items + 1] = banner
	end
	return ui.column({ gap = 8 }, items)
end

defaultsSummary = function()
	local d = snap.defaults or {}
	local parts = {}
	if type(d.project) == "string" and noctalia.string.trim(d.project) ~= "" then
		parts[#parts + 1] = "#" .. noctalia.string.trim(d.project)
	end
	if type(d.labels) == "table" then
		for _, l in ipairs(d.labels) do
			if type(l) == "string" and noctalia.string.trim(l) ~= "" then
				parts[#parts + 1] = "@" .. noctalia.string.trim(l)
			end
		end
	end
	if type(d.priority) == "string" and d.priority ~= "" and d.priority ~= "none" then
		parts[#parts + 1] = d.priority
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

render = function()
	local items = { header() }
	-- The form takes the whole body: navigation and the quick-add footer would
	-- only compete with it for space.
	if mode ~= "edit" then
		items[#items + 1] = tiles()
		items[#items + 1] = nav()
	else
		-- Pin the heading above the scroll so it stays visible while the user
		-- scrolls through all the edit fields.
		items[#items + 1] = ui.label({
			text = noctalia.tr("ui.panel.edit.heading"),
			fontSize = 14,
			fontWeight = "bold",
			maxLines = 1,
		})
	end
	items[#items + 1] = body()
	local f = footer()
	if f ~= nil then
		items[#items + 1] = f
	end
	panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1 }, items))
end

-- ── protocol ────────────────────────────────────────────────────
noctalia.state.watch("todoist", function(msg)
	if type(msg) ~= "table" then
		return
	end
	snap = msg
	if open then
		render()
	end
end)

noctalia.state.watch("svc_boot", function()
	-- The service restarted: any in-flight command died with its old VM.
	if client.busy() then
		client.abandon()
		setStatus("warn", noctalia.tr("err.timeout"))
	end
end)

noctalia.state.watch("evt.panel", function(msg)
	local op = client.take(msg)
	if op == nil then
		return
	end
	if op == "ping" then
		if msg.ok then
			setStatus("ok", noctalia.tr("ui.panel.status.ok"))
		else
			setStatus("err", errText(msg.err))
		end
	elseif op == "task.create" then
		if msg.ok then
			snap.error = nil
			setStatus("ok", noctalia.tr("ui.panel.quick.sent"))
			noctalia.notify(noctalia.tr("notify.created"))
		elseif msg.unknown_outcome then
			setStatus("warn", noctalia.tr("err.unknown_outcome"))
			noctalia.notifyError(noctalia.tr("notify.unknown"), noctalia.tr("err.unknown_outcome"))
			quickKey = quickKey + 1
		else
			setStatus("err", errText(msg.err))
			noctalia.notifyError(noctalia.tr("notify.failed"), errText(msg.err))
		end
		render()
	elseif op == "task.complete" or op == "task.reopen" or op == "task.delete" then
		if msg.ok then
			snap.error = nil
			statusKind, statusText = nil, nil
		elseif msg.unknown_outcome then
			-- The mutation may or may not have landed: re-read rather than
			-- retry, so we never close or reopen a task twice.
			setStatus("warn", noctalia.tr("err.unknown_outcome_refresh"))
			-- Undo is no longer safe: we don't know whether the action landed.
			undoTask = nil
			undoExpiry = nil
			client.send("tasks.refresh", {})
		else
			setStatus("err", errText(msg.err))
			-- Complete failed: the task was never removed, so undo is moot.
			undoTask = nil
			undoExpiry = nil
		end
		render()
	elseif op == "task.update" or op == "task.move" then
		if msg.ok then
			snap.error = nil
			statusKind, statusText = nil, nil
			if editId ~= nil then
				-- The service already replaced the row from the server object;
				-- re-read it so the form shows the truth and its buttons agree.
				if reseedEdit() then
					local changes, moved = editDiff()
					if next(changes) == nil and not moved then
						closeEdit()
					else
						render()
					end
				else
					closeEdit()
				end
			else
				render()
			end
		elseif msg.unknown_outcome then
			setStatus("warn", noctalia.tr("err.unknown_outcome_refresh"))
			client.send("tasks.refresh", {})
		else
			editErr = errText(msg.err)
			setStatus("err", editErr)
		end
		render()
	elseif op == "meta.load" then
		if not msg.ok then
			setStatus("warn", errText(msg.err))
		end
		render()
	elseif op == "tasks.fetch" or op == "tasks.refresh" then
		if msg.ok then
			snap.error = nil
			if statusKind ~= "ok" then
				statusText = nil
			end
		else
			setStatus("err", errText(msg.err))
		end
		render()
	end
end)

-- ── lifecycle ───────────────────────────────────────────────────
function onOpen(_context)
	open = true
	local current = noctalia.state.get("todoist")
	if type(current) == "table" then
		snap = current
	end

	-- Deep link from the launcher: switch to the task's project and reveal it.
	local focus = noctalia.state.get("open_task")
	if type(focus) == "table" and focus.id ~= nil then
		noctalia.state.set("open_task", nil)
		highlightId = tostring(focus.id)
		if type(focus.project_id) == "string" and focus.project_id ~= "" then
			mode = "list"
			client.send("tasks.fetch", { view = "project", project_id = focus.project_id })
		end
	end

	render()
end

function onClose()
	open = false
	client.abandon()
	highlightId = nil
	actionId, actionHover = nil, nil
	expandedDescId = nil
	undoTask = nil
	undoExpiry = nil
end

function update()
	if not open then
		return
	end
	if client.watchdog() then
		setStatus("warn", noctalia.tr("err.timeout"))
		render()
	end
	-- Auto-expire the undo toast when the window has passed.
	if undoExpiry ~= nil and noctalia.nowMs() > undoExpiry then
		clearUndo()
	end
end
