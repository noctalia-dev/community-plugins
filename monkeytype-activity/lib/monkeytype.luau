--!nonstrict

-- The MonkeyType API as this plugin sees it: request shapes, error mapping and
-- the one place that has to know how the responses are wrapped.
--
-- Authentication is an Ape Key (`Authorization: ApeKey <key>`), generated in
-- MonkeyType under Settings -> Ape Keys. Requests go through `noctalia.http`,
-- so the key never reaches a process command line.

local Monkeytype = {}

Monkeytype.BASE_URL = "https://api.monkeytype.com"
-- Ape Keys live in the account settings, in their own tab.
Monkeytype.APE_KEYS_URL = "https://monkeytype.com/account-settings?tab=apeKeys"

-- Shared status vocabulary published to the widget and the panel.
Monkeytype.STATUS = {
  AUTH = "auth_error",
  INVALID_KEY = "invalid_key",
  INACTIVE_KEY = "inactive_key",
  RATE_LIMITED = "rate_limited",
  REQUEST = "request_error",
  RESPONSE = "invalid_response",
  NO_ACTIVITY = "no_activity",
}

-- Ape Keys are base64url-ish tokens: anything else (a stray line break from a
-- paste, a whole shell snippet) must never reach the header list.
local KEY_PATTERN = "^[%w_%-]+$"

function Monkeytype.isValidKey(key)
  return type(key) == "string" and key ~= "" and string.match(key, KEY_PATTERN) ~= nil
end

-- One-way fingerprint of an Ape Key. The cache and the published payload are
-- bound to the credential without ever storing it: two Rabin-Karp style
-- hashes mod 2^31-1 give 62 bits, which is enough to tell accounts apart and
-- leaves nothing to reverse. Products stay below 2^53, so doubles are exact.
local HASH_MOD = 2147483647

local function hashText(text, multiplier, seed)
  local value = seed
  for index = 1, #text do
    value = (value * multiplier + string.byte(text, index)) % HASH_MOD
  end
  return value
end

function Monkeytype.fingerprint(key)
  if type(key) ~= "string" or key == "" then
    return ""
  end
  local salted = "monkeytype-activity:" .. key
  return string.format(
    "fp:%08x%08x",
    hashText(salted, 131, 7),
    hashText(salted, 65599, 104729)
  )
end

function Monkeytype.request(path, key)
  return {
    url = Monkeytype.BASE_URL .. path,
    method = "GET",
    headers = {
      "Accept: application/json",
      "Authorization: ApeKey " .. key,
    },
  }
end

-- The API answers 470 (unknown), 471 (disabled in the website's toggle) and
-- 472 (malformed) for unusable Ape keys, and 429/479 for rate limits; anything
-- else is a plain failure.
function Monkeytype.statusFor(httpStatus)
  if httpStatus == 401 then
    return Monkeytype.STATUS.AUTH
  end
  if httpStatus == 471 then
    return Monkeytype.STATUS.INACTIVE_KEY
  end
  if httpStatus == 470 or httpStatus == 472 then
    return Monkeytype.STATUS.INVALID_KEY
  end
  if httpStatus == 429 or httpStatus == 479 then
    return Monkeytype.STATUS.RATE_LIMITED
  end
  return Monkeytype.STATUS.REQUEST
end

-- Decode one `{ ok, status, body }` response into its `data` payload.
-- `no_activity` means the account has nothing saved yet, which is a normal
-- state, not an error.
--
-- The host reports `ok = true` for any completed transfer, including a 4xx
-- answer, so the HTTP status decides whether the payload is usable.
function Monkeytype.payload(response, decodeJson)
  if type(response) ~= "table" then
    return nil, Monkeytype.STATUS.REQUEST
  end

  local status = response.status
  if type(status) ~= "number" or status < 200 or status > 299 then
    return nil, Monkeytype.statusFor(status)
  end
  if response.ok ~= true then
    return nil, Monkeytype.STATUS.REQUEST
  end

  local envelope = type(decodeJson) == "function" and decodeJson(response.body or "") or nil
  if type(envelope) ~= "table" then
    return nil, Monkeytype.STATUS.RESPONSE
  end

  local data = envelope.data
  if data == nil then
    return nil, Monkeytype.STATUS.NO_ACTIVITY
  end
  if type(data) ~= "table" then
    return nil, Monkeytype.STATUS.RESPONSE
  end

  return data
end

-- Length of a flat numeric array as it appears in the response body.
--
-- The JSON decoder maps `null` to `nil`, and `#table` stops at the first hole,
-- so a `testsByDays` window that ends with test-free days would look shorter
-- than it is. Counting the separators in the body keeps the real window length
-- (and with it the day alignment) intact.
function Monkeytype.arrayLength(body, field)
  if type(body) ~= "string" or type(field) ~= "string" then
    return nil
  end

  local start = string.find(body, '"' .. field .. '"%s*:%s*%[')
  if start == nil then
    return nil
  end

  local open = string.find(body, "[", start, true)
  if open == nil then
    return nil
  end

  local depth = 0
  local separatorCount = 0
  local valueCount = 0
  for index = open, #body do
    local char = string.sub(body, index, index)
    if char == "[" then
      depth = depth + 1
    elseif char == "]" then
      depth = depth - 1
      if depth == 0 then
        return separatorCount + valueCount
      end
    elseif depth == 1 then
      if char == "," then
        separatorCount = separatorCount + 1
      elseif char ~= " " and char ~= "\t" and char ~= "\n" and char ~= "\r" then
        valueCount = 1
      end
    end
  end

  return separatorCount + valueCount
end

-- Profile URL for the optional username setting, or nil when unset or not a
-- name MonkeyType could have issued. Stripping bad characters would land on a
-- different (possibly existing) profile, so the name is validated instead.
function Monkeytype.profileUrl(username)
  if type(username) ~= "string" then
    return nil
  end

  local name = string.match(username, "^%s*(.-)%s*$")
  if name == "" or string.match(name, KEY_PATTERN) == nil then
    return nil
  end

  return "https://monkeytype.com/profile/" .. name
end

return Monkeytype
