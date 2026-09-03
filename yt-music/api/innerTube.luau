--!strict

export type Response = {
	ok: boolean?,
	status: number?,
	body: string?,
}


local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "innerTube")
local sha1 = require("../utils/sha1.luau").sha1

local const = require("./constants.luau")
local network = require("../utils/network.luau")
local KEY = const.KEY
local BASE = const.BASE
local ORIGIN = const.ORIGIN
local COOKIE_PATH = const.COOKIE_PATH

local EXPO = {}

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
	for k in pairs(values) do
		table.insert(names, k)
	end
	table.sort(names)
	log("cookies: parsed " .. #names .. " (" .. table.concat(names, ",") .. "), values not logged")
	return values
end

local auth_state = { ready = false, sapisid = "", cookie = "" }
-- SAPISIDHASH is stable for a whole second; memoize so a boot burst of
-- requests pays the pure-Luau SHA-1 once instead of per request.
local auth_memo_ts: number?, auth_memo_header: string? = nil, nil

function EXPO.invalidate_auth()
	auth_state.ready = false
	auth_memo_ts, auth_memo_header = nil, nil
end

local function build_auth(): (string?, string?)
	if not auth_state.ready or auth_state.sapisid == "" then
		local values = load_cookie_values()
		local sapisid = values["SAPISID"]
		local cookieParts = {}
		for k, v in pairs(values) do
			table.insert(cookieParts, k .. "=" .. v)
		end
		auth_state.cookie = #cookieParts > 0 and table.concat(cookieParts, "; ") or ""
		if sapisid and sapisid ~= "" then
			auth_state.sapisid = sapisid
			auth_state.ready = true
		else
			auth_state.sapisid = ""
			auth_state.ready = false
		end
		auth_memo_ts, auth_memo_header = nil, nil
	end
	if auth_state.sapisid == "" then
		return nil, #auth_state.cookie > 0 and auth_state.cookie or nil
	end
	local ts = math.floor(noctalia.nowMs() / 1000)
	if auth_memo_header and auth_memo_ts == ts then
		return auth_memo_header, auth_state.cookie
	end
	local hash = sha1(ts .. " " .. auth_state.sapisid .. " " .. ORIGIN)
	auth_memo_ts, auth_memo_header = ts, ("SAPISIDHASH %d_%s"):format(ts, hash)
	return auth_memo_header, auth_state.cookie
end

local function innerTube(endpoint: string, request: any, cb: (any?, string?) -> (), defer: boolean?)
	if not network.isOnline() then
		log("innerTube " .. endpoint .. ": offline, request dropped")
		cb(nil, "offline")
		return
	end
	local auth, cookie = build_auth()
	local payload, perr = noctalia.json.encode(request)
	if not payload then
		log("innerTube: json encode failed " .. tostring(perr))
		cb(nil, tostring(perr))
		return
	end
	log("innerTube POST " .. endpoint .. " body=" .. #payload .. " bytes (auth=" .. tostring(auth ~= nil) .. ")")
	local headers = {
		"Content-Type: application/json",
		"Origin: " .. ORIGIN,
		"User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
	}
	if auth then
		table.insert(headers, "Authorization: " .. auth)
	end
	if cookie then
		table.insert(headers, "Cookie: " .. cookie)
	end
	local accepted = network.http({
		url = BASE .. endpoint .. "?key=" .. KEY .. "&prettyPrint=false",
		method = "POST",
		body = payload,
		headers = headers,
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

EXPO.build_auth = build_auth
EXPO.innerTube = innerTube

return EXPO
