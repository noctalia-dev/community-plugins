--!nonstrict
-- Desktop widget: update counts as a compact card (system palette roles), with
-- the five most recent pending packages from the repos and AUR.

local core = require("./core.luau")
core.init("desktop")

local function section(title, count, list, accentColor)
	local countText = count == nil and "…" or tostring(count)
	local rows = {
		ui.row({ align = "center", paddingH = 4, paddingV = 2 }, {
			ui.label({ text = title, fontSize = 14, fontWeight = "bold", color = accentColor }),
			ui.spacer({ flexGrow = 1 }),
			ui.row({
				fill = accentColor .. "/0.18",
				radius = 6,
				paddingH = 7,
				paddingV = 2,
				align = "center",
			}, {
				ui.label({
					text = countText,
					fontSize = 13,
					fontWeight = "bold",
					color = (count and count > 0) and accentColor or "on_surface_variant",
				}),
			}),
		}),
	}
	if list == nil then
		table.insert(rows, ui.label({ text = "checking…", fontSize = 13, color = "on_surface_variant" }))
	elseif #list == 0 then
		table.insert(rows, ui.label({ text = "up to date", fontSize = 13, color = "on_surface_variant" }))
	else
		for _, e in ipairs(list) do
			table.insert(rows, ui.row({ align = "center", paddingH = 4, paddingV = 1 }, {
				ui.label({
					text = e.name,
					fontSize = 14,
					color = "on_surface",
					maxLines = 1,
					flexGrow = 1,
				}),
			}))
		end
	end
	return ui.column({
		gap = 3,
	}, rows)
end

function render()
	local total = (core.repoPending or 0) + (core.aurPending or 0)
	local totalText = (core.repoPending == nil and core.aurPending == nil) and "…" or tostring(total)
	local infoParts = {}
	if core.lastUpdatedAt then
		table.insert(infoParts, "last update: " .. os.date("%d %b %H:%M", core.lastUpdatedAt))
	end
	if core.lastCheckAt then
		local fmt = os.date("%Y-%m-%d", core.lastCheckAt) == os.date("%Y-%m-%d") and "%H:%M" or "%d %b %H:%M"
		table.insert(infoParts, "checked: " .. os.date(fmt, core.lastCheckAt))
	end
	local infoText = table.concat(infoParts, " · ")

	local headerRow = ui.row({ gap = 8, align = "center" }, {
		ui.glyph({ name = "package", size = 18, color = "primary" }),
		ui.label({ text = totalText .. " pending", fontSize = 16, fontWeight = "bold", color = "primary" }),
		ui.spacer({ flexGrow = 1 }),
		ui.button({
			glyph = core.checking and "loader" or "refresh",
			glyphSize = 14,
			variant = "ghost",
			width = 24,
			height = 24,
			enabled = not core.checking,
			onClick = "onRefresh",
			tooltip = "Check for updates",
		}),
	})

	local headerColChildren = { headerRow }
	if infoText ~= "" then
		table.insert(headerColChildren, ui.label({
			text = infoText,
			fontSize = 12,
			color = "on_surface_variant",
		}))
	end

	desktopWidget.render(ui.column({
		paddingH = 12,
		paddingV = 10,
		gap = 8,
		width = 280,
		height = 340,
	}, {
		ui.column({ gap = 2, paddingH = 4 }, headerColChildren),
		ui.column({ gap = 8 }, {
			section("REPO", core.repoPending, core.repoList, "primary"),
			ui.row({ height = 1, fill = "on_surface/0.08" }),
			section("AUR", core.aurPending, core.aurList, "tertiary"),
		}),
	}))
end

function update()
	noctalia.setUpdateInterval(core.checking and 5000 or 60000)
	core.tick(render)
end

function onRefresh()
	core.check(render)
end

-- `noctalia msg plugin 7sarus/archup:updates-desktop all refresh`
function onIpc(event)
	if event == "refresh" then
		core.check(render)
	end
end

core.loadState()
render()
core.check(render)
core.refreshLastUpdated(render)
