--!nonstrict
-- Headless poller: the single owner of `ai-usagebar usage --json`.
--
-- One call returns every configured vendor, so the capsules and the panel are
-- pure subscribers of noctalia.state and never spawn a process of their own.

-- `ai-usagebar` is a declared dependency, so it is expected on PATH.
local COMMAND = "ai-usagebar usage --json"

local function intervalMs()
    local minutes = tonumber(noctalia.getConfig("refresh_minutes")) or 5
    if minutes < 1 then minutes = 1 end
    return math.floor(minutes * 60 * 1000)
end

-- Everything below this line is text the CLI produced, and every bit of it ends
-- up on screen. It is cleaned once, here, where it enters the plugin:
-- an error can quote the request that failed, and a request can carry a key in
-- its query string. A runaway line would also push a bar capsule off screen.
local function safeText(value)
    local text = noctalia.string.trim(tostring(value or ""))
    text = text:gsub("%s+", " ")
    text = text:gsub("([%w_%-]*[Kk][Ee][Yy][%w_%-]*=)[^%s]+", "%1<redacted>")
    text = text:gsub("([Tt][Oo][Kk][Ee][Nn][%w_%-]*=)[^%s]+", "%1<redacted>")
    text = text:gsub("([Ss][Ee][Cc][Rr][Ee][Tt][%w_%-]*=)[^%s]+", "%1<redacted>")
    text = text:gsub("([Bb]earer%s+)[%w%._%-]+", "%1<redacted>")
    if #text > 200 then text = string.sub(text, 1, 200) .. "..." end
    return text
end

local inFlight = false

local function refresh()
    if inFlight then return end
    inFlight = true
    noctalia.state.set("polling", true)

    noctalia.runAsync(COMMAND, function(result)
        inFlight = false
        noctalia.state.set("polling", false)

        local decoded = result ~= nil and noctalia.json.decode(result.stdout or "") or nil
        if type(decoded) == "table" and type(decoded.entries) == "table" then
            -- A vendor that failed still comes back as an entry with `status =
            -- "error"`, so a non-zero exit is not a reason to drop the report.
            for _, entry in ipairs(decoded.entries) do
                if entry.error ~= nil then entry.error = safeText(entry.error) end
            end
            noctalia.state.set("report", decoded)
            noctalia.state.set("error", "")
            return
        end

        local message = "ai-usagebar returned no usage data"
        if result == nil then
            message = "could not run ai-usagebar"
        elseif result.timedOut then
            message = "ai-usagebar timed out"
        elseif result.exitCode ~= 0 then
            local stderr = safeText(result.stderr)
            message = stderr ~= "" and stderr or ("ai-usagebar exited with code " .. tostring(result.exitCode))
        end
        noctalia.state.set("error", message)
    end, 30000)
end

-- Manual refresh from a capsule or the panel.
noctalia.state.watch("command", function(value)
    if type(value) == "table" and value.action == "refresh" then refresh() end
end)

function update()
    noctalia.setUpdateInterval(intervalMs())
    refresh()
end

function onConfigChanged()
    noctalia.setUpdateInterval(intervalMs())
    refresh()
end

function onIpc(event, payload)
    if event == "refresh" then refresh() end
    -- `select <provider-id>` points the panel at one provider from a script.
    if event == "select" and type(payload) == "string" and payload ~= "" then
        noctalia.state.set("selected", payload)
    end
end

noctalia.setUpdateInterval(intervalMs())
refresh()
