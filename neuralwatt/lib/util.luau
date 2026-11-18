--!nonstrict
-- Shared helpers for every Neuralwatt entry. The bar widget, both panels and
-- the service load this with require(), so number formatting, the allowance
-- severity color and the date helpers live in exactly one place.

local M = {}

M.PLUGIN_ID = "omertahaoztop/neuralwatt"

-- Neuralwatt's own logomark (the brand mark from neuralwatt.com, kept in
-- assets/). The mark is monochrome, so the readable variant depends on the
-- palette rather than on the theme name.
function M.logoPath()
	if noctalia.isDarkMode() then
		return "assets/logomark-light.png"
	end
	return "assets/logomark-dark.png"
end

-- ── formatting ───────────────────────────────────────────────────────────────

-- Bare number, for places that print the unit once: "12.5/28.6 kWh".
function M.kwhValue(value)
	if type(value) ~= "number" then
		return "—"
	end
	if value >= 100 then
		return string.format("%.0f", value)
	elseif value >= 10 then
		return string.format("%.1f", value)
	elseif value >= 1 then
		return string.format("%.2f", value)
	end
	return string.format("%.3f", value)
end

-- Keeps a useful number of digits at every scale: 0.0234 kWh, 1.20 kWh, 12.5 kWh.
function M.kwh(value)
	if type(value) ~= "number" then
		return "—"
	end
	return M.kwhValue(value) .. " kWh"
end

function M.grams(value)
	if type(value) ~= "number" then
		return "—"
	end
	if value >= 1000 then
		return string.format("%.2f kg", value / 1000)
	elseif value >= 100 then
		return string.format("%.0f g", value)
	elseif value >= 10 then
		return string.format("%.1f g", value)
	elseif value >= 1 then
		return string.format("%.2f g", value)
	end
	return string.format("%.3f g", value)
end

function M.money(value)
	if type(value) ~= "number" then
		return "—"
	end
	return string.format("$%.2f", value)
end

function M.tokens(value)
	if type(value) ~= "number" then
		return "—"
	end
	if value >= 1e9 then
		return string.format("%.2fB", value / 1e9)
	elseif value >= 1e6 then
		return string.format("%.1fM", value / 1e6)
	elseif value >= 1e3 then
		return string.format("%.1fk", value / 1e3)
	end
	return string.format("%d", value)
end

function M.count(value)
	if type(value) ~= "number" then
		return "—"
	end
	return string.format("%d", math.floor(value + 0.5))
end

function M.pct(fraction)
	if type(fraction) ~= "number" or fraction < 0 then
		return nil
	end
	local value = fraction * 100
	if value > 999 then
		value = 999
	end
	return string.format("%d%%", math.floor(value + 0.5))
end

-- Palette role for an allowance fraction, driven by the user's thresholds and
-- colour choices so a capsule and a panel agree on what "nearly spent" looks
-- like.
function M.severity(fraction)
	local warn = (tonumber(noctalia.getConfig("warn_percent")) or 70) / 100
	local critical = (tonumber(noctalia.getConfig("critical_percent")) or 90) / 100
	local okColor = noctalia.getConfig("ok_color")
	local warnColor = noctalia.getConfig("warn_color")
	if type(okColor) ~= "string" or okColor == "" then
		okColor = "primary"
	end
	if type(warnColor) ~= "string" or warnColor == "" then
		warnColor = "secondary"
	end
	if type(fraction) ~= "number" or fraction < 0 then
		return "on_surface_variant"
	end
	if fraction >= critical then
		return "error"
	elseif fraction >= warn then
		return warnColor
	end
	return okColor
end

-- ── dates ────────────────────────────────────────────────────────────────────

-- ISO-8601 -> epoch seconds, computed arithmetically (days-from-civil) instead
-- of via os.time({...}), because os.time interprets a table as *local* time and
-- would shift every countdown by the host's UTC offset.
local function daysFromCivil(y, m, d)
	y = y - (m <= 2 and 1 or 0)
	local era = (y >= 0 and y or y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

function M.isoToEpoch(ts)
	if type(ts) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, s, rest = ts:match(
		"^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
	)
	if not y then
		return nil
	end
	-- Fractional seconds ("...:02.220Z") carry no information we use, but a UTC
	-- offset can follow them, so drop the fraction and keep the rest.
	local tail = rest:gsub("^%.%d+", "")
	local epoch = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
		+ tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
	local sign, oh, om = tail:match("^([%+%-])(%d%d):(%d%d)$")
	if sign then
		local offset = tonumber(oh) * 3600 + tonumber(om) * 60
		epoch = epoch + (sign == "-" and offset or -offset)
	end
	return epoch
end

-- "in 7d 3h" / "in 4h 12m" / "in 9m" / "now".
function M.countdown(ts)
	local epoch = M.isoToEpoch(ts)
	if not epoch then
		return nil
	end
	local diff = epoch - os.time()
	if diff <= 0 then
		return noctalia.tr("countdown.now")
	end
	local days = diff // 86400
	local hours = (diff % 86400) // 3600
	local mins = (diff % 3600) // 60
	if days > 0 then
		return noctalia.tr("countdown.days_hours", { days = days, hours = hours })
	elseif hours > 0 then
		return noctalia.tr("countdown.hours_mins", { hours = hours, mins = mins })
	end
	return noctalia.tr("countdown.mins", { mins = mins })
end

-- "18.09 → 11.10": compact, unambiguous, and independent of the shell's date
-- format setting (which the carbon window's exact dates should not follow).
function M.dateRange(startIso, endIso)
	local function short(iso)
		if type(iso) ~= "string" then
			return nil
		end
		local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
		if not y then
			return iso
		end
		return d .. "." .. m
	end
	local first, last = short(startIso), short(endIso)
	if first and last then
		return first .. " → " .. last
	end
	return first or last
end

return M
