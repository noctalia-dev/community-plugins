-- bt-buds service: headset connection + codec, tiny state.

local function detect_home()
    local ok, v = pcall(function() return os.getenv("HOME") end)
    if ok and type(v) == "string" and v ~= "" then return v end
    local ok2, h = pcall(function()
        local f = io.popen("printf '%s' \"$HOME\"")
        if not f then return nil end
        local out = f:read("*a")
        f:close()
        return out
    end)
    if ok2 and type(h) == "string" and h ~= "" then return h end
    return "/home/jswift"
end
local HOME = detect_home()
local PLUGIN_DIR = HOME .. "/.local/share/noctalia/plugins/bt-buds"
local STATE_DIR = HOME .. "/.local/state/bt-buds"
local SVC_STATE = "btbuds.status"
local CODECS = { "sbc", "sbc_xq", "aac" }
local PROFILES = {
    sbc = "a2dp-sink-sbc",
    sbc_xq = "a2dp-sink-sbc_xq",
    aac = "a2dp-sink",
}
local EQ_PRESETS = { "normal", "more_bass", "boost_vocals", "more_highs" }
local eq_index = 1

local function play_sound(name)
    -- NB: os.execute is neutered in the service sandbox; use runAsync.
    noctalia.runAsync("ffplay -nodisp -autoexit -v 0 /usr/share/sounds/freedesktop/stereo/" .. name .. ".oga >/dev/null 2>&1 &")
end

local snap = { connected = false, codec = "", mac = "", mode = "off", bat = "", bat_l = -1, bat_r = -1, bat_c = -1, lang = "auto", eq_preset = "normal" }

local function publish()
    noctalia.state.set(SVC_STATE, {
        connected = snap.connected,
        codec = snap.codec,
        mac = snap.mac,
        mode = snap.mode,
        bat = snap.bat,
        bat_l = snap.bat_l,
        bat_r = snap.bat_r,
        bat_c = snap.bat_c,
        lang = snap.lang,
        eq_preset = snap.eq_preset,
    })
end

local function read_lang()
    local okf, content = pcall(noctalia.readFile, STATE_DIR .. "/lang")
    if okf and type(content) == "string" then
        local v = content:match("(%w+)")
        if v == "ru" or v == "en" or v == "auto" then return v end
    end
    return "auto"
end

local function apply_eq_result(out, exitCode)
    local v = (out or ""):match("ok%s+(%S+)")
    if exitCode == 0 and v then
        for i, p in ipairs(EQ_PRESETS) do
            if p == v then
                eq_index = i
                snap.eq_preset = v
                return true
            end
        end
    end
    return false
end

local function refresh()
    noctalia.runAsync(
        "card=$(pactl list cards short 2>/dev/null | grep bluez_card | head -n1 | cut -f2);"
        .. " if [ -z \"$card\" ]; then echo connected=0;"
        .. " else codec=$(pactl list sinks 2>/dev/null | grep -m1 'api.bluez5.codec' | sed 's/.*= //;s/\"//g');"
        .. " echo connected=1; echo \"card=$card\"; echo \"codec=$codec\"; fi",
        function(result)
            local out = (result and result.stdout) or ""
            local connected, card, codec = false, "", ""
            for line in out:gmatch("[^\r\n]+") do
                local k, v = line:match("^(%w+)=(.*)$")
                if k == "connected" and v == "1" then connected = true end
                if k == "card" then card = v end
                if k == "codec" then codec = v end
            end
            snap.connected = connected
            snap.codec = codec
            if card ~= "" then
                local mac = card:match("^bluez_card%.(.*)$") or ""
                snap.mac = mac:gsub("_", ":")
            end
            local okf, content = pcall(noctalia.readFile, STATE_DIR .. "/mode.json")
            if okf and type(content) == "string" then
                local v = content:match('"mode":%s*"(%w+)"')
                if v == "anc" or v == "transparency" or v == "off" then snap.mode = v end
            end
            snap.lang = read_lang()
            -- eq state + battery are independent: fetch concurrently, publish once
            local pending = 2
            local function done()
                pending = pending - 1
                if pending <= 0 then publish() end
            end
            noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/eq.py get", function(eqres)
                if eqres and eqres.exitCode == 0 then
                    apply_eq_result(eqres.stdout, eqres.exitCode)
                end
                done()
            end)
            noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/battery.py 2>/dev/null",
                function(result)
                    local out = (result and result.stdout) or ""
                    local l, r, c = out:match("(%d+)%s+(%d+)%s+(-?%d+)")
                    if result and result.exitCode == 0 and l then
                        snap.bat_l = tonumber(l) or -1
                        snap.bat_r = tonumber(r) or -1
                        snap.bat_c = tonumber(c) or -1
                        local cs = snap.bat_c >= 0 and ("Case " .. c .. "%") or "Case Closed"
                        snap.bat = "L " .. l .. "% · R " .. r .. "% · " .. cs
                    end
                    -- on failure keep last known values instead of blanking
                    done()
                end
            )
        end
    )
