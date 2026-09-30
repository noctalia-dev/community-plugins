--!nonstrict

local updates = {}
local isPolling = false
local currentError = nil
local commandTimeoutMs = 60000

local interval = tonumber(noctalia.getConfig("interval")) or 300
interval = math.max(60, math.min(interval, 86400))
noctalia.setUpdateInterval(interval * 1000)

noctalia.state.set("updates", updates)
noctalia.state.set("update_error", nil)
noctalia.state.set("update_checking", false)

local upgradeWatchTicks = 0
local upgradeWatchSeconds = 10
local upgradeWatchMaxTicks = 120

local function setChecking(value)
    isPolling = value
    noctalia.state.set("update_checking", value)
end

local function applyPollInterval()
    local seconds = interval
    if upgradeWatchTicks > 0 then
        seconds = math.min(upgradeWatchSeconds, interval)
    end
    noctalia.setUpdateInterval(seconds * 1000)
end

local function startUpgradeWatch()
    upgradeWatchTicks = upgradeWatchMaxTicks
    applyPollInterval()
end

-- Returns true while a post-upgrade watch is still running, so transient
-- failures while rum holds the package database are not surfaced as errors.
local function consumeUpgradeWatchTick(reachedZero)
    if upgradeWatchTicks == 0 then
        return false
    end

    upgradeWatchTicks = upgradeWatchTicks - 1
    if reachedZero or upgradeWatchTicks <= 0 then
        upgradeWatchTicks = 0
        applyPollInterval()
    end

    return true
end

local function trim(value)
    return noctalia.string.trim(value or "")
end

local function cleanError(value)
    local message = trim(value)
    if message == "" then
        return noctalia.tr("poller.error.exit", { code = "unknown" })
    end
    if #message > 500 then
        return string.sub(message, 1, 497) .. "..."
    end
    return message
end

local function findJson(stdout)
    if type(stdout) ~= "string" then
        return nil
    end

    local candidate = nil
    for line in string.gmatch(stdout, "[^\r\n]+") do
        local text = trim(line)
        if string.sub(text, 1, 1) == "{" and string.sub(text, -1) == "}" then
            candidate = text
        end
    end
    return candidate
end

local function decodeUpdates(stdout)
    local text = findJson(stdout)
    if text == nil then
        return nil, noctalia.tr("poller.error.invalid_json")
    end

    local decoded, decodeError = noctalia.json.decode(text)
    if decoded == nil or decodeError ~= nil then
        return nil, noctalia.tr("poller.error.decode_failed", {
            error = decodeError or noctalia.tr("poller.error.invalid_json"),
        })
    end
    if type(decoded) ~= "table" or type(decoded.updates) ~= "table" then
        return nil, noctalia.tr("poller.error.invalid_payload")
    end

    local parsed = {}
    for _, update in ipairs(decoded.updates) do
        if type(update) ~= "table"
            or type(update.name) ~= "string"
            or type(update.current_version) ~= "string"
            or type(update.version) ~= "string"
            or type(update.arch) ~= "string"
            or type(update.repo) ~= "string" then
            return nil, noctalia.tr("poller.error.invalid_payload")
        end

        table.insert(parsed, {
            name = update.name,
            current_version = update.current_version,
            version = update.version,
            arch = update.arch,
            repo = update.repo,
        })
    end

    table.sort(parsed, function(left, right)
        if left.name == right.name then
            if left.arch == right.arch then
                return left.repo < right.repo
            end
            return left.arch < right.arch
        end
        return left.name < right.name
    end)

    return parsed
end

local function showError(message)
    currentError = cleanError(message)
    noctalia.state.set("update_error", currentError)
end

-- Errors are swallowed while watching for an upgrade to finish, so a failed
-- check during the upgrade does not replace the update list with an error.
local function fail(message)
    if consumeUpgradeWatchTick(false) then
        return
    end
    showError(message)
end

local function commitUpdates(parsed)
    updates = parsed
    currentError = nil
    noctalia.state.set("updates", updates)
    noctalia.state.set("update_error", nil)
    consumeUpgradeWatchTick(#updates == 0)
end

-- rum 0.1.0 `check-upgrade` can report a candidate that its own upgrade
-- resolution will not apply (a phantom version that exists in no repo, e.g.
-- from within the `updates` repository). Cross-validate the structured update
-- list against `rum upgrade --dry-run`, which resolves exactly what the
-- widget's update action will run, and drop any candidate `upgrade` would not
-- upgrade. If the dry run itself fails, keep the reported updates unchanged.
local function planMatchesLine(line, name)
    local prefix = name .. "-"
    return string.sub(line, 1, #prefix) == prefix
        and string.sub(line, -1, -1) == ")"
end

local function crossCheckWithUpgradePlan(parsed)
    local started = noctalia.runAsync("rum upgrade --dry-run", function(result)
        if type(result) == "table" and result.timedOut ~= true and result.exitCode == 0 then
            local stdout = trim(result.stdout)
            local filtered = {}
            for _, update in ipairs(parsed) do
                local found = false
                for line in string.gmatch(stdout, "[^\r\n]+") do
                    if planMatchesLine(trim(line), update.name) then
                        found = true
                        break
                    end
                end
                if found then
                    table.insert(filtered, update)
                end
            end
            commitUpdates(filtered)
        else
            commitUpdates(parsed)
        end
    end, commandTimeoutMs)

    if not started then
        commitUpdates(parsed)
    end
end

local function refresh()
    if isPolling then
        return
    end

    if not noctalia.commandExists("rum") then
        setChecking(false)
        updates = {}
        noctalia.state.set("updates", updates)
        fail(noctalia.tr("poller.error.missing_rum"))
        return
    end

    setChecking(true)
    local started = noctalia.runAsync("rum check-upgrade --json", function(result)
        setChecking(false)

        if type(result) ~= "table" then
            fail(noctalia.tr("poller.error.invalid_result"))
            return
        end
        if result.timedOut == true then
            fail(noctalia.tr("poller.error.timed_out", {
                seconds = commandTimeoutMs / 1000,
            }))
            return
        end
        if result.exitCode ~= 0 then
            local message = noctalia.tr("poller.error.exit", {
                code = tostring(result.exitCode),
            })
            local detail = trim(result.stderr)
            if detail ~= "" then
                message = string.format("%s: %s", message, detail)
            end
            fail(message)
            return
        end

        local parsed, parseError = decodeUpdates(result.stdout)
        if parsed == nil then
            fail(parseError)
            return
        end

        if #parsed == 0 then
            commitUpdates(parsed)
            return
        end

        crossCheckWithUpgradePlan(parsed)
    end, commandTimeoutMs)

    if not started then
        setChecking(false)
        updates = {}
        noctalia.state.set("updates", updates)
        fail(noctalia.tr("poller.error.launch_failed"))
    end
end

function update()
    refresh()
end

function onIpc(event)
    if event == "refresh" then
        refresh()
    elseif event == "upgrade_started" then
        startUpgradeWatch()
        refresh()
    elseif event == "status" then
        noctalia.log(string.format(
            "RUM Updates: updates=%d error=%s checking=%s watch=%s",
            #updates,
            currentError or "none",
            tostring(isPolling),
            tostring(upgradeWatchTicks > 0)
        ))
    end
end

refresh()
