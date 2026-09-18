--!nonstrict
-- Podcast Index API (api.podcastindex.org) discovery. Active only when the
-- user sets both podindex_key and podindex_secret in plugin settings;
-- otherwise P.configured() is false and no call is ever made.

local P = {}

function P.configured()
  local k = noctalia.string.trim(tostring(noctalia.getConfig("podindex_key") or ""))
  local s = noctalia.string.trim(tostring(noctalia.getConfig("podindex_secret") or ""))
  local ok = k ~= "" and s ~= ""
  return ok, k, s
end

local HEXD = "0123456789abcdef"

local function whex(x)
  local s = ""
  for i = 7, 0, -1 do
    local nib = bit32.extract(x, i * 4, 4)
    s = s .. string.sub(HEXD, nib + 1, nib + 1)
  end
  return s
end

-- Compact SHA-1 (hex) for the Podcast Index auth hash. Pure Luau, no deps.
local function sha1hex(msg)
  local ml = #msg * 8
  msg = msg .. "\128"
  while #msg % 64 ~= 56 do
    msg = msg .. "\0"
  end
  msg = msg .. string.char(0, 0, 0, 0,
    math.floor(ml / 16777216) % 256,
    math.floor(ml / 65536) % 256,
    math.floor(ml / 256) % 256,
    ml % 256)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  for c = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local b = c + i * 4
      w[i] = string.byte(msg, b) * 16777216 + string.byte(msg, b + 1) * 65536
        + string.byte(msg, b + 2) * 256 + string.byte(msg, b + 3)
    end
    for i = 16, 79 do
      w[i] = bit32.lrotate(bit32.bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, cc, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bit32.bor(bit32.band(b, cc), bit32.band(bit32.bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bit32.bxor(b, cc, d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bit32.bor(bit32.band(b, cc), bit32.band(b, d), bit32.band(cc, d))
        k = 0x8F1BBCDC
      else
        f = bit32.bxor(b, cc, d)
        k = 0xCA62C1D6
      end
      local t = (bit32.lrotate(a, 5) + f + e + k + w[i]) % 4294967296
      e = d
      d = cc
      cc = bit32.lrotate(b, 30)
      b = a
      a = t
    end
    h0 = (h0 + a) % 4294967296
    h1 = (h1 + b) % 4294967296
    h2 = (h2 + cc) % 4294967296
    h3 = (h3 + d) % 4294967296
    h4 = (h4 + e) % 4294967296
  end
  return whex(h0) .. whex(h1) .. whex(h2) .. whex(h3) .. whex(h4)
end

P.sha1hex = sha1hex

-- Search Podcast Index. cb(list) with { title, artist, feed, art, count },
-- or cb(nil) when unconfigured/failed. Never throws.
function P.search(term, limit, cb)
  local ok, key, secret = P.configured()
  if not ok then
    cb(nil)
    return
  end
  local t = tostring(os.time())
  local authOk, auth = pcall(sha1hex, key .. secret .. t)
  if not authOk or type(auth) ~= "string" then
    cb(nil)
    return
  end
  noctalia.http({
    url = "https://api.podcastindex.org/api/1.0/search/byterm?q="
      .. noctalia.string.urlEncode(term) .. "&max=" .. tostring(limit or 10),
    headers = {
      "X-Auth-Date: " .. t,
      "X-Auth-Key: " .. key,
      "Authorization: " .. auth,
      "User-Agent: noctalia-podcasts/0.1.0",
    },
  }, function(res)
    if not res.ok then
      cb(nil)
      return
    end
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" or type(data.feeds) ~= "table" then
      cb(nil)
      return
    end
    local out = {}
    for _, f in ipairs(data.feeds) do
      if type(f) == "table" and f.url and f.url ~= "" then
        table.insert(out, {
          title = f.title or "Unknown podcast",
          artist = f.author or "",
          feed = f.url,
          art = f.image or "",
          count = tonumber(f.episodeCount) or 0,
        })
      end
    end
    cb(out)
  end)
end

return P
