--!nonstrict
-- Details panel entry: two tabs in one surface — the account's usage (quota,
-- allowance, this month, carbon, account) and the model catalog. One panel
-- means the catalog opens exactly where the usage view is, instead of a second
-- surface that has to guess its own position.
--
--   panel.render(tree)                  declarative ui.* tree
--   noctalia.state.watch("quota", cb)   re-render when the service publishes
--   noctalia.state.set("quota.cmd", n)  ask the service to refetch now
--   onIpc(event)                        `noctalia msg plugin <id>:usage all refresh`

local util = require("./lib/util.luau")
local catalog = require("./lib/catalog.luau")

local TABS = {
	{ id = "usage", key = "tabs.usage" },
	{ id = "models", key = "tabs.models" },
}

local quota = noctalia.state.get("quota")
local energy = noctalia.state.get("energy")
local models = noctalia.state.get("models")
local busy = false
local tab = "usage"
local query = ""
-- The countdown string currently on screen, so the second tick only re-renders
-- when it actually changes.
local lastCountdown = nil

-- Forward declaration: the tab callbacks below are closures that re-render, and
-- a `local function render` declared later would not be in their scope (they
-- would capture the global, which is nil).
local render

local STATUS_KEY = {
	active = "substatus.active",
	canceling = "substatus.canceling",
	past_due = "substatus.past_due",
	paused = "substatus.paused",
	trialing = "substatus.trialing",
}
local INTERVAL_KEY = { month = "interval.month", year = "interval.year" }

local function mapped(value, map)
	if type(value) ~= "string" then
		return "—"
	end
	local key = map[value]
	return key and noctalia.tr(key) or value
end

-- ── ui helpers ───────────────────────────────────────────────────────────────

local function chip(text, color, size, weight)
	return ui.row({
		paddingH = 7,
		paddingV = 2,
		radius = 5,
		align = "center",
		justify = "center",
		fill = color .. "/0.12",
	}, {
		ui.label({ text = text, fontSize = size or 11, fontWeight = weight or "bold", color = color }),
	})
end

