--!nonstrict
-- Model catalog view: the /v1/models list, filtered and rendered as ui.* rows.
-- Kept in its own module so panel.luau stays about the panel shell (tabs,
-- header, refresh) and the catalog stays about the catalog.

local util = require("./util.luau")

local M = {}

local function context(value)
	if type(value) ~= "number" then
		return nil
	end
	if value >= 1000 then
		return string.format("%dK", math.floor(value / 1000))
	end
	return string.format("%d", value)
end

local function price(value)
	if type(value) ~= "number" then
		return "—"
	end
	return string.format("%g", value)
end

local function chip(text, color)
	return ui.row({
		paddingH = 7,
		paddingV = 2,
		radius = 5,
		align = "center",
		justify = "center",
		fill = color .. "/0.12",
	}, {
		ui.label({ text = text, fontSize = 10, fontWeight = "bold", color = color }),
	})
end

-- Matches on the name, the id and the provider, case-insensitively.
function M.filter(list, query)
	if query == "" then
		return list
	end
	local needle = string.lower(query)
	local out = {}
	for _, m in ipairs(list) do
		local name = m.name and string.lower(m.name) or ""
		local id = m.id and string.lower(m.id) or ""
		local provider = m.provider and string.lower(m.provider) or ""
		if string.find(name, needle, 1, true) or string.find(id, needle, 1, true) or string.find(provider, needle, 1, true) then
			table.insert(out, m)
		end
	end
	return out
end

-- One catalog entry: identity, then the numbers that decide a call, then the
-- capability flags. No card chrome — a hairline separator carries the grouping.
function M.row(m)
	local head = {
		ui.label({ text = m.name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
	}
	if m.provider then
		table.insert(head, ui.label({ text = m.provider, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
	end
	table.insert(head, ui.spacer({ flexGrow = 1 }))
	if m.deprecated then
		table.insert(head, chip(noctalia.tr("models.deprecated"), "error"))
	end

	local children = { ui.row({ align = "center", gap = 6 }, head) }

	local limits = {}
	local ctx = context(m.context)
	if ctx then
		table.insert(limits, string.format("%s ctx", ctx))
	end
	local out = context(m.outputLimit)
	if out then
		table.insert(limits, string.format("%s out", out))
	end

	local pricing = noctalia.tr("models.price_tbd")
	if not m.pricingTbd and m.inputPrice then
		pricing = string.format("$%s in · $%s out /M", price(m.inputPrice), price(m.outputPrice))
	end

	table.insert(children, ui.row({ align = "center", gap = 8 }, {
		ui.label({ text = table.concat(limits, " · "), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({ text = pricing, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
	}))

	local caps = {}
	if m.tools then
		table.insert(caps, "tools")
	end
	if m.vision then
		table.insert(caps, "vision")
	end
	if m.reasoning then
		table.insert(caps, "reasoning")
	end
	if m.json then
		table.insert(caps, "json")
	end
	if m.streaming then
		table.insert(caps, "streaming")
	end
	if #caps > 0 then
		table.insert(children, ui.label({
			text = table.concat(caps, " · "),
			fontSize = 10,
			color = "secondary",
			maxLines = 1,
		}))
	end

	return ui.column({ key = "model-" .. tostring(m.id), gap = 4, paddingV = 7, align = "stretch" }, children)
end

function M.rows(list)
	local nodes = {}
	for index, m in ipairs(list) do
		if index > 1 then
			table.insert(nodes, ui.separator({ spacing = 0, color = "outline_variant/0.25" }))
		end
		table.insert(nodes, M.row(m))
	end
	return nodes
end

return M
