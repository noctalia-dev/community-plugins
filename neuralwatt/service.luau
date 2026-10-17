--!nonstrict
-- Headless [[service]] entry: the plugin's only network client. Polls the
-- Neuralwatt account endpoints and publishes the parsed result to
-- noctalia.state, where the bar widget and both panels read it.
--
--   noctalia.http({ url, headers }, cb)   async HTTP; headers are "K: V" lines
--   noctalia.state.set / get / watch      shared with the plugin's other entries
--   noctalia.getConfig(key)               plugin-level [[setting]] values
--   noctalia.setUpdateInterval(ms)        tick rate for update()
--   onIpc(event)                          `noctalia msg plugin <id>:poller all refresh`
--
-- The bar and panels own no polling logic: they only read state.

local util = require("./lib/util.luau")

local QUOTA_URL = "https://api.neuralwatt.com/v1/quota"
local ENERGY_URL = "https://api.neuralwatt.com/v1/usage/energy"
local MODELS_URL = "https://api.neuralwatt.com/v1/models"
local REFRESH_CMD = "quota.cmd"
local MODELS_CMD = "models.cmd"

local function num(value)
	if type(value) == "number" then
		return value
	end
	return nil
end

-- `code` is a stable machine-readable tag; `message` is the already-translated
-- display text. Entries branch on `code`, never on the message text.
local function fail(code, message)
	noctalia.state.set("quota", { ready = true, ok = false, code = code, message = message })
end

-- Returns the billing-period start date (YYYY-MM-DD) so the carbon window can
-- follow the same period, or nil when the account has no subscription.
local function parseQuota(body)
	local data = noctalia.json.decode(body)
	if type(data) ~= "table" then
		fail("bad_response", noctalia.tr("status.bad_response"))
		return nil
	end

	local sub = data.subscription
	local bal = data.balance or {}
	local month = (data.usage and data.usage.current_month) or {}
	local life = (data.usage and data.usage.lifetime) or {}
	local limits = data.limits or {}

	local kwhIncluded = sub and num(sub.kwh_included) or nil
	local kwhUsed = sub and num(sub.kwh_used) or nil
	local fraction = -1
	if kwhIncluded and kwhIncluded > 0 and kwhUsed then
		fraction = kwhUsed / kwhIncluded
	end

	local periodStart = nil
	if sub and type(sub.current_period_start) == "string" then
		periodStart = sub.current_period_start:sub(1, 10)
	end

	noctalia.state.set("quota", {
		ready = true,
		ok = true,
		code = nil,
		plan = sub and sub.plan or nil,
		status = sub and sub.status or nil,
		billingInterval = sub and sub.billing_interval or nil,
		autoRenew = sub and sub.auto_renew or nil,
		periodEnd = sub and sub.current_period_end or nil,
		kwhUsed = kwhUsed,
		kwhIncluded = kwhIncluded,
		kwhRemaining = sub and num(sub.kwh_remaining) or nil,
		inOverage = sub and sub.in_overage == true or false,
		kwhFraction = fraction,
		monthCost = num(month.cost_usd),
		monthRequests = num(month.requests),
		monthTokens = num(month.tokens),
		monthEnergyKwh = num(month.energy_kwh),
		lifetimeCost = num(life.cost_usd),
		lifetimeEnergyKwh = num(life.energy_kwh),
		creditsRemaining = num(bal.credits_remaining_usd),
		creditsTotal = num(bal.total_credits_usd),
		accountingMethod = bal.accounting_method,
		rateTier = limits.rate_limit_tier,
	})
	return periodStart
end

-- ── fetch ────────────────────────────────────────────────────────────────────

local quotaInFlight = false
local energyInFlight = false
local modelsInFlight = false

local function headers(apiKey)
	return {
		"Authorization: Bearer " .. apiKey,
		"Accept: application/json",
	}
end

-- Carbon is an optional extra: a failure leaves the previous reading in place.
local function fetchEnergy(apiKey, periodStart)
	if energyInFlight then
		return
	end
	local startDate = periodStart or os.date("%Y-%m-01")
	local endDate = os.date("%Y-%m-%d")
	local url = ENERGY_URL .. "?start_date=" .. startDate .. "&end_date=" .. endDate

	energyInFlight = true
	local accepted = noctalia.http({ url = url, headers = headers(apiKey) }, function(res)
		energyInFlight = false
		if not res.ok or res.status ~= 200 then
			return
		end
		local data = noctalia.json.decode(res.body)
		local totals = data and data.totals
		if type(totals) ~= "table" then
			return
		end
		noctalia.state.set("energy", {
			ready = true,
			carbonG = num(totals.carbon_g_co2eq),
			energyKwh = num(totals.energy_kwh),
			start = data.period and data.period.start or startDate,
			-- "end" is a Lua keyword, so the key needs bracket syntax.
			["end"] = data.period and data.period["end"] or endDate,
		})
	end)
	if not accepted then
		energyInFlight = false
	end
