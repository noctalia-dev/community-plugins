--!nonstrict
-- Checks on settings, the key file and the age of the service's snapshot. No
-- Noctalia calls in here, so the tests can run them directly.

local M = {}

-- Longer than a native request can hang (30 s) plus the retry through curl.
local STALE_MIN_MS = 60 * 1000

-- The API key travels as basic auth on every poll, so only https is accepted.
-- A URL without a scheme counts as insecure too: libcurl would read it as http.
function M.isSecureUrl(url)
	return tostring(url):lower():match("^https://[^/%s]") ~= nil
end

-- Reads the key=/secret= file OPNsense offers for download. The first valid line
-- of each name wins. CURL_SCRIPT in service.luau has to accept the same lines.
function M.parseCredentials(raw)
	local found = {}
	for line in tostring(raw):gmatch("[^\r\n]+") do
		local name, value = line:match("^%s*(%a+)%s*=%s*(%S+)%s*$")
		if (name == "key" or name == "secret") and found[name] == nil then
			found[name] = value
		end
	end
	if found.key == nil or found.secret == nil then
		return nil
	end
	return found
end

-- True when the service has not published for a while, e.g. because Noctalia
-- stopped feeding it after repeated script errors. No snapshot at all counts too.
function M.isStale(updatedAtMs, nowMs, pollSeconds)
	local updatedAt = tonumber(updatedAtMs)
	if updatedAt == nil then
		return true
	end
	local poll = math.max(tonumber(pollSeconds) or 2, 1)
	return nowMs - updatedAt > math.max(STALE_MIN_MS, poll * 3000)
end

return M
