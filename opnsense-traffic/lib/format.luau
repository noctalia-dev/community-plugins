--!nonstrict
-- Rate formatting shared by widget and panel. Mirrors Noctalia's built-in
-- network widgets: decimal units (1 kB = 1000 B), one decimal, compact style
-- drops "/s" ("1.2M" instead of "1.2 MB/s").

local M = {}

local KB = 1000
local MB = 1000 * 1000
local GB = 1000 * 1000 * 1000

local function value(v, full, short, compact)
	if compact then
		return string.format("%.1f%s", v, short)
	end
	return string.format("%.1f %s", v, full)
end

-- unit: "auto" | "kb" | "mb"
function M.rate(bytesPerSec, unit, compact)
	local b = math.max(tonumber(bytesPerSec) or 0, 0)
	if unit == "kb" then
		return value(b / KB, "kB/s", "k", compact)
	elseif unit == "mb" then
		return value(b / MB, "MB/s", "M", compact)
	end
	if b >= GB then
		return value(b / GB, "GB/s", "G", compact)
	elseif b >= MB then
		return value(b / MB, "MB/s", "M", compact)
	elseif b >= KB then
		return value(b / KB, "kB/s", "k", compact)
	end
	if compact then
		return string.format("%.0fB", b)
	end
	return string.format("%.0f B/s", b)
end

-- Same as the built-in "show units" switch: keep the number, drop the suffix.
function M.stripUnit(text)
	local stripped = text:match("^(.-%d)%s*[^%d]*$")
	return stripped or text
end

-- Bytes/s as Mbit/s, for the panel next to the configured line speed.
function M.mbit(bytesPerSec)
	local mbit = math.max(tonumber(bytesPerSec) or 0, 0) * 8 / MB
	return string.format(mbit < 10 and "%.2f Mbit/s" or "%.1f Mbit/s", mbit)
end

return M
