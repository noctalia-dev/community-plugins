--!nonstrict
-- Rate formatting for the tooltip, in decimal units like Noctalia's built-in
-- network widgets (1 kB = 1000 B).

local M = {}

local KB = 1000
local MB = 1000 * 1000
local GB = 1000 * 1000 * 1000

function M.rate(bytesPerSec)
	local b = math.max(tonumber(bytesPerSec) or 0, 0)
	if b >= GB then
		return string.format("%.1f GB/s", b / GB)
	elseif b >= MB then
		return string.format("%.1f MB/s", b / MB)
	elseif b >= KB then
		return string.format("%.1f kB/s", b / KB)
	end
	return string.format("%d B/s", math.floor(b + 0.5))
end

-- The color of an idle LED: the active color at `brightness` (0-1) alpha.
-- Accepts a palette role ("error", "primary/0.8") or a hex value.
function M.dim(color, brightness)
	local spec = tostring(color or "error")
	local alpha = math.max(0, math.min(1, tonumber(brightness) or 0))
	local hex = spec:match("^(#%x%x%x%x%x%x)")
	if hex ~= nil then
		return hex .. string.format("%02x", math.floor(alpha * 255 + 0.5))
	end
	local role = spec:match("^([^/]+)") or spec
	return role .. "/" .. string.format("%.2f", alpha)
end

return M
