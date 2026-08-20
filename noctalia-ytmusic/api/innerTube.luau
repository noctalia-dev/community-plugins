--!strict

export type Response = {
    ok: boolean?,
    status: number?,
    body: string?,
}

local bit = bit32

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "innerTube")

local const = require("./constants.luau")
local KEY = const.KEY
local BASE = const.BASE
local ORIGIN = const.ORIGIN
local COOKIE_PATH = const.COOKIE_PATH

local EXPO = {}

-- ----------------------------------------------------------------------------
-- Pure-Luau SHA-1 (FIPS 180-1), uint32 math via bit32
-- ----------------------------------------------------------------------------

local function sha1(msg: string): string
    local mod32 = 0xFFFFFFFF
    local function hex32(n: number)
        local h = "0123456789abcdef"
        local out = {}
        for i = 1, 8 do
            local d = n % 16
            out[9 - i] = h:sub(d + 1, d + 1)
            n = math.floor(n / 16)
        end
        return table.concat(out)
    end
    local bytes = { string.byte(msg, 1, -1) }
    local bits = #bytes * 8
    table.insert(bytes, 0x80)
    while #bytes % 64 ~= 56 do
        table.insert(bytes, 0)
    end
    for i = 1, 8 do
        local shift = (8 - i) * 8
        table.insert(bytes, math.floor(bits / (2 ^ shift)) % 256)
    end

    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

    for pos = 1, #bytes, 64 do
        local w = {}
        for i = 0, 15 do
            local o = pos + i * 4
            w[i] = bit.bor(
                bit.lshift(bytes[o], 24),
                bit.lshift(bytes[o + 1], 16),
                bit.lshift(bytes[o + 2], 8),
                bytes[o + 3]
            )
        end
        for i = 16, 79 do
            w[i] = bit.lrotate(
                bit.bxor(bit.bxor(w[i - 3], w[i - 8]), bit.bxor(w[i - 14], w[i - 16])),
                1
            )
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i <= 19 then
                f = bit.bor(bit.band(b, c), bit.band(bit.bnot(b), d))
                k = 0x5A827999
            elseif i <= 39 then
                f = bit.bxor(bit.bxor(b, c), d)
                k = 0x6ED9EBA1
            elseif i <= 59 then
                f = bit.bor(bit.bor(bit.band(b, c), bit.band(b, d)), bit.band(c, d))
                k = 0x8F1BBCDC
            else
                f = bit.bxor(bit.bxor(b, c), d)
                k = 0xCA62C1D6
            end
            local temp = (bit.lrotate(a, 5) + f + e + k + w[i]) % (mod32 + 1)
            e, d, c, b, a = d, c, bit.lrotate(b, 30), a, temp
        end
        h0 = (h0 + a) % (mod32 + 1)
        h1 = (h1 + b) % (mod32 + 1)
        h2 = (h2 + c) % (mod32 + 1)
        h3 = (h3 + d) % (mod32 + 1)
        h4 = (h4 + e) % (mod32 + 1)
    end

    return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4)
end

do
    local abc = sha1("abc")
    log("sha1 self-test sha1(abc)=" .. abc .. (abc == "a9993e364706816aba3e25717850c26c9cd0d89d" and " OK" or " MISMATCH"))
end

-- ----------------------------------------------------------------------------
-- auth + request
-- ----------------------------------------------------------------------------

local function load_cookie_values()
    local values = {}
    local raw = noctalia.readFile(COOKIE_PATH)
    if not raw then
        log("readFile failed on " .. COOKIE_PATH)
        return values
    end
    log("cookies: path=" .. COOKIE_PATH .. " len=" .. #raw)
    for line in raw:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local fields = {}
            for f in line:gmatch("([^\t]+)") do
                table.insert(fields, f)
            end
            if #fields >= 7 and fields[6] == "SAPISID" then
                log("cookies: SAPISID line has " .. #fields .. " fields")
            end
            local name = fields[6]
            local value = fields[7]
            if name then
                values[name] = value
            end
        end
    end
    local names = {}
    for k in pairs(values) do table.insert(names, k) end
    table.sort(names)
    log("cookies: parsed " .. #names .. " (" .. table.concat(names, ",") .. "), values not logged")
    return values
end

local auth_state = { ready = false, sapisid = "", cookie = "" }

function EXPO.invalidate_auth()
    auth_state.ready = false
end

local function build_auth(): (string?, string?)
    if not auth_state.ready then
        local values = load_cookie_values()
        local sapisid = values["SAPISID"]
        if not sapisid or sapisid == "" then
            return nil, nil
        end
        local cookieParts = {}
        for k, v in pairs(values) do
            table.insert(cookieParts, k .. "=" .. v)
        end
        auth_state.sapisid = sapisid
        auth_state.cookie = table.concat(cookieParts, "; ")
        auth_state.ready = true
    end
    local ts = math.floor(noctalia.nowMs() / 1000)
    local hash = sha1(ts .. " " .. auth_state.sapisid .. " " .. ORIGIN)
    local auth = "SAPISIDHASH " .. ts .. "_" .. hash
    return auth, auth_state.cookie
end

local function innerTube(endpoint: string, request: any, cb: (any?, string?) -> (), defer: boolean?)
    local auth, cookie = build_auth()
    if not auth then
        log("innerTube: no SAPISID auth, request dropped")
        cb(nil, "no auth")
        return
    end
    local payload, perr = noctalia.json.encode(request)
    if not payload then
        log("innerTube: json encode failed " .. tostring(perr))
        cb(nil, tostring(perr))
        return
    end
    log("innerTube POST " .. endpoint .. " body=" .. #payload .. " bytes")
    local accepted = noctalia.http({
        url = BASE .. endpoint .. "?key=" .. KEY .. "&prettyPrint=false",
        method = "POST",
        body = payload,
        headers = {
            "Content-Type: application/json",
            "Authorization: " .. auth,
            "Origin: " .. ORIGIN,
            "Cookie: " .. (cookie or ""),
            "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        },
    }, function(resp: Response?)
        if not resp then
            log("innerTube " .. endpoint .. ": no response")
            cb(nil, "no response")
            return
        end
        if not resp.ok then
            log("innerTube " .. endpoint .. ": http status=" .. tostring(resp.status))
            cb(nil, "http " .. tostring(resp.status))
            return
        end
        if defer then
            log("innerTube " .. endpoint .. ": got " .. #(resp.body or "") .. " bytes (deferred)")
            cb(resp.body)
            return
        end
        local data, jerr = noctalia.json.decode(resp.body or "")
        if not data then
            log("innerTube " .. endpoint .. ": json decode failed " .. tostring(jerr))
            cb(nil, "json " .. tostring(jerr))
            return
        end
        log("innerTube " .. endpoint .. ": got " .. #(resp.body or "") .. " bytes, parsed ok")
        cb(data)
    end)
    if not accepted then
        log("innerTube " .. endpoint .. ": request rejected by host")
        cb(nil, "request rejected")
    end
end

EXPO.sha1 = sha1
EXPO.build_auth = build_auth
EXPO.innerTube = innerTube

return EXPO