end

local function next_codec(cur)
    for i, c in ipairs(CODECS) do
        if c == cur then
            return CODECS[(i % #CODECS) + 1]
        end
    end
    return CODECS[1]
end

local function rebuild_eq()
    local cur = snap.eq_preset or "normal"
    noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/eq.py set " .. cur, function(result)
        if result then apply_eq_result(result.stdout, result.exitCode) end
        refresh()
    end)
end

function onIpc(event, _payload)
    if event == "refresh" then
        refresh()
    elseif event == "hold" then
        refresh()
    elseif event == "toggle" then
        if snap.mac == "" then
            refresh()
            return
        end
        local action = snap.connected and "disconnect" or "connect"
        noctalia.runAsync("bluetoothctl " .. action .. " " .. snap.mac, function()
            refresh()
        end)
    elseif event == "cycle_codec" then
        if not snap.connected or snap.mac == "" then return end
        local target = next_codec(snap.codec)
        local card = "bluez_card." .. snap.mac:gsub(":", "_")
        noctalia.runAsync("pactl set-card-profile " .. card .. " " .. PROFILES[target], function()
            refresh()
            rebuild_eq()
        end)
    elseif event == "cycle_eq" then
        if not snap.connected then return end
        local nxt = EQ_PRESETS[(eq_index % #EQ_PRESETS) + 1]
        noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/eq.py set " .. nxt, function(result)
            if result and apply_eq_result(result.stdout, result.exitCode) then
                publish()
            end
        end)
    elseif event == "set_eq" then
        if not snap.connected then return end
        local want = (_payload == "more_bass" or _payload == "boost_vocals" or _payload == "more_highs") and _payload or "normal"
        noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/eq.py set " .. want, function(result)
            if result and apply_eq_result(result.stdout, result.exitCode) then
                publish()
            end
        end)
    elseif event == "set_mode" then
        if not snap.connected then return end
        local want = (_payload == "anc" or _payload == "transparency") and _payload or "off"
        noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/mode.py " .. want, function(result)
            local out = (result and result.stdout) or ""
            local v = out:match("(%w+)")
            if result and result.exitCode == 0 and (v == "anc" or v == "transparency" or v == "off") then
                snap.mode = v
                publish()
            end
        end)
elseif event == "cycle_mode" then
        if not snap.connected then return end
        local order = { off = "anc", anc = "transparency", transparency = "off" }
        local want = order[snap.mode] or "anc"
        noctalia.runAsync("python3 " .. PLUGIN_DIR .. "/mode.py " .. want, function(result)
            local out = (result and result.stdout) or ""
            local v = out:match("(%w+)")
            if result and result.exitCode == 0 and (v == "anc" or v == "transparency" or v == "off") then
                snap.mode = v
                publish()
                play_sound("complete")
            end
        end)
    elseif event == "cycle_lang" then
        local cur = read_lang()
        local nxt = (cur == "auto") and "ru" or ((cur == "ru") and "en" or "auto")
        pcall(noctalia.writeFile, STATE_DIR .. "/lang", nxt)
        snap.lang = nxt
        publish()
        play_sound("message-new-instant")
    elseif event == "set_codec" then
        if not snap.connected or snap.mac == "" then return end
        local want = (_payload == "sbc_xq" or _payload == "aac" or _payload == "sbc") and _payload or "sbc"
        local card = "bluez_card." .. snap.mac:gsub(":", "_")
        noctalia.runAsync("pactl set-card-profile " .. card .. " " .. PROFILES[want], function()
            refresh()
            rebuild_eq()
        end)
    end
end

function onOpen()
    publish()
    refresh()
end

function onExit() end

onOpen()
