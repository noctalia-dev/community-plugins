--!nonstrict
-- TOTP (RFC 6238, HMAC-SHA1) and the import formats: otpauth:// URIs and Google
-- Authenticator's otpauth-migration:// export. Pure Luau, no host APIs, so it runs
-- under the plain `luau` CLI for tests.

local M = {}

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lrotate, rshift, lshift = bit32.lrotate, bit32.rshift, bit32.lshift

-- SHA-1 over a byte string.
local function sha1(msg: string): string
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local ml = #msg * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64) .. string.pack(">I4I4", 0, ml)
  local w = table.create(80, 0)
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      w[i] = string.unpack(">I4", msg, chunk + i * 4)
    end
    for i = 16, 79 do
      w[i] = lrotate(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local t = (lrotate(a, 5) + f + e + k + w[i]) % 0x100000000
      e, d, c, b, a = d, c, lrotate(b, 30), a, t
    end
    h0 = (h0 + a) % 0x100000000
    h1 = (h1 + b) % 0x100000000
    h2 = (h2 + c) % 0x100000000
    h3 = (h3 + d) % 0x100000000
    h4 = (h4 + e) % 0x100000000
  end
  return string.pack(">I4I4I4I4I4", h0, h1, h2, h3, h4)
end

local function hmacSha1(key: string, msg: string): string
  if #key > 64 then
    key = sha1(key)
  end
  key ..= string.rep("\0", 64 - #key)
  local ipad, opad = table.create(64), table.create(64)
  for i = 1, 64 do
    local b = string.byte(key, i)
    ipad[i] = string.char(bxor(b, 0x36))
    opad[i] = string.char(bxor(b, 0x5C))
  end
  return sha1(table.concat(opad) .. sha1(table.concat(ipad) .. msg))
end

M.sha1 = sha1
M.hmacSha1 = hmacSha1

local B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

-- Base32 (RFC 4648) to bytes; spaces, dashes and padding are ignored, case-insensitive.
-- Returns nil for anything else.
function M.base32Decode(s: string): string?
  s = s:upper():gsub("[%s%-=]", "")
  if s == "" then
    return nil
  end
  local out, buf, bits = {}, 0, 0
  for i = 1, #s do
    local v = B32:find(s:sub(i, i), 1, true)
    if not v then
      return nil
    end
    buf = bor(lshift(band(buf, 0xFFFFFF), 5), v - 1)
    bits += 5
    if bits >= 8 then
      bits -= 8
      table.insert(out, string.char(band(rshift(buf, bits), 0xFF)))
    end
  end
  return table.concat(out)
end

function M.base32Encode(bytes: string): string
  local out, buf, bits = {}, 0, 0
  for i = 1, #bytes do
    buf = bor(lshift(band(buf, 0xFFFFFF), 8), string.byte(bytes, i))
    bits += 8
    while bits >= 5 do
      bits -= 5
      local v = band(rshift(buf, bits), 31)
      table.insert(out, B32:sub(v + 1, v + 1))
    end
  end
  if bits > 0 then
    local v = band(lshift(buf, 5 - bits), 31)
    table.insert(out, B32:sub(v + 1, v + 1))
  end
  return table.concat(out)
end

-- Code for `key` (raw bytes) at counter value `counter` (RFC 4226 dynamic truncation).
function M.hotp(key: string, counter: number, digits: number): string
  local hi = math.floor(counter / 0x100000000)
  local lo = counter % 0x100000000
  local mac = hmacSha1(key, string.pack(">I4I4", hi, lo))
  local offset = band(string.byte(mac, 20), 0x0F)
  local bin = band(string.unpack(">I4", mac, offset + 1), 0x7FFFFFFF)
  return string.format("%0" .. digits .. "d", bin % 10 ^ digits)
end

-- Current code and seconds left for an account { secret = base32, digits, period }.
function M.code(account, now: number): (string?, number)
  local period = account.period or 30
  local key = M.base32Decode(account.secret)
  local left = period - math.floor(now) % period
  if not key then
    return nil, left
  end
  return M.hotp(key, math.floor(now / period), account.digits or 6), left
end

-- "123456" -> "123 456", "12345678" -> "1234 5678"
function M.group(code: string): string
  local half = math.ceil(#code / 2)
  return code:sub(1, half) .. " " .. code:sub(half + 1)
end

local function urlDecode(s: string): string
  return (s:gsub("+", " "):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function query(q: string)
  local out = {}
  for k, v in q:gmatch("([^&=]+)=?([^&]*)") do
    out[urlDecode(k):lower()] = urlDecode(v)
  end
  return out
end

-- otpauth://totp/Issuer:account?secret=...&issuer=...  ->  account table, or nil + reason.
function M.parseUri(uri: string)
  local kind, path, q = uri:match("^otpauth://(%a+)/([^?]*)%??(.*)$")
  if not kind then
    return nil, "not_otpauth"
  end
  if kind:lower() ~= "totp" then
    return nil, "unsupported_type"
  end
  local p = query(q)
  local algo = (p.algorithm or "SHA1"):upper()
  if algo ~= "SHA1" then
    return nil, "unsupported_algorithm"
  end
  local secret = p.secret and p.secret:upper():gsub("[%s=]", "")
  if not secret or not M.base32Decode(secret) then
    return nil, "bad_secret"
  end
  local label = urlDecode(path)
  local labelIssuer, account = label:match("^([^:]*):%s*(.*)$")
  account = account or label
  local issuer = p.issuer or labelIssuer or ""
  local digits = tonumber(p.digits) or 6
  local period = tonumber(p.period) or 30
  if digits < 6 or digits > 8 or period < 1 then
    return nil, "bad_parameters"
  end
  return { issuer = issuer, account = account, secret = secret, digits = digits, period = period }
end

local function base64Decode(s: string): string?
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  s = s:gsub("[%s=]", "")
  local out, buf, bits = {}, 0, 0
  for i = 1, #s do
    local v = alphabet:find(s:sub(i, i), 1, true)
    if not v then
      return nil
    end
    buf = bor(lshift(band(buf, 0xFFFFFF), 6), v - 1)
    bits += 6
    if bits >= 8 then
      bits -= 8
      table.insert(out, string.char(band(rshift(buf, bits), 0xFF)))
    end
  end
  return table.concat(out)
end

-- Minimal protobuf reader: calls fn(field, wireType, value) for each field of `buf`;
-- value is a number for varints and a byte string for length-delimited fields.
local function fields(buf: string, fn)
  local i = 1
  local function varint()
    local r, mul = 0, 1
    while true do
      local b = string.byte(buf, i)
      if not b then
        error("truncated")
      end
      i += 1
      r += band(b, 0x7F) * mul
      mul *= 128
      if b < 128 then
        return r
      end
    end
  end
  while i <= #buf do
    local key = varint()
    local field, wire = math.floor(key / 8), key % 8
    if wire == 0 then
      fn(field, wire, varint())
    elseif wire == 2 then
      local len = varint()
      fn(field, wire, buf:sub(i, i + len - 1))
      i += len
    elseif wire == 5 then
      i += 4
    elseif wire == 1 then
      i += 8
    else
      error("bad wire type")
    end
  end
end

-- otpauth-migration://offline?data=... -> list of accounts, skipped count; or nil + reason.
-- Google's enums: algorithm 1 = SHA1; digits 1 = six, 2 = eight; type 2 = TOTP.
function M.parseMigration(uri: string)
  local data = uri:match("^otpauth%-migration://offline%?.*data=([^&]+)")
  if not data then
    return nil, "not_migration"
  end
  local raw = base64Decode(urlDecode(data))
  if not raw then
    return nil, "bad_migration"
  end
  local accounts, skipped = {}, 0
  local ok = pcall(fields, raw, function(field, _, value)
    if field ~= 1 then
      return
    end
    local p = { algorithm = 1, digits = 1, type = 2 }
    fields(value, function(f, _, v)
      if f == 1 then
        p.secret = v
      elseif f == 2 then
        p.name = v
      elseif f == 3 then
        p.issuer = v
      elseif f == 4 then
        p.algorithm = v
      elseif f == 5 then
        p.digits = v
      elseif f == 6 then
        p.type = v
      end
    end)
    if p.secret and p.type == 2 and (p.algorithm == 1 or p.algorithm == 0) then
      local issuer = p.issuer or ""
      local account = p.name or ""
      local labelIssuer, rest = account:match("^([^:]+):%s*(.+)$")
      if labelIssuer and issuer == "" then
        issuer, account = labelIssuer, rest
      end
      table.insert(accounts, {
        issuer = issuer,
        account = account,
        secret = M.base32Encode(p.secret),
        digits = p.digits == 2 and 8 or 6,
        period = 30,
      })
    else
      skipped += 1
    end
  end)
  if not ok then
    return nil, "bad_migration"
  end
  return accounts, skipped
end

-- Any text holding one or more otpauth / otpauth-migration URIs (a QR payload, the
-- clipboard, a FreeOTP+ export) -> list of accounts, skipped count, first error.
function M.parseAny(text: string)
  local accounts, skipped, firstErr = {}, 0, nil
  for line in text:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line:find("^otpauth%-migration://") then
      local list, err = M.parseMigration(line)
      if list then
        for _, a in list do
          table.insert(accounts, a)
        end
        skipped += err
      else
        skipped += 1
        firstErr = firstErr or err
      end
    elseif line:find("^otpauth://") then
      local a, err = M.parseUri(line)
      if a then
        table.insert(accounts, a)
      else
        skipped += 1
        firstErr = firstErr or err
      end
    end
  end
  if #accounts == 0 and skipped == 0 then
    firstErr = "nothing_found"
  end
  return accounts, skipped, firstErr
end

return M
