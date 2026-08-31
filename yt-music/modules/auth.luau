local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local network = require("../utils/network.luau")
local Bash = require("../utils/bash.luau")
local BROWSERS = require("../utils/browsers.luau")
local library = require("./library.luau")
local home = require("./home.luau")

local state = store.state
local log = logger.module("ytm", "auth")

local extraction_active = false

local Auth = {}

function Auth.browser_label(id)
    for _, b in ipairs(BROWSERS) do
        if b.id == id then return b.label end
    end
    return id or "Browser"
end

function Auth.open_login(browser)
    local target = (type(browser) == "string" and browser ~= "") and browser or "default"
    Bash.run_script("cookies.sh", "open_browser", function() end, 5000, target)
end

function Auth.extract_cookies(browser)
    if extraction_active then return end
    if type(browser) ~= "string" or browser == "" then return end
    if not network.isOnline() then
        state.status = "error"
        state.last_error = "You're offline — sign-in needs an internet connection"
        store.publish()
        return
    end
    local label = Auth.browser_label(browser)
    extraction_active = true
    state.extracting = true
    state.browser = browser
    state.browser_label = label
    state.status = "extracting"
    state.status_text = "Extracting cookies from " .. label .. "..."
    state.last_error = ""
    store.publish()

    Bash.run_script("cookies.sh", "extract_cookies", function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        log("extract: browser=" .. tostring(browser) .. " out=" .. tostring(out:sub(1, 200)))
        local dir = out:match("DIR=([^\n]+)") or ""
        local cookies = out:match("OUT=([^\n]+)") or ""
        local total = tonumber(out:match("TOTAL=([^\n]+)") or "0") or 0
        local kept = tonumber(out:match("KEPT=([^\n]+)") or "0") or 0
        local err_log = out:match("LOG=([^\n]*)") or ""

        extraction_active = false
        state.extracting = false

        if kept > 0 then
            state.status = "ready"
            state.temp_dir = dir
            state.cookies_path = cookies
            state.cookie_count = kept
            state.last_error = ""
            state.status_text = string.format("Saved %d YouTube cookies from %s (filtered %d others)",
                kept, label, math.max(0, total - kept))
            if noctalia.notify then
                noctalia.notify("YouTube Music", state.status_text)
            end
            if api and api.invalidate_auth then
                api.invalidate_auth()
            end
            if api and api.library then
                api.library()
            end
            if api and api.fetch_quick_picks then
                api.fetch_quick_picks(function(qp, mixes)
                    if type(qp) == "table" and #qp > 0 then
                        state.quick_picks = qp
                    end
                    if type(mixes) == "table" and #mixes > 0 then
                        state.home_mixes = mixes
                    end
                    store.publish()
                    home.fetch_home_thumbs()
                end)
            end
        else
            state.status = "error"
            state.cookies_path = ""
            state.temp_dir = dir
            state.cookie_count = 0
            state.last_error = err_log
            state.status_text = "No YouTube session found in " .. label
            Auth.open_login(browser)
            if noctalia.notify then
                noctalia.notify("YouTube Music", "No YouTube login in " .. label .. ". Opening YouTube Music — sign in, then click the button again.")
            end
        end
        store.publish()
    end, 60000, browser)
end

function Auth.load_cached_cookies()
    Bash.run_script("cookies.sh", "load_cached_cookies", function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if out:find("FOUND=1") then
            local kept = tonumber(out:match("KEPT=([^\n]+)") or "0") or 0
            local cookies = out:match("OUT=([^\n]+)") or ""
            if kept > 0 then
                state.status = "ready"
                state.cookies_path = cookies
                state.cookie_count = kept
                state.last_error = ""
                if state.status_text == "Not logged in" then
                    state.status_text = string.format("Loaded %d saved YouTube cookies", kept)
                end
                if api and api.invalidate_auth then
                    api.invalidate_auth()
                end
            if api and api.load_cached_playlist then
                local vllm = api.load_cached_playlist("VLLM")
                    if vllm then library.sync_liked_tracks(vllm) end
                end
                if api and api.load_cached_quick_picks then
                    local qp = api.load_cached_quick_picks()
                    if qp then state.quick_picks = qp end
                end
                library.sync_audio_cache()
                store.publish()
                if api and api.fetch_quick_picks then
                    api.fetch_quick_picks(function(qp, mixes)
                        if type(qp) == "table" and #qp > 0 then
                            state.quick_picks = qp
                        end
                        if type(mixes) == "table" and #mixes > 0 then
                            state.home_mixes = mixes
                        end
                        store.publish()
                        home.fetch_home_thumbs()
                    end)
                end
            end
        end
    end, 8000)
end

function Auth.detect_browsers()
    Bash.run_script("cookies.sh", "detect_browsers", function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        local available = {}
        for found in out:gmatch("FOUND=([^\n]+)") do
            available[found] = true
        end
        state.available = available
        store.publish()
    end, 8000)
end

return Auth