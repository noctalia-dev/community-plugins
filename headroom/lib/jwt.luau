--!nonstrict
-- Reads the claims of a JWT without verifying it. Used only to learn a token's
-- expiry locally, so an expired session shows "sign in again" without a
-- network round-trip. Nothing here is trusted for authorization.

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE = {}
for i = 1, #ALPHABET do
  DECODE[string.byte(ALPHABET, i)] = i - 1
end
DECODE[string.byte("-")] = 62
DECODE[string.byte("_")] = 63

-- base64 / base64url, padding optional. nil on any invalid character.
function M.base64Decode(input: string): string?
  input = input:gsub("=+$", "")
  local out = table.create(#input * 3 // 4)
  local acc, bits = 0, 0
  for i = 1, #input do
    local v = DECODE[string.byte(input, i)]
    if v == nil then
      return nil
    end
    acc = bit32.bor(bit32.lshift(acc, 6), v)
    bits += 6
    if bits >= 8 then
      bits -= 8
      table.insert(out, string.char(bit32.band(bit32.rshift(acc, bits), 0xFF)))
    end
  end
  return table.concat(out)
end

-- Claims table, or nil when the token is not a decodable JWT.
function M.claims(token: any, decodeJson): { [string]: any }?
  if type(token) ~= "string" then
    return nil
  end
  local payload = token:match("^[^.]+%.([^.]+)%.")
  if payload == nil then
    return nil
  end
  local raw = M.base64Decode(payload)
  if raw == nil then
    return nil
  end
  local claims = decodeJson(raw)
  return if type(claims) == "table" then claims else nil
end

return M
