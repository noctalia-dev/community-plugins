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
--   noctalia.state.set("usage", <table>)   -- the parsed usage object
--   noctalia.state.set("status", {...})    -- loading / ready / error + availability
--
-- Force a refresh from the shell:
--   noctalia msg plugin nightwatch75/claude-cockpit:service all refresh

local scriptPath = `{noctalia.pluginDir()}/get-claude-usage`
local depsOk = noctalia.commandExists("jq") and noctalia.commandExists("curl")
local fetching = false
local started = false

local function publishStatus(state, message)
    noctalia.state.set("status", { state = state, available = depsOk, message = message or "" })
end

-- usage_refresh_interval is in minutes (2–15); convert to the update() cadence in ms.
local function intervalMs()
    local mins = noctalia.getConfig("usage_refresh_interval")
    if type(mins) ~= "number" or mins < 1 then
        mins = 2
    end
    return math.floor(mins * 60000)
end

local function fetch()
    if fetching then
        return
    end
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

-- update() fires immediately at load and then on the interval — refresh on
-- start, then every N minutes.
function update()
    noctalia.setUpdateInterval(intervalMs())
    if not started then
        started = true
        if not depsOk then
            publishStatus("error", "jq and curl are required")
        end
    end
    fetch()
end

-- The panel bumps this nonce (its refresh button) to force an out-of-band fetch.
noctalia.state.watch("refresh_nonce", function()
    fetch()
end)

function onIpc(event)
    if event == "refresh" then
        fetch()
    end
end
