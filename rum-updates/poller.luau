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
    setChecking(false)
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

local finishRefresh

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
            finishRefresh(filtered)
        else
            finishRefresh(parsed)
        end
    end, commandTimeoutMs)

    if not started then
        finishRefresh(parsed)
    end
end

local function resultOk(result)
    return type(result) == "table" and result.timedOut ~= true and result.exitCode == 0
end

local function parseInstalledVersions(stdout)
    local installed = {}
    if type(stdout) ~= "string" then
        return installed
    end

    for line in string.gmatch(stdout, "[^\r\n]+") do
        local text = trim(line)
        if text ~= "" then
            local appId, version = text:match("^([^\t]+)\t(.*)$")
            if appId then
                installed[appId] = trim(version or "")
            end
        end
    end

    return installed
end

local function runtimeDetail(lower)
    if string.sub(lower, -13) == ".gl32.default" then
        return "Mesa (32-bit)"
    end
    if string.sub(lower, -11) == ".gl.default" then
        return "Mesa"
    end
    if string.find(lower, ".gl32.nvidia", 1, true) or string.find(lower, ".gl.nvidia", 1, true) then
        return "NVIDIA Driver"
    end
    if string.find(lower, ".vaapi", 1, true) then
        return "VA-API"
    end
    if string.sub(lower, -13) == ".codecs-extra" then
        return "Codecs (Extra)"
    end
    if string.sub(lower, -7) == ".codecs" then
        return "Codecs"
    end
    if string.sub(lower, -9) == ".openh264" then
        return "OpenH264"
    end
    if string.sub(lower, -12) == ".ffmpeg-full" then
        return "FFmpeg"
    end
    if string.sub(lower, -4) == ".sdk" then
        return "SDK"
    end
    if string.sub(lower, -7) == ".locale" then
        return "Locale"
    end
    return nil
end

local function runtimeDisplayName(appId)
    local detail = runtimeDetail(string.lower(appId))
    local components = {}
    for part in string.gmatch(appId, "[^.]+") do
        table.insert(components, part)
    end
    local vendor = string.lower(components[2] or "")
    local vendorNames = {
        gnome = "GNOME",
        kde = "KDE",
        freedesktop = "Freedesktop",
        gimp = "GIMP",
        libreoffice = "LibreOffice",
        mozilla = "Mozilla",
    }
    local component = components[3] or appId
    local last = components[#components] or appId
    local base = vendorNames[vendor] and (vendorNames[vendor] .. " " .. component) or component
    if detail then
        if string.lower(component) == string.lower(last) then
            return base .. " " .. detail
        end
        return base .. " — " .. detail
    end
    if string.lower(last) == string.lower(component) then
        return base
    end
    return base .. " — " .. last
end

local function flatpakName(appId, runtime)
    if runtime then
        return runtimeDisplayName(appId)
    end
    return appId:match("([^.]+)$") or appId
end

local function parseFlatpakUpdates(stdout, installed, installation)
    local entries = {}
    if type(stdout) ~= "string" then
        return entries
    end

    for line in string.gmatch(stdout, "[^\r\n]+") do
        local text = trim(line)
        if text ~= "" then
            local appId, branch, version, refField = text:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
            appId = trim(appId or "")
            if appId ~= "" then
                local runtime = string.sub(refField or "", 1, 8) == "runtime/"
                table.insert(entries, {
                    name = flatpakName(appId, runtime),
                    current_version = installed[appId] or "",
                    version = trim(version or ""),
                    arch = "",
                    repo = "",
                    kind = "flatpak",
                    app_id = appId,
                    runtime = runtime,
                    branch = trim(branch or ""),
                    installation = installation,
                })
            end
        end
    end

    return entries
end

local function mergeUpdates(rumUpdates, flatpaks)
    local combined = {}
    for _, update in ipairs(rumUpdates) do
        table.insert(combined, update)
    end
    for _, update in ipairs(flatpaks) do
        table.insert(combined, update)
    end

    table.sort(combined, function(left, right)
        if left.kind == right.kind then
            if left.name == right.name then
                if (left.arch or "") == (right.arch or "") then
                    return (left.repo or "") < (right.repo or "")
                end
                return (left.arch or "") < (right.arch or "")
            end
            return left.name < right.name
        end
        if left.kind == "flatpak" then
            return false
        end
        return right.kind == "flatpak"
    end)

    return combined
end

local function detectFlatpakUpdates(done)
    if not noctalia.commandExists("flatpak") then
        done({})
        return
    end

    local combined = {}
    local steps = {}
    local scopes = {
        { scope = "system", flag = "--system" },
        { scope = "user", flag = "--user" },
    }

    for _, scope in ipairs(scopes) do
        local workspace = {}
        table.insert(steps, {
            command = string.format("flatpak list %s --columns=application,version", scope.flag),
            onResult = function(result)
                if resultOk(result) then
                    workspace.installed = parseInstalledVersions(result.stdout)
                end
            end,
        })
        table.insert(steps, {
            command = string.format("flatpak remote-ls %s --updates --columns=application,branch,version,ref", scope.flag),
            onResult = function(result)
                if resultOk(result) then
                    local found = parseFlatpakUpdates(result.stdout, workspace.installed or {}, scope.scope)
                    for _, update in ipairs(found) do
                        table.insert(combined, update)
                    end
                end
            end,
        })
    end

    local index = 1
    local function runNext()
        if index > #steps then
            done(combined)
            return
        end

        local step = steps[index]
        index = index + 1
        local started = noctalia.runAsync(step.command, function(result)
            step.onResult(result)
            runNext()
        end, commandTimeoutMs)
        if not started then
            done(combined)
        end
    end

    runNext()
end

finishRefresh = function(rumUpdates)
    detectFlatpakUpdates(function(flatpaks)
        commitUpdates(mergeUpdates(rumUpdates, flatpaks))
    end)
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
        if type(result) ~= "table" then
            setChecking(false)
            fail(noctalia.tr("poller.error.invalid_result"))
            return
        end
        if result.timedOut == true then
            setChecking(false)
            fail(noctalia.tr("poller.error.timed_out", {
                seconds = commandTimeoutMs / 1000,
            }))
            return
        end
        if result.exitCode ~= 0 then
            setChecking(false)
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
            setChecking(false)
            fail(parseError)
            return
        end

        if #parsed == 0 then
            finishRefresh(parsed)
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
