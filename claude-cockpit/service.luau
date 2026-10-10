--!nonstrict
-- Claude Cockpit — headless service (usage data owner).
--
-- Runs get-claude-usage (with --json, copied from jrohland/claudecode —
-- MIT, see README Notes) on the configured interval,
-- decodes the result, and publishes it so the panel's Usage tab can read it
-- without shelling out itself. Sessions and CLAUDE.md are deliberately NOT
-- handled here: they are read on-demand by the panel (open + refresh
-- button), never polled — scanning every session file on a tick would scan
-- 60+ MB of transcripts for no reason most of the time.
--
-- Live sessions ARE polled here, every LIVE_TICK_MS, but only while someone
-- asks for them: the bar widget in activity mode and the panel on its Live
-- tab stamp "live_wanted_at" every tick; with no stamp in the last
-- LIVE_WANTED_SECS the poll stops. One poller, however many readers.
--
--   noctalia.state.set("usage", <table>)   -- the parsed usage object
--   noctalia.state.set("status", {...})    -- loading / ready / error + availability
--   noctalia.state.set("live", { groups, error })  -- see live.luau
--
-- Force a refresh from the shell:
--   noctalia msg plugin nightwatch75/claude-cockpit:service all refresh

local live = require("./live.luau")

local scriptPath = `{noctalia.pluginDir()}/get-claude-usage`
local LIVE_TICK_MS = 2000
local LIVE_WANTED_SECS = 5
local livePolling = false
local lastUsageFetch = nil
local depsOk = noctalia.commandExists("jq") and noctalia.commandExists("curl")
local fetching = false
local started = false

local function publishStatus(state, message)
    noctalia.state.set("status", { state = state, available = depsOk, message = message or "" })
end

-- usage_refresh_interval is in minutes (2–15).
local function intervalSecs()
    local mins = noctalia.getConfig("usage_refresh_interval")
    if type(mins) ~= "number" or mins < 1 then
        mins = 2
    end
    return math.floor(mins * 60)
end

local function fetch()
    if fetching then
        return
    end
    lastUsageFetch = os.time()
    if not depsOk then
        publishStatus("error", "jq and curl are required")
        return
    end

    fetching = true
    publishStatus("loading")

    local apiUrl = noctalia.getConfig("currency_api_url")
    if type(apiUrl) ~= "string" or apiUrl == "" then
        apiUrl = "https://api.frankfurter.dev/v1/latest"
    end

    local launched = noctalia.runAsync({ "bash", scriptPath, "--json", "--currency-api-url=" .. apiUrl }, function(result)
        fetching = false

        if type(result) ~= "table" or result.success == false or result.exitCode ~= 0 then
            noctalia.log("claude-cockpit: get-claude-usage failed")
            publishStatus("error", "Fetch failed")
            return
        end

        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" then
            noctalia.log("claude-cockpit: could not decode JSON output")
            publishStatus("error", "Bad data")
            return
        end

        noctalia.state.set("usage", data)
        publishStatus("ready")
    end)

    if not launched then
        fetching = false
        publishStatus("error", "Could not launch get-claude-usage")
    end
end

local function pollLive()
    if livePolling then
        return
    end
    livePolling = true
    live.refresh(function(groups, err)
        livePolling = false
        noctalia.state.set("live", { groups = groups, error = err })
    end)
end

-- update() fires immediately at load and then every LIVE_TICK_MS: usage on
-- start and then every N minutes, live sessions only while wanted.
function update()
    noctalia.setUpdateInterval(LIVE_TICK_MS)
    if not started then
        started = true
        if not depsOk then
            publishStatus("error", "jq and curl are required")
        end
    end
    if lastUsageFetch == nil or os.time() - lastUsageFetch >= intervalSecs() then
        fetch()
    end
    local wanted = tonumber(noctalia.state.get("live_wanted_at"))
    if wanted ~= nil and os.time() - wanted <= LIVE_WANTED_SECS then
        pollLive()
    end
end

-- Bumped by a reader that wants fresh data now (tab switch, refresh button).
noctalia.state.watch("live_nonce", function()
    pollLive()
end)

-- The panel bumps this nonce (its refresh button) to force an out-of-band fetch.
noctalia.state.watch("refresh_nonce", function()
    fetch()
end)

function onIpc(event)
    if event == "refresh" then
        fetch()
    end
end
