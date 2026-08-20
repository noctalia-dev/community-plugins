--!strict

-- like / unlike endpoints.

local helpers = require("../utils/helpers.luau")
local sanitize = helpers.sanitize

local const = require("./constants.luau")
local CONTEXT = const.CONTEXT
local ORIGIN = const.ORIGIN
local COOKIE_PATH = const.COOKIE_PATH

local it = require("./innerTube.luau")
local build_auth = it.build_auth

local EXPO = {}

function EXPO.like_video(video_id: string?, callback: ((boolean) -> ())?)
    if type(video_id) ~= "string" or video_id == "" then
        if callback then callback(false) end
        return
    end
    local safe_id = sanitize(video_id)
    local body_json = noctalia.json.encode({
        context = CONTEXT.context,
        target = { videoId = safe_id }
    }) or ""
    local auth = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""
    local tmp_payload = "/tmp/noctalia-ytmusic-like-payload.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/like/like?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-like-payload.json" >/dev/null 2>&1
echo "STATUS=OK"
]=]
    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 10000)
end

function EXPO.unlike_video(video_id: string?, callback: ((boolean) -> ())?)
    if type(video_id) ~= "string" or video_id == "" then
        if callback then callback(false) end
        return
    end
    local safe_id = sanitize(video_id)
    local body_json = noctalia.json.encode({
        context = CONTEXT.context,
        target = { videoId = safe_id }
    }) or ""
    local auth = build_auth()
    local auth_header = auth and ("-H \"Authorization: " .. auth .. "\"") or ""
    local origin_header = "-H \"Origin: " .. ORIGIN .. "\""
    local tmp_payload = "/tmp/noctalia-ytmusic-unlike-payload.json"
    noctalia.writeFile(tmp_payload, body_json)

    local script = [=[
export PATH="/etc/profiles/per-user/$USER/bin:$PATH"
C_ARG=""
if [ -s "]=] .. COOKIE_PATH .. [=[" ]; then
  C_ARG="--cookie ]=] .. COOKIE_PATH .. [=["
fi

curl -s -X POST "https://music.youtube.com/youtubei/v1/like/removelike?prettyPrint=false" \
  -H "Content-Type: application/json" \
  ]=] .. origin_header .. [=[ \
  ]=] .. auth_header .. [=[ \
  $C_ARG \
  -d @"/tmp/noctalia-ytmusic-unlike-payload.json" >/dev/null 2>&1
echo "STATUS=OK"
]=]
    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local ok = out:find("STATUS=OK") ~= nil
        if callback then callback(ok) end
    end, 10000)
end

return EXPO