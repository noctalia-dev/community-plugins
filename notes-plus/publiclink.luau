-- Public link to the notes app on a phone.
--
-- The link is the Cloudflare tunnel in front of `notes-mobile` (the tunnel
-- rewrites `~/notes-mobile/public-url.txt` every time it starts) plus the
-- server token as a query string: "https://<id>.trycloudflare.com/?token=...".
-- The phone opens that URL in its browser and decides whether to install the
-- app or keep it as one more tab.
--
-- Pure functions only: no I/O, no `noctalia` access, so the unit tests drive
-- them directly (the panel does the reading).

local M = {}

function M.trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The tunnel writes its URL with or without trailing slashes; the link needs
-- exactly one before the query string.
function M.normalizeBase(base)
  local trimmed = M.trim(base)
  if trimmed == "" then
    return ""
  end
  return (trimmed:gsub("/+$", ""))
end

-- Returns "" when the tunnel address or the token is missing: the caller turns
-- that into a message that says which one is missing.
function M.buildLink(base, token)
  local cleanBase = M.normalizeBase(base)
  local cleanToken = M.trim(token)
  if cleanBase == "" or cleanToken == "" then
    return ""
  end
  return cleanBase .. "/?token=" .. cleanToken
end

-- Token from `~/notes-mobile/config.json`. `decode` is `noctalia.json.decode`
-- (passed in so this module stays free of host globals). A missing, empty or
-- corrupt file means "no token": the panel explains it instead of failing.
function M.tokenFromConfig(raw, decode)
  if type(raw) ~= "string" or M.trim(raw) == "" or type(decode) ~= "function" then
    return ""
  end
  local ok, decoded = pcall(decode, raw)
  if not ok or type(decoded) ~= "table" then
    return ""
  end
  return M.trim(decoded.token)
end

return M