end

local function fetchModels()
	if modelsInFlight then
		return
	end
	local apiKey = noctalia.getConfig("api_key")
	local hdrs = { "Accept: application/json" }
	if type(apiKey) == "string" and apiKey ~= "" then
		hdrs = headers(apiKey)
	end

	modelsInFlight = true
	local accepted = noctalia.http({ url = MODELS_URL, headers = hdrs }, function(res)
		modelsInFlight = false
		if not res.ok then
			noctalia.state.set("models", { ready = true, ok = false, code = "network", message = noctalia.tr("status.network") })
			return
		elseif res.status ~= 200 then
			noctalia.state.set("models", { ready = true, ok = false, code = "http_error", message = noctalia.tr("status.http_error", { status = res.status }) })
			return
		end
		local data = noctalia.json.decode(res.body)
		local list = data and data.data
		if type(list) ~= "table" then
			noctalia.state.set("models", { ready = true, ok = false, code = "bad_response", message = noctalia.tr("status.bad_response") })
			return
		end
		local models = {}
		for _, entry in ipairs(list) do
			local meta = entry.metadata or {}
			local pricing = meta.pricing or {}
			local caps = meta.capabilities or {}
			local lim = meta.limits or {}
			table.insert(models, {
				id = entry.id,
				name = meta.display_name or entry.id,
				provider = meta.provider,
				context = lim.max_context_length or entry.max_model_len,
				outputLimit = lim.max_output_tokens,
				inputPrice = num(pricing.input_per_million),
				outputPrice = num(pricing.output_per_million),
				cachedPrice = num(pricing.cached_input_per_million),
				pricingTbd = pricing.pricing_tbd == true,
				deprecated = meta.deprecated == true,
				tools = caps.tools == true,
				vision = caps.vision == true,
				reasoning = caps.reasoning == true,
				json = caps.json_mode == true,
				streaming = caps.streaming == true,
			})
		end
		table.sort(models, function(a, b)
			return string.lower(a.name) < string.lower(b.name)
		end)
		noctalia.state.set("models", { ready = true, ok = true, models = models })
	end)
	if not accepted then
		modelsInFlight = false
		noctalia.state.set("models", { ready = true, ok = false, code = "refused", message = noctalia.tr("status.refused") })
	end
end

local function fetchQuota()
	if quotaInFlight then
		return
	end
	local apiKey = noctalia.getConfig("api_key")
	if type(apiKey) ~= "string" or apiKey == "" then
		fail("need_key", noctalia.tr("status.need_key"))
		return
	end

	quotaInFlight = true
	-- res.ok is transport success, not HTTP status: a 401 arrives with ok=true.
	local accepted = noctalia.http({ url = QUOTA_URL, headers = headers(apiKey) }, function(res)
		quotaInFlight = false
		if not res.ok then
			fail("network", noctalia.tr("status.network"))
		elseif res.status ~= 200 then
			fail("http_error", noctalia.tr("status.http_error", { status = res.status }))
		else
			local periodStart = parseQuota(res.body)
			fetchEnergy(apiKey, periodStart)
		end
	end)
	if not accepted then
		quotaInFlight = false
		fail("refused", noctalia.tr("status.refused"))
	end
end

-- Refetch on demand: the panel Refresh button, a widget right-click, or
-- `noctalia msg plugin omertahaoztop/neuralwatt:poller all refresh`.
noctalia.state.watch(REFRESH_CMD, function()
	fetchQuota()
end)
noctalia.state.watch(MODELS_CMD, function()
	fetchModels()
end)

function onIpc(event)
	if event == "refresh" then
		fetchQuota()
	elseif event == "models" then
		fetchModels()
	end
end

noctalia.setUpdateInterval(math.max(60, tonumber(noctalia.getConfig("refresh_interval_sec")) or 600) * 1000)

function update()
	fetchQuota()
end

-- Top-level init: publish a loading state and do the first fetch immediately,
-- so the bar has data before the first scheduled tick.
fail("loading", noctalia.tr("status.loading"))
fetchQuota()