-- Key/value line: the panel's whole vocabulary. A section is a heading plus
-- these, never a bordered card.
local function kv(key, value, color)
	return ui.row({ align = "center", gap = 8 }, {
		ui.label({ text = key, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({ text = value, fontSize = 12, fontWeight = "semibold", color = color or "on_surface", maxLines = 1 }),
	})
end

local function section(title, rows, trailing)
	local head = {
		ui.label({ text = title, fontSize = 11, fontWeight = "bold", color = "on_surface_variant", maxLines = 1 }),
	}
	if trailing then
		table.insert(head, ui.spacer({ flexGrow = 1 }))
		table.insert(head, trailing)
	end
	local children = { ui.row({ align = "center", gap = 8 }, head) }
	for _, row in ipairs(rows) do
		table.insert(children, row)
	end
	return ui.column({ gap = 5, align = "stretch" }, children)
end

local function divider()
	return ui.separator({ spacing = 11, color = "outline/0.35" })
end

-- ── usage sections ───────────────────────────────────────────────────────────

local function subscriptionSection(q)
	-- Recomputed per render, not read from state: a countdown cached at poll time
	-- would stay frozen for up to a full refresh interval.
	local renews = util.countdown(q.periodEnd)
	if renews and q.autoRenew == true then
		renews = renews .. " · " .. noctalia.tr("field.auto_renew")
	end
	local rows = {
		kv(noctalia.tr("field.plan"), q.plan or noctalia.tr("panel.no_plan")),
		kv(noctalia.tr("field.status"), mapped(q.status, STATUS_KEY)),
	}
	if q.billingInterval then
		table.insert(rows, kv(noctalia.tr("field.billing"), mapped(q.billingInterval, INTERVAL_KEY)))
	end
	if renews then
		table.insert(rows, kv(noctalia.tr("field.renews"), renews))
	end
	return section(noctalia.tr("panel.subscription"), rows)
end

local function allowanceSection(q)
	if not (q.kwhIncluded and q.kwhUsed) then
		return nil
	end
	local fraction = q.kwhFraction or 0
	local tint = util.severity(fraction)
	local rows = {
		ui.progress({
			progress = math.min(1, math.max(0, fraction)),
			fill = tint,
			track = "on_surface/0.10",
			height = 5,
			radius = 2,
		}),
		kv(noctalia.tr("field.used"), string.format("%s / %s kWh", util.kwhValue(q.kwhUsed), util.kwhValue(q.kwhIncluded))),
	}
	if q.kwhRemaining then
		table.insert(rows, kv(noctalia.tr("field.remaining"), util.kwh(q.kwhRemaining)))
	end
	if q.inOverage then
		table.insert(rows, ui.row({ align = "start" }, { chip(noctalia.tr("field.overage"), "error") }))
	end
	return section(noctalia.tr("panel.allowance"), rows, chip(util.pct(fraction) or "—", tint))
end

local function monthSection(q)
	return section(noctalia.tr("panel.this_month"), {
		kv(noctalia.tr("field.cost"), util.money(q.monthCost)),
		kv(noctalia.tr("field.requests"), util.count(q.monthRequests)),
		kv(noctalia.tr("field.tokens"), util.tokens(q.monthTokens)),
		kv(noctalia.tr("field.energy"), util.kwh(q.monthEnergyKwh)),
	})
end

local function carbonSection(e)
	if type(e) ~= "table" or not e.carbonG then
		return nil
	end
	local rows = {
		kv(noctalia.tr("field.emissions"), util.grams(e.carbonG) .. " CO\u{2082}e"),
	}
	if e.energyKwh then
		table.insert(rows, kv(noctalia.tr("field.energy"), util.kwh(e.energyKwh)))
	end
	local window = util.dateRange(e.start, e["end"])
	if window then
		table.insert(rows, ui.label({ text = window, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))
	end
	return section(noctalia.tr("panel.carbon"), rows)
end

local function accountSection(q)
	local rows = {}
	if q.creditsRemaining then
		table.insert(rows, kv(noctalia.tr("field.balance"), util.money(q.creditsRemaining)))
	end
	if q.creditsTotal then
		table.insert(rows, kv(noctalia.tr("field.total"), util.money(q.creditsTotal)))
	end
	if q.accountingMethod then
		table.insert(rows, kv(noctalia.tr("field.accounting"), q.accountingMethod))
	end
	if q.rateTier then
		table.insert(rows, kv(noctalia.tr("field.rate_tier"), q.rateTier))
	end
	if q.lifetimeCost or q.lifetimeEnergyKwh then
		table.insert(rows, kv(noctalia.tr("field.lifetime"), string.format("%s · %s", util.money(q.lifetimeCost), util.kwh(q.lifetimeEnergyKwh))))
	end
	if #rows == 0 then
		return nil
	end
	return section(noctalia.tr("panel.account"), rows)
end

local function usageBody()
	if type(quota) ~= "table" then
		return { ui.label({ text = noctalia.tr("panel.waiting"), color = "on_surface_variant" }) }
	end
	if not quota.ok then
		local body = {
			ui.label({
				text = quota.message or noctalia.tr("panel.unavailable"),
				color = "error",
				fontWeight = "medium",
			}),
		}
		if quota.code == "need_key" then
			table.insert(body, ui.label({
				text = noctalia.tr("panel.key_hint"),
				fontSize = 12,
				color = "on_surface_variant",
			}))
		end
		return body
	end

	-- Section builders stay functions so the list is always dense. An absent
	-- section (no allowance, no carbon) must not punch a hole in a table literal:
	-- ipairs() stops at the first nil, so a missing carbon row would silently drop
	-- the Account section after it, and a missing allowance every section after
	-- Subscription.
	local body = {}
	for _, build in ipairs({
		function()
			return subscriptionSection(quota)
		end,
		function()
			return allowanceSection(quota)
		end,
		function()
			return monthSection(quota)
		end,
		function()
			return carbonSection(energy)
		end,
		function()
			return accountSection(quota)
		end,
	}) do
		local item = build()
		if item then
			if #body > 0 then
				table.insert(body, divider())
			end
			table.insert(body, item)
		end
	end
	return body
end

-- ── catalog ──────────────────────────────────────────────────────────────────

local function catalogBody()
	if type(models) ~= "table" then
		return { ui.label({ text = noctalia.tr("models.loading"), color = "on_surface_variant" }) }
	end
	if not models.ok then
		return {
			ui.label({
				text = models.message or noctalia.tr("panel.unavailable"),
				color = "error",
				fontWeight = "medium",
			}),
		}
	end
	local list = catalog.filter(models.models or {}, query)
	if #list == 0 then
		return { ui.label({ text = noctalia.tr("models.empty"), color = "on_surface_variant" }) }
	end
	return catalog.rows(list)
end

-- ── chrome ───────────────────────────────────────────────────────────────────

local function header()
	local count = ""
	if tab == "models" and type(models) == "table" and models.ok and models.models then
		count = string.format("%d", #models.models)
	end
	return ui.row({ align = "center", gap = 8 }, {
		ui.image({ path = util.logoPath(), width = 18, height = 18, fit = "contain" }),
		ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
		ui.spacer({ flexGrow = 1 }),
		ui.label({ text = count, fontSize = 12, color = "on_surface_variant" }),
		ui.button({
			glyph = "refresh",
			variant = "ghost",
			controlSize = "sm",
			width = 26,
			height = 26,
			glyphSize = 14,
			tooltip = noctalia.tr("panel.refresh"),
			enabled = not busy,
			onClick = "onRefresh",
		}),
	})
end

local function tabBar()
	local children = {}
	for _, entry in ipairs(TABS) do
		local selected = tab == entry.id
		table.insert(children, ui.button({
			key = "tab-" .. entry.id,
			text = noctalia.tr(entry.key),
			variant = selected and "primary" or "outline",
			selected = selected,
			controlSize = "sm",
			flexGrow = 1,
			onClick = function()
				tab = entry.id
				render()
				if entry.id == "models" and (type(models) ~= "table" or not models.ok) then
					noctalia.state.set("models.cmd", (noctalia.state.get("models.cmd") or 0) + 1)
				end
			end,
		}))
	end
	return ui.row({ gap = 6, align = "center" }, children)
end

render = function()
	lastCountdown = type(quota) == "table" and quota.ok and util.countdown(quota.periodEnd) or nil
	local body = tab == "models" and catalogBody() or usageBody()

	local children = { header(), tabBar() }
	if tab == "models" then
		table.insert(children, ui.input({
			key = "search",
			-- The filter survives a tab switch, so the recreated field must show it.
			value = query,
			placeholder = noctalia.tr("models.search"),
			controlSize = "sm",
			onChange = "onSearch",
		}))
	end
	table.insert(children, ui.scroll({ flexGrow = 1, gap = 0, align = "stretch" }, body))

	panel.render(ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, children))
end

function onSearch(value)
	query = value or ""
	render()
end

function onRefresh()
	busy = true
	render()
	if tab == "models" then
		noctalia.state.set("models.cmd", (noctalia.state.get("models.cmd") or 0) + 1)
	else
		noctalia.state.set("quota.cmd", (noctalia.state.get("quota.cmd") or 0) + 1)
	end
end

function onIpc(event)
	if event == "refresh" then
		onRefresh()
	elseif event == "models" then
		tab = "models"
		render()
		noctalia.state.set("models.cmd", (noctalia.state.get("models.cmd") or 0) + 1)
	elseif event == "usage" then
		tab = "usage"
		render()
	end
end

noctalia.state.watch("quota", function(value)
	quota = value
	busy = false
	render()
end)

noctalia.state.watch("energy", function(value)
	energy = value
	render()
end)

noctalia.state.watch("models", function(value)
	models = value
	busy = false
	render()
end)

function onOpen(_context)
	render()
	-- Fetch the catalog only when the tab needs it and the cache is cold.
	if tab == "models" and (type(models) ~= "table" or not models.ok) then
		noctalia.state.set("models.cmd", (noctalia.state.get("models.cmd") or 0) + 1)
	end
end

-- The renewal countdown is minute-grained, so second ticks are only used to
-- notice when the string changes; a closed panel stays static and onOpen
-- re-renders it.
panel.setWantsSecondTicks(true)

function update()
	if type(quota) ~= "table" or not quota.ok then
		return
	end
	local renews = util.countdown(quota.periodEnd)
	if renews ~= lastCountdown then
		lastCountdown = renews
		render()
	end
end

render()
