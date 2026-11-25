--!nonstrict
-- ui_nav.luau
-- Header chrome, filter tiles, and segmented navigation tabs.
local theme = require("./theme.luau")

local M = {}

function M.header(props)
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
			enabled = not props.busy,
			onClick = props.onRefresh,
		}),
		ui.button({
			glyph = "help-circle",
			variant = (props.mode == "help") and "secondary" or "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.help"),
			onClick = props.onToggleHelp,
		}),
		ui.button({
			glyph = "settings",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.settings"),
			onClick = props.onOpenSettings,
		}),
		ui.button({
			glyph = "x",
			variant = "ghost",
			controlSize = "sm",
			tooltip = noctalia.tr("ui.panel.close"),
			onClick = props.onClose,
		}),
	})
end

function M.tiles(props)
	local counts = props.counts or {}
	local function tile(key, labelKey, glyphName)
		local c = tonumber(counts[key]) or 0
		return ui.button({
			glyph = glyphName,
			text = noctalia.tr(labelKey) .. (c > 0 and ("  " .. tostring(c)) or ""),
			variant = (props.mode == "list" and props.activeView == key) and "primary" or "ghost",
			controlSize = "sm",
			onClick = function()
				props.onSelectView(key)
			end,
		})
	end
	return ui.row({ gap = 6, align = "center" }, {
		tile("overdue", "ui.panel.filter.overdue", "alert-circle"),
		tile("today", "ui.panel.filter.today", "clock"),
		tile("p1", "ui.panel.filter.p1", "flag"),
	})
end

function M.nav(props)
	local activeProjectId = nil
	local v = props.activeView
	if props.mode == "list" and type(v) == "string" and v:match("^project:") then
		activeProjectId = v:sub(9)
	end
	local function tab(key, labelKey, glyphName, active)
		return ui.button({
			glyph = glyphName,
			text = noctalia.tr(labelKey),
			variant = active and "secondary" or "ghost",
			controlSize = "sm",
			onClick = function()
				if key == "__projects" then
					props.onSelectProjects()
				else
					props.onSelectView(key)
				end
			end,
		})
	end
	local items = {
		tab("today", "ui.panel.nav.today", "calendar", props.mode == "list" and v == "today"),
		tab("inbox", "ui.panel.nav.inbox", "inbox", props.mode == "list" and v == "inbox"),
		tab("__projects", "ui.panel.nav.projects", "folder", props.mode == "projects" or activeProjectId ~= nil),
		tab("completed", "ui.panel.nav.completed", "circle-check", props.mode == "list" and v == "completed"),
	}
	if activeProjectId and props.projectName then
		local name = props.projectName(activeProjectId)
		if name then
			items[#items + 1] = ui.label({
				text = "·  " .. name,
				fontSize = 12,
				color = theme.MUTED,
				flexGrow = 1,
				maxLines = 1,
			})
		end
	end
	return ui.row({
		gap = 4,
		align = "center",
		fill = "surface_container_highest/0.4",
		radius = 8,
		paddingH = 4,
		paddingV = 3,
	}, items)
end

return M
