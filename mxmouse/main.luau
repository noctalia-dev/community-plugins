--!nonstrict

local DEFAULTS = {
    version = 1,
    applyGeneration = 0,
    device = {
        autoDetect = true,
        path = "",
        triggerButton = "BTN_FORWARD",
        dpi = 0,
        verticalScroll = 100,
        horizontalScroll = 100,
    },
    defaultPresetId = "default",
    presets = {
        {
            id = "default",
            name = "Default",
            mode = "gesture",
            glyph = "arrows-move",
            dpi = 0,
            verticalScroll = 0,
            horizontalScroll = 0,
            threshold = 100,
            retriggerDistance = 100,
            escalation = 0,
            metaKey = "KEY_LEFTMETA",
            bindings = {
                left = { type = "niri", value = "focus-column-left" },
                right = { type = "niri", value = "focus-column-right" },
                up = { type = "niri", value = "focus-workspace-up" },
                down = { type = "niri", value = "focus-workspace-down" },
                tap = { type = "niri", value = "toggle-overview" },
                scrollUp = { type = "niri", value = "focus-workspace-up" },
                scrollDown = { type = "niri", value = "focus-workspace-down" },
                thumbwheelLeft = { type = "niri", value = "" },
                thumbwheelRight = { type = "niri", value = "" },
                thumbwheelButtonLeft = { type = "niri", value = "" },
                thumbwheelButtonRight = { type = "niri", value = "" },
                sideBack = { type = "niri", value = "" },
                sideForward = { type = "niri", value = "" },
                thumbLeftClick = { type = "niri", value = "" },
                thumbMiddleClick = { type = "niri", value = "" },
                thumbRightClick = { type = "niri", value = "" },
            },
        },
    },
    appPresets = {},
}

local CONFIG_PATH = nil
local STATUS_PATH = nil
local CANDIDATE_PATH = nil
local config = nil
local status = nil
local daemonInstalled = nil
local serviceEnabled = nil
local serviceActive = nil
local windows = {}
local selectedPresetId = "default"
local deviceDPIInput = "0"
local verticalScrollInput = "100"
local horizontalScrollInput = "100"
local message = ""
local saving = false
local configuringService = false
local localSourceAvailable = false
local localBuildAvailable = false
local activePage = "overview"
local nextPresetNumber = 0
local selectedActionKey = "left"
local selectedSideButtonKey = "sideBack"
local profileSectionExpanded = {}
local actionOptions = { niri = {}, noctalia = {} }
local logLines = {}
local logStreamStarted = false
local logStreamError = nil
local servicePollInFlight = false
local windowRefreshInFlight = false
local windowListSignature = ""
local lastFocusedWindow = nil
local appIconPaths = {}
local notifiedServiceError = ""
local pendingConfigGeneration = nil
local load_status
local render

local function default_config()
    local defaults = noctalia.json.decode(noctalia.json.encode(DEFAULTS))
    deviceDPIInput = tostring(defaults.device.dpi)
    verticalScrollInput = tostring(defaults.device.verticalScroll)
    horizontalScrollInput = tostring(defaults.device.horizontalScroll)
    return defaults
end

local function app_icon(appId, size)
    local iconSize = size or 40
    local cached = appIconPaths[appId]
    if cached == nil then
        cached = { path = noctalia.appIconPath(appId, 40) }
        appIconPaths[appId] = cached
    end
    if type(cached.path) == "string" then
        return ui.image({
            path = cached.path,
            width = iconSize,
            height = iconSize,
            fit = "contain",
        })
    end
    return ui.glyph({
        name = "window",
        size = iconSize,
        color = "primary",
    })
end

local function parse_action_options(output, sectionName)
    local options = {}
    local inSection = false
    for line in string.gmatch(output .. "\n", "([^\n]*)\n") do
        if line == sectionName .. ":" then
            inSection = true
        elseif inSection then
            local indent = #line - #string.gsub(line, "^ *", "")
            if indent == 2 then
                local name = string.match(line, "^%s+(%S+)")
                if name ~= nil then
                    table.insert(options, name)
                end
            elseif line ~= "" and indent == 0 then
                break
            end
        end
    end
    return options
end

local function parse_media_action_options(output)
    local options = {}
    local actionLine = string.match(output, "[^\n]*<action>[^\n]*one of:[^\n]*")
    local actions = if actionLine ~= nil then string.match(actionLine, "one of:%s*(.-)%s*$") else nil
    if actions ~= nil then
        for action in string.gmatch(actions, "[%w%-]+") do
            table.insert(options, "media " .. action)
        end
    end
    return options
end

local function load_action_options()
    local function load_media_actions()
        local started = noctalia.runAsync({ "noctalia", "msg", "media", "--help" }, function(result)
            if result.timedOut or result.exitCode ~= 0 then
                local detail = result.stderr ~= "" and result.stderr
                    or result.stdout ~= "" and result.stdout
                    or `exit status {result.exitCode}`
                message = `Could not load Noctalia media choices: {detail}`
                render()
                return
            end

            local mediaOptions = parse_media_action_options((result.stdout or "") .. "\n" .. (result.stderr or ""))
            if #mediaOptions == 0 then
                message = "Could not find media actions in Noctalia help."
                render()
                return
            end

            for _, option in ipairs(mediaOptions) do
                table.insert(actionOptions.noctalia, option)
            end
            render()
        end, 10000)
        if not started then
            message = "Could not start Noctalia to load media choices."
            render()
        end
    end

    local function load_one(label, command, section, key, acceptHelpExit)
        local started = noctalia.runAsync(command, function(result)
            local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
            local options = parse_action_options(output, section)
            if result.timedOut
                or (#options == 0)
                or (result.exitCode ~= 0 and not acceptHelpExit)
            then
                local stderr = if type(result.stderr) == "string" then result.stderr else ""
                local stdout = if type(result.stdout) == "string" then result.stdout else ""
                local detail = stderr ~= "" and stderr
                    or stdout ~= "" and stdout
                    or `exit status {result.exitCode}`
                message = `Could not load {label} choices: {detail}`
                render()
                return
            end
            actionOptions[key] = options
            render()
            if key == "noctalia" then
                load_media_actions()
            end
        end, 10000)
        if not started then
            message = `Could not start {label} to load action choices.`
            render()
        end
    end

    load_one("Niri", { "niri", "msg", "action" }, "Actions", "niri", true)
    load_one("Noctalia", { "noctalia", "msg", "--help" }, "Commands", "noctalia", false)
end

local function config_path()
    local configHome = noctalia.getenv("XDG_CONFIG_HOME")
    if type(configHome) ~= "string" or configHome == "" or string.sub(configHome, 1, 1) ~= "/" then
        local home = noctalia.getenv("HOME")
        if type(home) ~= "string" or home == "" then
            return nil
        end
        configHome = home .. "/.config"
    end
    return configHome .. "/mxmouse/config.json"
end

local function check_service()
    serviceEnabled = nil
    render()
    local started = noctalia.runAsync({ "systemctl", "--user", "is-enabled", "nnmxd.service" }, function(result)
        serviceEnabled = not result.timedOut and result.exitCode == 0
        if not serviceEnabled then
            serviceActive = false
            render()
            return
        end
        local activeStarted = noctalia.runAsync({ "systemctl", "--user", "is-active", "nnmxd.service" }, function(activeResult)
            serviceActive = not activeResult.timedOut and activeResult.exitCode == 0
            load_status()
            render()
        end, 3000)
        if not activeStarted then
            serviceActive = false
            message = "Could not start systemctl to check nnmxd service status."
            render()
        end
    end, 3000)
    if not started then
        serviceEnabled = false
        serviceActive = false
        message = "Could not start systemctl to check nnmxd service status."
        render()
    end
end

local function poll_service_status()
    if daemonInstalled ~= true or servicePollInFlight then
        return
    end

    servicePollInFlight = true
    local started = noctalia.runAsync({ "systemctl", "--user", "is-active", "nnmxd.service" }, function(result)
        servicePollInFlight = false
        serviceActive = not result.timedOut and result.exitCode == 0
        load_status()
        render()
    end, 3000)
    if not started then
        servicePollInFlight = false
        message = "Could not start systemctl to refresh nnmxd service status."
        render()
    end
end

local function check_daemon()
    daemonInstalled = nil
    serviceEnabled = nil
    localSourceAvailable = false
    localBuildAvailable = false
    render()
    local home = noctalia.getenv("HOME")
    if type(home) == "string" and home ~= "" then
        local sourcePath = home .. "/.local/src/nnmxd"
        localSourceAvailable = noctalia.fileExists(sourcePath .. "/Makefile")
        localBuildAvailable = noctalia.fileExists(sourcePath .. "/bin/nnmxd")
            and noctalia.fileExists(sourcePath .. "/configs/nnmxd.service")
    end
    local daemonCommand = "nnmxd"
    if type(home) == "string" and home ~= "" and noctalia.fileExists(home .. "/.local/bin/nnmxd") then
        daemonCommand = home .. "/.local/bin/nnmxd"
    end
    local started = noctalia.runAsync({ daemonCommand, "--version" }, function(result)
        daemonInstalled = not result.timedOut and result.exitCode == 0
        if daemonInstalled then
            check_service()
        else
            serviceActive = false
            status = nil
            render()
        end
    end, 3000)
    if not started then
        daemonInstalled = false
        serviceActive = false
        render()
    end
end

local function configure_service()
    if configuringService then
        return
    end
    local home = noctalia.getenv("HOME")
    if type(home) ~= "string" or home == "" then
        message = "Could not resolve HOME; cannot configure nnmxd.service."
        render()
        return
    end

    local sourcePath = home .. "/.local/src/nnmxd"
    local installBuild = localBuildAvailable
    if installBuild and not localBuildAvailable then
        message = "Build nnmxd from the reviewed source first, then check again."
        render()
        return
    end

    configuringService = true
    message = if installBuild then "Installing the locally built daemon and service unit..."
        else "Reloading the user service manager..."
    render()

    local function reload_and_enable()
        message = "Reloading the user service manager..."
        render()
        local reloadStarted = noctalia.runAsync({ "systemctl", "--user", "daemon-reload" }, function(reloadResult)
            if reloadResult.timedOut or reloadResult.exitCode ~= 0 then
                configuringService = false
                local detail = reloadResult.stderr ~= "" and reloadResult.stderr
                    or reloadResult.stdout ~= "" and reloadResult.stdout
                    or `exit status {reloadResult.exitCode}`
                message = `Could not reload the user service manager: {detail}`
                render()
                return
            end

            message = "Enabling and starting nnmxd.service..."
            render()
            local enableStarted = noctalia.runAsync({
                "systemctl", "--user", "enable", "--now", "nnmxd.service",
            }, function(enableResult)
                configuringService = false
                if enableResult.timedOut or enableResult.exitCode ~= 0 then
                    local detail = enableResult.stderr ~= "" and enableResult.stderr
                        or enableResult.stdout ~= "" and enableResult.stdout
                        or `exit status {enableResult.exitCode}`
                    message = `Could not enable and start nnmxd.service: {detail}`
                    render()
                    return
                end
                message = "nnmxd.service is enabled and started."
                check_daemon()
            end, 10000)
            if not enableStarted then
                configuringService = false
                message = "Could not start systemctl to enable nnmxd.service."
                render()
            end
        end, 10000)
        if not reloadStarted then
            configuringService = false
            message = "Could not start systemctl to reload the user service manager."
            render()
        end
    end

    if not installBuild then
        reload_and_enable()
        return
    end

    local binaryStarted = noctalia.runAsync({
        "install", "-Dm0755", sourcePath .. "/bin/nnmxd", home .. "/.local/bin/nnmxd",
    }, function(binaryResult)
        if binaryResult.timedOut or binaryResult.exitCode ~= 0 then
            configuringService = false
            local detail = binaryResult.stderr ~= "" and binaryResult.stderr
                or binaryResult.stdout ~= "" and binaryResult.stdout
                or `exit status {binaryResult.exitCode}`
            message = `Could not install the locally built nnmxd binary: {detail}`
            render()
            return
        end

        local unitStarted = noctalia.runAsync({
            "install", "-Dm0644", sourcePath .. "/configs/nnmxd.service",
            home .. "/.config/systemd/user/nnmxd.service",
        }, function(unitResult)
            if unitResult.timedOut or unitResult.exitCode ~= 0 then
                configuringService = false
                local detail = unitResult.stderr ~= "" and unitResult.stderr
                    or unitResult.stdout ~= "" and unitResult.stdout
                    or `exit status {unitResult.exitCode}`
                message = `Could not install nnmxd.service: {detail}`
                render()
                return
            end
            reload_and_enable()
        end, 10000)
        if not unitStarted then
            configuringService = false
            message = "Could not start install to configure nnmxd.service."
            render()
        end
    end, 10000)
    if not binaryStarted then
        configuringService = false
        message = "Could not start install to configure the nnmxd binary."
        render()
    end
end

local function status_path()
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
    if type(runtimeDir) ~= "string" or runtimeDir == "" then
        return nil
    end
    return runtimeDir .. "/mxmouse/status.json"
end

local function selected_preset()
    for _, preset in ipairs(config.presets) do
        if preset.id == selectedPresetId then
            return preset
        end
    end
    selectedPresetId = config.defaultPresetId
    for _, preset in ipairs(config.presets) do
        if preset.id == selectedPresetId then
            return preset
        end
    end
    return config.presets[1]
end

local function load_config()
    CONFIG_PATH = config_path()
    STATUS_PATH = status_path()
    if CONFIG_PATH == nil then
        message = "Could not resolve the user configuration directory."
        config = default_config()
        return
    end
    if not noctalia.fileExists(CONFIG_PATH) then
        config = default_config()
        return
    end

    local contents, readError = noctalia.readFile(CONFIG_PATH)
    if type(contents) ~= "string" then
        message = `Could not read {CONFIG_PATH}: {tostring(readError)}`
        config = default_config()
        return
    end
    local ok, decoded = pcall(noctalia.json.decode, contents)
    if not ok or type(decoded) ~= "table"
        or type(decoded.presets) ~= "table"
        or #decoded.presets == 0
        or type(decoded.device) ~= "table"
    then
        message = "The service configuration is invalid JSON or has no presets."
        config = default_config()
        return
    end
    decoded.appPresets = if type(decoded.appPresets) == "table" then decoded.appPresets else {}
    decoded.metaStateFile = nil
    decoded.writeWaybar = nil
    for _, preset in ipairs(decoded.presets) do
        if type(preset) ~= "table" or type(preset.id) ~= "string" or type(preset.name) ~= "string" then
            message = "The service configuration contains a malformed preset."
            config = default_config()
            return
        end
        if type(preset.bindings) ~= "table" then
            preset.bindings = {}
        end
        for key in pairs(DEFAULTS.presets[1].bindings) do
            local binding = preset.bindings[key]
            if type(binding) == "string" then
                local actionName, oldArguments = string.match(binding, "^(%S+)%s*(.*)$")
                preset.bindings[key] = {
                    type = "niri",
                    value = actionName or binding,
                    arguments = oldArguments or "",
                }
            elseif type(binding) ~= "table" then
                preset.bindings[key] = { type = "niri", value = "" }
            else
                binding.type = if binding.type == "niri"
                    or binding.type == "noctalia"
                    or binding.type == "command"
                    then binding.type else "niri"
                binding.value = if type(binding.value) == "string" then binding.value else ""
                binding.arguments = if type(binding.arguments) == "string" then binding.arguments else ""
                if binding.type ~= "command" then
                    local actionName, oldArguments = string.match(binding.value, "^(%S+)%s*(.*)$")
                    if actionName ~= nil and oldArguments ~= "" then
                        binding.value = actionName
                        if binding.arguments == "" then
                            binding.arguments = oldArguments
                        end
                    end
                end
            end
        end
        preset.mode = if preset.mode == "meta-toggle" then "meta-toggle" else "gesture"
        preset.glyph = if type(preset.glyph) == "string" and preset.glyph ~= "" then preset.glyph else "arrows-move"
        preset.dpi = if type(preset.dpi) == "number" then preset.dpi else 0
        preset.verticalScroll = if type(preset.verticalScroll) == "number" then preset.verticalScroll else 0
        preset.horizontalScroll = if type(preset.horizontalScroll) == "number" then preset.horizontalScroll else 0
        preset.threshold = if type(preset.threshold) == "number" then preset.threshold else 100
        preset.retriggerDistance = if type(preset.retriggerDistance) == "number" and preset.retriggerDistance > 0
            then preset.retriggerDistance else preset.threshold
        preset.escalation = if type(preset.escalation) == "number" then preset.escalation else 0
        preset.metaKey = if type(preset.metaKey) == "string" then preset.metaKey else "KEY_LEFTMETA"
    end
    if type(decoded.defaultPresetId) ~= "string" then
        decoded.defaultPresetId = decoded.presets[1].id
    end
    if type(decoded.device.autoDetect) ~= "boolean" then
        decoded.device.autoDetect = true
    end
    if type(decoded.device.path) ~= "string" then
        decoded.device.path = ""
    end
    if type(decoded.device.triggerButton) ~= "string" or decoded.device.triggerButton == "" then
        decoded.device.triggerButton = "BTN_FORWARD"
    end
    if type(decoded.device.dpi) ~= "number" then
        decoded.device.dpi = 0
    end
    if type(decoded.device.verticalScroll) ~= "number" then
        decoded.device.verticalScroll = 100
    end
    if type(decoded.device.horizontalScroll) ~= "number" then
        decoded.device.horizontalScroll = 100
    end
    if type(decoded.applyGeneration) ~= "number"
        or decoded.applyGeneration % 1 ~= 0
        or decoded.applyGeneration < 0
    then
        decoded.applyGeneration = 0
    end
    deviceDPIInput = tostring(decoded.device.dpi)
    verticalScrollInput = tostring(decoded.device.verticalScroll)
    horizontalScrollInput = tostring(decoded.device.horizontalScroll)
    config = decoded
    selectedPresetId = config.defaultPresetId or config.presets[1].id
end

local function show_notification(body)
    local notificationArgs = {
        "noctalia",
        "msg",
        "notification-show",
        "MX Mouse",
        body,
    }
    local pluginPath = noctalia.pluginDir()
    if type(pluginPath) == "string" and pluginPath ~= "" then
        local hintPath = pluginPath .. "/thumb-press-hint.png"
        if noctalia.fileExists(hintPath) then
            local payload, encodeError = noctalia.json.encode({
                app_name = "MX Mouse",
                summary = "MX Mouse",
                body = body,
                icon = hintPath,
            })
            if type(payload) == "string" then
                notificationArgs = { "noctalia", "msg", "notification-show", payload }
            else
                noctalia.notifyError("MX Mouse", `Could not encode notification image payload: {tostring(encodeError)}`)
            end
        else
            noctalia.notifyError("MX Mouse", `Could not find thumb-button hint image: {hintPath}`)
        end
    else
        noctalia.notifyError("MX Mouse", `Could not locate plugin directory for thumb-button hint image: {tostring(pluginPath)}`)
    end
    local started = noctalia.runAsync(notificationArgs, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            noctalia.notifyError("MX Mouse", `Could not show notification: {detail}`)
        end
    end, 5000)
    if not started then
        noctalia.notifyError("MX Mouse", "Could not start the notification command.")
    end
end

local function is_niri_focus_error(serviceError)
    return serviceError == "Niri reports no focused window"
end

local function is_dpi_error(serviceError)
    return string.find(string.lower(serviceError), "dpi", 1, true) ~= nil
end

load_status = function()
    status = nil
    if STATUS_PATH == nil or not noctalia.fileExists(STATUS_PATH) then
        return
    end
    local contents, readError = noctalia.readFile(STATUS_PATH)
    if type(contents) ~= "string" then
        message = `Could not read service status: {tostring(readError)}`
        return
    end
    local ok, decoded = pcall(noctalia.json.decode, contents)
    if ok and type(decoded) == "table" then
        status = decoded
        if pendingConfigGeneration == nil
            and type(config) == "table"
            and type(config.applyGeneration) == "number"
            and type(status.appliedGeneration) == "number"
            and config.applyGeneration > status.appliedGeneration
        then
            pendingConfigGeneration = config.applyGeneration
            message = "Configuration saved. Press the thumb button once to apply it; that press will not run its assigned action."
        end
        local justAppliedConfig = pendingConfigGeneration ~= nil
            and type(status.appliedGeneration) == "number"
            and status.appliedGeneration == pendingConfigGeneration
        if justAppliedConfig then
            pendingConfigGeneration = nil
            message = "Configuration applied. The thumb-button press was used to apply it; its assigned action was skipped."
            show_notification(message)
        end
        local serviceError = if type(status.lastError) == "string" then status.lastError else ""
        if serviceError == "" then
            notifiedServiceError = ""
        elseif is_niri_focus_error(serviceError) then
            notifiedServiceError = serviceError
        elseif is_dpi_error(serviceError) then
            if justAppliedConfig and serviceError ~= notifiedServiceError then
                notifiedServiceError = serviceError
                noctalia.notifyError("MX Mouse", serviceError)
            end
        elseif serviceError ~= notifiedServiceError then
            notifiedServiceError = serviceError
            noctalia.notifyError("MX Mouse", serviceError)
        end
    else
        message = "Could not parse mxmouse service status."
    end
end

local function refresh_windows()
    if windowRefreshInFlight then
        return
    end
    windowRefreshInFlight = true
    local started = noctalia.runAsync({ "niri", "msg", "--json", "windows" }, function(result)
        windowRefreshInFlight = false
        local changed = false
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            message = `Could not read Niri windows: {detail}`
            changed = true
        else
            local ok, decoded = pcall(noctalia.json.decode, result.stdout)
            if not ok or type(decoded) ~= "table" then
                message = "Could not parse Niri windows response."
                changed = true
            else
                local signatureRows = {}
                local focusedWindow = nil
                local fallbackWindow = nil
                local fallbackFocusTimestamp = nil
                local previousFocusedID = if lastFocusedWindow ~= nil then lastFocusedWindow.id else nil
                for _, window in ipairs(decoded) do
                    if type(window) == "table" then
                        table.insert(signatureRows, {
                            id = window.id,
                            app_id = window.app_id,
                            title = window.title,
                            is_focused = window.is_focused,
                        })
                        if window.is_focused == true
                            and type(window.app_id) == "string"
                            and window.app_id ~= ""
                        then
                            focusedWindow = window
                        end
                        local timestamp = window.focus_timestamp
                        if type(window.app_id) == "string" and window.app_id ~= ""
                            and type(timestamp) == "table"
                        then
                            local secs = tonumber(timestamp.secs) or 0
                            local nanos = tonumber(timestamp.nanos) or 0
                            if fallbackFocusTimestamp == nil
                                or secs > fallbackFocusTimestamp.secs
                                or (secs == fallbackFocusTimestamp.secs and nanos > fallbackFocusTimestamp.nanos)
                            then
                                fallbackWindow = window
                                fallbackFocusTimestamp = { secs = secs, nanos = nanos }
                            end
                        end
                    end
                end
                local signature = noctalia.json.encode(signatureRows) or ""
                changed = signature ~= windowListSignature
                windowListSignature = signature
                windows = decoded
                focusedWindow = focusedWindow or fallbackWindow
                if focusedWindow ~= nil then
                    lastFocusedWindow = focusedWindow
                    changed = changed or focusedWindow.id ~= previousFocusedID
                end
            end
        end
        load_status()
        if changed then
            render()
        end
    end, 5000)
    if not started then
        windowRefreshInFlight = false
        message = "Could not start Niri to list windows."
        render()
    end
end

local function save_config()
    if saving then
        return
    end
    local dpi = tonumber(deviceDPIInput)
    local verticalScroll = tonumber(verticalScrollInput)
    local horizontalScroll = tonumber(horizontalScrollInput)
    if dpi == nil or dpi % 1 ~= 0 or (dpi ~= 0 and (dpi < 100 or dpi > 16000)) then
        message = "DPI must be 0 (unchanged) or a whole number from 100 to 16000."
        render()
        return
    end
    if verticalScroll == nil or verticalScroll % 1 ~= 0 or verticalScroll < 10 or verticalScroll > 500 then
        message = "Vertical scroll scale must be a whole percentage from 10 to 500."
        render()
        return
    end
    if horizontalScroll == nil or horizontalScroll % 1 ~= 0 or horizontalScroll < 10 or horizontalScroll > 500 then
        message = "Horizontal scroll scale must be a whole percentage from 10 to 500."
        render()
        return
    end
    config.device.dpi = dpi
    config.device.verticalScroll = verticalScroll
    config.device.horizontalScroll = horizontalScroll
    local dataDir, dirError = noctalia.pluginDataDir()
    if type(dataDir) ~= "string" or dataDir == "" then
        message = `Could not locate plugin data directory: {tostring(dirError)}`
        render()
        return
    end
    CANDIDATE_PATH = dataDir .. "/candidate-config.json"
    config.applyGeneration += 1
    local encoded, encodeError = noctalia.json.encode(config, true)
    if type(encoded) ~= "string" then
        message = `Could not encode configuration: {tostring(encodeError)}`
        render()
        return
    end
    local written, writeError = noctalia.writeFile(CANDIDATE_PATH, encoded)
    if not written then
        message = `Could not write temporary configuration: {tostring(writeError)}`
        render()
        return
    end

    saving = true
    pendingConfigGeneration = config.applyGeneration
    message = "Validating and saving configuration..."
    render()
    local serviceCommand = "nnmxd"
    local home = noctalia.getenv("HOME")
    if type(home) == "string" and home ~= "" and noctalia.fileExists(home .. "/.local/bin/nnmxd") then
        serviceCommand = home .. "/.local/bin/nnmxd"
    end
    local started = noctalia.runAsync({ serviceCommand, "--apply-config", CANDIDATE_PATH }, function(result)
        saving = false
        if result.timedOut or result.exitCode ~= 0 then
            pendingConfigGeneration = nil
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            message = `Could not apply configuration: {detail}`
            noctalia.notifyError("MX Mouse", message)
        else
            message = "Configuration saved. Press the thumb button once to apply; that press will not run its assigned action."
            show_notification(message)
        end
        render()
    end, 10000)
    if not started then
        saving = false
        pendingConfigGeneration = nil
        message = "Could not start nnmxd to validate configuration."
        noctalia.notifyError("MX Mouse", message)
        render()
    end
end

local function restart_service(successMessage)
    local started = noctalia.runAsync({ "systemctl", "--user", "restart", "nnmxd.service" }, function(result)
        if result.timedOut or result.exitCode ~= 0 then
            local detail = result.stderr ~= "" and result.stderr
                or result.stdout ~= "" and result.stdout
                or `exit status {result.exitCode}`
            message = `Could not restart nnmxd.service: {detail}`
            noctalia.notifyError("MX Mouse", message)
        else
            message = successMessage or "Restarted nnmxd.service."
        end
        load_status()
        render()
        check_service()
    end, 10000)
    if not started then
        message = "Could not start systemctl to restart the user service."
        render()
    end
end

local function start_log_stream()
    if logStreamStarted then
        return
    end

    logStreamStarted = true
    logStreamError = nil
    local started = noctalia.runStream(
        "journalctl --user --unit=nnmxd.service --lines=100 --follow --no-pager --output=short-iso-precise 2>&1",
        function(line)
            table.insert(logLines, line)
            if #logLines > 250 then
                table.remove(logLines, 1)
            end
            if activePage == "logs" then
                render()
            end
        end
    )
    if not started then
        logStreamStarted = false
        logStreamError = "Could not start the nnmxd journal stream."
        render()
    end
end

local function add_preset()
    nextPresetNumber += 1
    local id = `preset-{tostring(os.time())}-{tostring(nextPresetNumber)}`
    local preset = {
        id = id,
        name = "New preset",
        mode = "gesture",
        glyph = "arrows-move",
        dpi = 0,
        verticalScroll = 0,
        horizontalScroll = 0,
        threshold = 100,
        retriggerDistance = 100,
        escalation = 0,
        metaKey = "KEY_LEFTMETA",
        bindings = {
            left = { type = "niri", value = "focus-column-left" },
            right = { type = "niri", value = "focus-column-right" },
            up = { type = "niri", value = "focus-workspace-up" },
            down = { type = "niri", value = "focus-workspace-down" },
            tap = { type = "niri", value = "toggle-overview" },
            scrollUp = { type = "niri", value = "focus-workspace-up" },
            scrollDown = { type = "niri", value = "focus-workspace-down" },
            thumbwheelLeft = { type = "niri", value = "" },
            thumbwheelRight = { type = "niri", value = "" },
            thumbwheelButtonLeft = { type = "niri", value = "" },
            thumbwheelButtonRight = { type = "niri", value = "" },
            sideBack = { type = "niri", value = "" },
            sideForward = { type = "niri", value = "" },
            thumbLeftClick = { type = "niri", value = "" },
            thumbMiddleClick = { type = "niri", value = "" },
            thumbRightClick = { type = "niri", value = "" },
        },
    }
    table.insert(config.presets, preset)
    selectedPresetId = id
    message = "New preset added. Edit it and save."
    render()
end

local function delete_selected_preset()
    if #config.presets <= 1 then
        message = "Keep at least one preset."
        render()
        return
    end
    local deleting = selected_preset()
    local replacement = config.presets[1]
    for index, preset in ipairs(config.presets) do
        if preset.id == deleting.id then
            replacement = config.presets[index == #config.presets and index - 1 or index + 1]
            table.remove(config.presets, index)
            break
        end
    end
    for appId, presetId in pairs(config.appPresets) do
        if presetId == deleting.id then
            config.appPresets[appId] = nil
        end
    end
    if config.defaultPresetId == deleting.id then
        config.defaultPresetId = replacement.id
    end
    selectedPresetId = replacement.id
    message = `Deleted preset "{deleting.name}". Save to apply.`
    render()
end

local function action_field(preset, entry)
    local key = entry[1]
    local binding = preset.bindings[key]
    local actionTypeNames = {
        { "niri", "Niri" },
        { "noctalia", "Noctalia" },
        { "command", "Command" },
    }
    local choices = actionOptions[binding.type]
    local choiceOptions = { "Choose an action…" }
    if type(choices) == "table" then
        for _, choice in ipairs(choices) do
            table.insert(choiceOptions, choice)
        end
    end
    local choiceIndex = 0
    for choiceIndexInList, choice in ipairs(choices or {}) do
        if choice == binding.value then
            choiceIndex = choiceIndexInList
            break
        end
    end
    local typeTabs = {}
    for _, item in ipairs(actionTypeNames) do
        local actionType = item[1]
        table.insert(typeTabs, ui.button({
            key = `binding-type-{preset.id}-{key}-{actionType}`,
            text = item[2],
            selected = binding.type == actionType,
            onClick = function()
                binding.type = actionType
                binding.value = ""
                binding.arguments = ""
                render()
            end,
        }))
    end
    local fields = {
        ui.label({ text = `{entry[2]} action`, fontWeight = "semibold" }),
        ui.row({ gap = 6 }, typeTabs),
    }
    if string.find(key, "thumbwheel", 1, true) then
        table.insert(fields, ui.label({
            text = "Leave this action unselected to pass horizontal scrolling through unchanged.",
            color = "on_surface_variant",
        }))
    end
    if binding.type ~= "command" then
        table.insert(fields, ui.select({
            key = `binding-choice-{preset.id}-{key}`,
            options = choiceOptions,
            selectedIndex = choiceIndex,
            onChange = function(value)
                local selected = tonumber(value)
                if selected == nil or selected <= 0 or choices == nil or selected > #choices then
                    return
                end
                binding.value = choices[selected]
                render()
            end,
        }))
        table.insert(fields, ui.column({ gap = 3 }, {
            ui.label({ text = "Arguments (optional)", fontWeight = "medium" }),
            ui.label({
                text = "Appended after the action name. Quote arguments that contain spaces.",
                color = "on_surface_variant",
            }),
            ui.input({
                key = `binding-arguments-{preset.id}-{key}`,
                value = binding.arguments or "",
                placeholder = "e.g. 2 or \"ffngs/mxmouse:manager\"",
                flexGrow = 1,
                onChange = function(value)
                    binding.arguments = value
                end,
            }),
        }))
    else
        table.insert(fields, ui.column({ gap = 3 }, {
            ui.label({ text = "Shell command", fontWeight = "medium" }),
            ui.label({
                text = "Runs as your user. Use only commands you trust.",
                color = "on_surface_variant",
            }),
            ui.input({
                key = `binding-{preset.id}-{key}`,
                value = binding.value,
                placeholder = "e.g. notify-send 'Mouse gesture'",
                flexGrow = 1,
                onChange = function(value)
                    binding.value = value
                end,
            }),
        }))
    end
    return ui.column({ gap = 8, padding = 12, fill = "surface_container_high", radius = 12 }, fields)
end

local function preset_editor(preset)
    if profileSectionExpanded[preset.id] == nil then
        profileSectionExpanded[preset.id] = {
            gestures = false,
            thumbChords = false,
            wheelActions = false,
            scrollwheel = false,
            thumbwheel = false,
            sideButtons = false,
            dpiScroll = false,
        }
    end
    local expanded = profileSectionExpanded[preset.id]
    local children = {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = "Profile", fontSize = 16, fontWeight = "bold" }),
                ui.label({
                    text = if config.defaultPresetId == preset.id then "Default profile" else "Custom profile",
                    color = "on_surface_variant",
                }),
            }),
            ui.button({
                text = "Make default",
                glyph = "star",
                selected = config.defaultPresetId == preset.id,
                onClick = function()
                    config.defaultPresetId = preset.id
                    message = `"{preset.name}" is now the fallback preset. Save to apply.`
                    render()
                end,
            }),
            ui.button({
                text = "Delete",
                glyph = "trash",
                variant = "destructive",
                enabled = #config.presets > 1,
                onClick = delete_selected_preset,
            }),
        }),
    }
    table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, {
        ui.row({ align = "center", gap = 6 }, {
            ui.glyph({ name = "user-cog", size = 18, color = "primary" }),
            ui.label({ text = "Profile", fontWeight = "semibold" }),
        }),
        ui.input({
            key = "preset-name-" .. preset.id,
            value = preset.name,
            placeholder = "Profile name",
            onChange = function(value)
                preset.name = value
            end,
        }),
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = preset.glyph, size = 20, color = "primary" }),
            ui.column({ flexGrow = 1, gap = 4 }, {
                ui.label({ text = "Profile glyph" }),
                ui.input({
                    key = "preset-glyph-" .. preset.id,
                    value = preset.glyph,
                    placeholder = "e.g. arrows-move",
                    onChange = function(value)
                        preset.glyph = value
                    end,
                }),
            }),
        }),
        ui.row({ gap = 8 }, {
            ui.button({
                text = "Gesture mode",
                glyph = "arrows-move",
                selected = preset.mode == "gesture",
                onClick = function()
                    preset.mode = "gesture"
                    render()
                end,
            }),
            ui.button({
                text = "Meta toggle",
                glyph = "keyboard",
                selected = preset.mode == "meta-toggle",
                onClick = function()
                    preset.mode = "meta-toggle"
                    render()
                end,
            }),
        }),
    }))

    local sideButtonEntries = {
        { "sideBack", "Back side button (BTN_SIDE)", "arrow-left" },
        { "sideForward", "Front side button (BTN_EXTRA)", "arrow-right" },
    }
    local function side_button_card()
        local sideButtonCard = {
            ui.row({ align = "center", gap = 6 }, {
                ui.glyph({ name = "mouse", size = 18, color = "primary" }),
                ui.button({
                    key = `profile-section-{preset.id}-sideButtons`,
                    text = "Side buttons",
                    glyph = if expanded.sideButtons then "chevron-down" else "chevron-right",
                    variant = "ghost",
                    contentAlign = "start",
                    onClick = function()
                        expanded.sideButtons = not expanded.sideButtons
                        render()
                    end,
                }),
            }),
        }
        if expanded.sideButtons then
            table.insert(sideButtonCard, ui.row({ gap = 8, align = "center", justify = "center" }, {
                ui.button({
                    key = `side-button-{preset.id}-sideBack`,
                    text = "Back",
                    glyph = "arrow-left",
                    selected = selectedSideButtonKey == "sideBack",
                    onClick = function()
                        selectedSideButtonKey = "sideBack"
                        render()
                    end,
                }),
                ui.button({
                    key = `side-button-{preset.id}-sideForward`,
                    text = "Front",
                    glyph = "arrow-right",
                    selected = selectedSideButtonKey == "sideForward",
                    onClick = function()
                        selectedSideButtonKey = "sideForward"
                        render()
                    end,
                }),
            }))
            table.insert(sideButtonCard, ui.label({
                text = "These actions run on press, use the focused app's profile, and work in either profile mode.",
                color = "on_surface_variant",
            }))
            local selectedSideEntry = sideButtonEntries[1]
            if selectedSideButtonKey == "sideForward" then
                selectedSideEntry = sideButtonEntries[2]
            end
            table.insert(sideButtonCard, action_field(preset, selectedSideEntry))
        end
        return ui.column({
            gap = 8, padding = 12, fill = "surface_container", radius = 12,
        }, sideButtonCard)
    end

    if preset.mode == "gesture" then
        local bindingNames = {
            { "left", "Left", "arrow-left" }, { "right", "Right", "arrow-right" },
            { "up", "Up", "arrow-up" }, { "down", "Down", "arrow-down" },
            { "tap", "Tap", "hand-click" }, { "scrollUp", "Scroll up", "arrow-up" },
            { "scrollDown", "Scroll down", "arrow-down" },
            { "thumbwheelLeft", "Left", "arrow-left" },
            { "thumbwheelRight", "Right", "arrow-right" },
            { "thumbwheelButtonLeft", "Left", "arrow-left" },
            { "thumbwheelButtonRight", "Right", "arrow-right" },
            { "thumbLeftClick", "Thumb + Left click", "arrow-left" },
            { "thumbMiddleClick", "Thumb + Middle click", "mouse" },
            { "thumbRightClick", "Thumb + Right click", "arrow-right" },
        }
        local gestureBindings = { bindingNames[1], bindingNames[2], bindingNames[3], bindingNames[4], bindingNames[5] }
        local scrollwheelBindings = { bindingNames[6], bindingNames[7] }
        local thumbwheelBindings = { bindingNames[8], bindingNames[9], bindingNames[10], bindingNames[11] }
        local thumbClickBindings = { bindingNames[12], bindingNames[13], bindingNames[14] }
        local function set_action(entry, section, subgroup)
            selectedActionKey = entry[1]
            if section ~= nil then
                expanded[section] = true
            end
            if subgroup ~= nil then
                expanded[subgroup] = true
            end
            render()
        end
        local function action_tab(entry, section, subgroup, label)
            local key = entry[1]
            return ui.button({
                key = `profile-action-{preset.id}-{key}`,
                text = label or entry[2],
                glyph = entry[3],
                selected = selectedActionKey == key,
                onClick = function()
                    set_action(entry, section, subgroup)
                end,
            })
        end
        local function section_header(title, sectionKey, glyph)
            return ui.row({ align = "center", gap = 6 }, {
                ui.glyph({ name = glyph, size = 18, color = "primary" }),
                ui.button({
                    key = `profile-section-{preset.id}-{sectionKey}`,
                    text = title,
                    glyph = if expanded[sectionKey] then "chevron-down" else "chevron-right",
                    variant = "ghost",
                    contentAlign = "start",
                    onClick = function()
                        expanded[sectionKey] = not expanded[sectionKey]
                        render()
                    end,
                }),
            })
        end
        local gestureControls = {
            ui.row({ gap = 8 }, {
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Initial movement threshold (device counts)" }),
                    ui.input({
                        key = "threshold-" .. preset.id,
                        value = tostring(preset.threshold),
                        onChange = function(value)
                            local number = tonumber(value)
                            if number ~= nil and math.floor(number) == number then
                                preset.threshold = number
                            end
                        end,
                    }),
                }),
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Retrigger distance (device counts)" }),
                    ui.input({
                        key = "retrigger-distance-" .. preset.id,
                        value = tostring(preset.retriggerDistance),
                        onChange = function(value)
                            local number = tonumber(value)
                            if number ~= nil and math.floor(number) == number and number > 0 then
                                preset.retriggerDistance = number
                            end
                        end,
                    }),
                }),
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Escalation per retrigger (device counts)" }),
                    ui.input({
                        key = "escalation-" .. preset.id,
                        value = tostring(preset.escalation),
                        onChange = function(value)
                            local number = tonumber(value)
                            if number ~= nil and math.floor(number) == number and number >= 0 then
                                preset.escalation = number
                            end
                        end,
                    }),
                }),
            }),
            ui.label({
                text = "Threshold triggers the first directional action. Retrigger distance is the movement needed between later actions. Escalation adds to that distance after each retrigger; 0 keeps each retrigger the same distance. Retrigger distance defaults to the threshold.",
                color = "on_surface_variant",
            }),
        }
        local function tabs(entries, section, subgroup, labels)
            local buttons = {}
            for index, entry in ipairs(entries) do
                table.insert(buttons, action_tab(entry, section, subgroup, labels and labels[index]))
            end
            return ui.row({ gap = 6, align = "center", justify = "center" }, buttons)
        end
        local gestureSectionContent = nil
        local thumbChordSectionContent = nil
        if expanded.gestures then
            gestureSectionContent = gestureControls
            table.insert(gestureSectionContent, ui.label({
                text = "Choose a direction or tap to configure its action.",
                color = "on_surface_variant",
            }))
            table.insert(gestureSectionContent, ui.column({ gap = 6, align = "center" }, {
                ui.row({ justify = "center", gap = 6 }, { action_tab(gestureBindings[3], "gestures") }),
                ui.row({ justify = "center", gap = 6 }, {
                    action_tab(gestureBindings[1], "gestures"),
                    action_tab(gestureBindings[2], "gestures"),
                }),
                ui.row({ justify = "center", gap = 6 }, { action_tab(gestureBindings[4], "gestures") }),
            }))
            table.insert(gestureSectionContent, tabs({ gestureBindings[5] }, "gestures"))
        end
        if expanded.thumbChords then
            thumbChordSectionContent = {
                ui.label({
                    text = "Assigned actions replace the click while holding the thumb button. Unassigned clicks pass through normally.",
                    color = "on_surface_variant",
                }),
                tabs(thumbClickBindings, "thumbChords", nil, { "Left click", "Middle click", "Right click" }),
            }
        end
        local wheelSectionContent = nil
        local scrollwheelContent = nil
        local thumbwheelContent = nil
        if expanded.wheelActions then
            wheelSectionContent = {}
            scrollwheelContent = {
                section_header("Scrollwheel", "scrollwheel", "arrows-up-down"),
            }
            if expanded.scrollwheel then
                table.insert(scrollwheelContent, ui.label({
                    text = "Actions run only while holding the thumb button and turning the vertical scrollwheel.",
                    color = "on_surface_variant",
                }))
                table.insert(scrollwheelContent, tabs(scrollwheelBindings, "wheelActions", "scrollwheel"))
            end
            thumbwheelContent = {
                section_header("Thumbwheel", "thumbwheel", "arrow-left-right"),
            }
            if expanded.thumbwheel then
                table.insert(thumbwheelContent, ui.label({
                    text = "Unassigned directions preserve horizontal scrolling.",
                    color = "on_surface_variant",
                }))
                table.insert(thumbwheelContent, ui.label({ text = "Without holding the thumb button", fontWeight = "medium" }))
                table.insert(thumbwheelContent, tabs({ thumbwheelBindings[1], thumbwheelBindings[2] }, "wheelActions", "thumbwheel"))
                table.insert(thumbwheelContent, ui.label({ text = "While holding the thumb button", fontWeight = "medium" }))
                table.insert(thumbwheelContent, tabs({ thumbwheelBindings[3], thumbwheelBindings[4] }, "wheelActions", "thumbwheel"))
            end
        end

        local selectedEntry = nil
        for _, entry in ipairs(bindingNames) do
            if entry[1] == selectedActionKey then
                selectedEntry = entry
                break
            end
        end
        selectedEntry = selectedEntry or bindingNames[1]
        selectedActionKey = selectedEntry[1]

        local function gesture_field(entry)
            return action_field(preset, entry)
        end
        local selectedKey = selectedEntry[1]
        local selectedIsGesture = selectedKey == "left" or selectedKey == "right"
            or selectedKey == "up" or selectedKey == "down" or selectedKey == "tap"
        local selectedIsThumbClick = selectedKey == "thumbLeftClick"
            or selectedKey == "thumbMiddleClick" or selectedKey == "thumbRightClick"
        local selectedIsScrollwheel = selectedKey == "scrollUp" or selectedKey == "scrollDown"
        if (selectedIsGesture and expanded.gestures)
            or (selectedIsThumbClick and expanded.thumbChords)
            or (selectedIsScrollwheel and expanded.wheelActions and expanded.scrollwheel)
            or (string.find(selectedKey, "thumbwheel", 1, true) ~= nil
                and expanded.wheelActions and expanded.thumbwheel)
        then
            if selectedIsGesture then
                table.insert(gestureSectionContent, gesture_field(selectedEntry))
            elseif selectedIsThumbClick then
                table.insert(thumbChordSectionContent, gesture_field(selectedEntry))
            elseif selectedIsScrollwheel then
                table.insert(scrollwheelContent, gesture_field(selectedEntry))
            else
                table.insert(thumbwheelContent, gesture_field(selectedEntry))
            end
        end
        if wheelSectionContent ~= nil then
            table.insert(wheelSectionContent, ui.column({
                gap = 8, padding = 10, fill = "surface_container_high", radius = 10,
            }, scrollwheelContent))
            table.insert(wheelSectionContent, ui.column({
                gap = 8, padding = 10, fill = "surface_container_high", radius = 10,
            }, thumbwheelContent))
        end
        if gestureSectionContent ~= nil then
            local gestureCard = { section_header("Gestures", "gestures", "arrows-move") }
            for _, child in ipairs(gestureSectionContent) do
                table.insert(gestureCard, child)
            end
            table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, gestureCard))
        else
            table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, {
                section_header("Gestures", "gestures", "arrows-move"),
            }))
        end

        if thumbChordSectionContent ~= nil then
            local thumbChordCard = { section_header("Thumb Chords", "thumbChords", "mouse") }
            for _, child in ipairs(thumbChordSectionContent) do
                table.insert(thumbChordCard, child)
            end
            table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, thumbChordCard))
        else
            table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, {
                section_header("Thumb Chords", "thumbChords", "mouse"),
            }))
        end

        table.insert(children, side_button_card())

        if wheelSectionContent ~= nil then
            local wheelCard = { section_header("Wheel actions", "wheelActions", "mouse") }
            for _, child in ipairs(wheelSectionContent) do
                table.insert(wheelCard, child)
            end
            table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, wheelCard))
        else
            table.insert(children, ui.column({ gap = 8, padding = 12, fill = "surface_container", radius = 12 }, {
                section_header("Wheel actions", "wheelActions", "mouse"),
            }))
        end
    else
        local keys = {
            "KEY_LEFTMETA", "KEY_RIGHTMETA", "KEY_LEFTCTRL", "KEY_RIGHTCTRL",
            "KEY_LEFTALT", "KEY_RIGHTALT", "KEY_LEFTSHIFT", "KEY_RIGHTSHIFT",
        }
        local index = 1
        for i, key in ipairs(keys) do
            if key == preset.metaKey then
                index = i
                break
            end
        end
        table.insert(children, ui.label({ text = "Modifier key injected on each press" }))
        table.insert(children, ui.button({
            text = `Key: {preset.metaKey}`,
            onClick = function()
                preset.metaKey = keys[index % #keys + 1]
                render()
            end,
        }))
        table.insert(children, side_button_card())
    end

    local dpiScrollCard = {
        ui.row({ align = "center", gap = 6 }, {
            ui.glyph({ name = "adjustments", size = 18, color = "primary" }),
            ui.button({
                key = `profile-section-{preset.id}-dpiScroll`,
                text = "DPI and Scroll speed",
                glyph = if expanded.dpiScroll then "chevron-down" else "chevron-right",
                variant = "ghost",
                contentAlign = "start",
                onClick = function()
                    expanded.dpiScroll = not expanded.dpiScroll
                    render()
                end,
            }),
        }),
    }
    if expanded.dpiScroll then
        table.insert(dpiScrollCard, ui.column({ gap = 8 }, {
            ui.label({
                text = "Profile values apply when this profile is focused. A value of 0 uses the matching setting from the Device page.",
                color = "on_surface_variant",
            }),
            ui.row({ gap = 12 }, {
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "DPI (0 = device setting)" }),
                    ui.input({
                        key = "profile-dpi-" .. preset.id,
                        value = tostring(preset.dpi or 0),
                        placeholder = "0",
                        onChange = function(value)
                            local number = tonumber(value)
                            if number ~= nil and math.floor(number) == number and number >= 0 then
                                preset.dpi = number
                            end
                        end,
                    }),
                }),
            }),
            ui.row({ gap = 12 }, {
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Vertical scroll (%)" }),
                    ui.input({
                        key = "profile-vertical-scroll-" .. preset.id,
                        value = tostring(preset.verticalScroll or 0),
                        placeholder = "0",
                        onChange = function(value)
                            local number = tonumber(value)
                            if number ~= nil and math.floor(number) == number and number >= 0 then
                                preset.verticalScroll = number
                            end
                        end,
                    }),
                }),
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Horizontal scroll (%)" }),
                    ui.input({
                        key = "profile-horizontal-scroll-" .. preset.id,
                        value = tostring(preset.horizontalScroll or 0),
                        placeholder = "0",
                        onChange = function(value)
                            local number = tonumber(value)
                            if number ~= nil and math.floor(number) == number and number >= 0 then
                                preset.horizontalScroll = number
                            end
                        end,
                    }),
                }),
            }),
            ui.label({
                text = "DPI must be supported by the mouse (100–16000). Scroll multipliers range from 10% to 500%; 0 inherits the Device setting.",
                color = "on_surface_variant",
            }),
        }))
    end
    table.insert(children, ui.column({
        gap = 8, padding = 12, fill = "surface_container", radius = 12,
    }, dpiScrollCard))

    return ui.column({ gap = 10 }, children)
end

local function button_rows(buttons, buttonsPerRow)
    local rows = {}
    for start = 1, #buttons, buttonsPerRow do
        local row = {}
        for index = start, math.min(start + buttonsPerRow - 1, #buttons) do
            table.insert(row, buttons[index])
        end
        table.insert(rows, ui.row({ gap = 8 }, row))
    end
    return rows
end

render = function()
    if config == nil then
        load_config()
    end
    if daemonInstalled ~= true or serviceEnabled ~= true then
        local setupContent = {
            ui.row({ align = "center", gap = 10 }, {
                ui.label({ text = "MX", fontSize = 22, fontWeight = "bold", color = "primary" }),
                ui.column({ flexGrow = 1, gap = 2 }, {
                    ui.label({ text = "MX Mouse", fontSize = 22, fontWeight = "bold" }),
                    ui.label({ text = "Niri controls for your MX Master", color = "on_surface_variant" }),
                }),
            }),
        }
        local setupStatus = if daemonInstalled == nil
            then "Looking for nnmxd..."
            elseif daemonInstalled == true and serviceEnabled == nil
            then "Checking the nnmxd user service..."
            elseif daemonInstalled == true
            then "The daemon is installed, but its user service is not enabled."
            elseif localBuildAvailable
            then "Local nnmxd build found; configure the user service."
            else "Install nnmxd manually to start configuring your mouse."
        table.insert(setupContent, ui.column({ gap = 8, padding = 18, fill = "surface_container", radius = 16 }, {
            ui.label({ text = setupStatus, fontSize = 17, fontWeight = "bold" }),
            ui.label({
                text = if daemonInstalled == false and not localBuildAvailable and localSourceAvailable
                    then "The nnmxd source is present. Review it and run its Makefile yourself. Afterward, this panel can install the local build and configure the service. The build requires Make, Go, and input-device permissions."
                    else if daemonInstalled == false and not localBuildAvailable
                    then "Review the nnmxd source, clone it, and run its Makefile yourself. Afterward, this panel can install the local build and configure the service. The build requires Git, Make, Go, and input-device permissions."
                    else if localBuildAvailable
                    then "The panel can install your local build and service unit, then reload the user service manager and enable and start nnmxd.service. No elevated privileges are used."
                    else "The panel can reload the user service manager and enable and start nnmxd.service. No elevated privileges are used.",
                color = "on_surface_variant",
                maxLines = 5,
            }),
        }))
        if daemonInstalled == false and not localBuildAvailable then
            table.insert(setupContent, ui.column({ gap = 6, padding = 12, fill = "surface_container_high", radius = 12 }, {
                ui.label({
                    text = if localSourceAvailable then "Build the reviewed local source in a terminal:"
                        else "Clone and build nnmxd in a terminal. Skip the clone command if you already have this checkout:",
                    fontWeight = "semibold",
                }),
                ui.label({
                    text = if localSourceAvailable
                        then "make -C ~/.local/src/nnmxd build"
                        else "mkdir -p ~/.local/src\ngit clone https://github.com/uheplm/nnmxd.git ~/.local/src/nnmxd\nmake -C ~/.local/src/nnmxd build",
                    fontFamily = "monospace",
                    color = "on_surface_variant",
                }),
            }))
        end
        if daemonInstalled == false or serviceEnabled == false then
            local setupButtons = {}
            if localBuildAvailable or (daemonInstalled == true and serviceEnabled == false) then
                table.insert(setupButtons, ui.button({
                    text = if configuringService then "Configuring service..." else "Configure service",
                    glyph = if configuringService then "loader" else "play",
                    enabled = not configuringService,
                    variant = "primary",
                    onClick = configure_service,
                }))
            end
            table.insert(setupButtons, ui.button({
                text = "Check again",
                glyph = "refresh",
                enabled = not configuringService,
                onClick = check_daemon,
            }))
            table.insert(setupContent, ui.row({ gap = 8 }, setupButtons))
        end
        if message ~= "" then
            table.insert(setupContent, ui.label({ text = message, color = "on_surface_variant" }))
        end
        panel.render(ui.column({ flexGrow = 1, gap = 14, padding = 18 }, setupContent))
        return
    end

    local preset = selected_preset()
    local noMouseDetected = serviceActive == true
        and status ~= nil
        and status.running ~= true
        and type(status.lastError) == "string"
        and string.find(string.lower(status.lastError), "no logitech mouse", 1, true) ~= nil
    local deviceName = if noMouseDetected then "No compatible MX mouse connected"
        else if status ~= nil and type(status.device) == "string" and status.device ~= ""
            then status.device else "MX Master"
    local serviceSummary = "Service unavailable"
    local serviceGlyph = "circle-x"
    local serviceColor = "error"
    if serviceActive == true and status ~= nil and status.running == true then
        serviceSummary = "Connected"
        serviceGlyph = "circle-check"
        serviceColor = "primary"
    elseif noMouseDetected then
        serviceSummary = "No MX mouse connected"
    elseif serviceActive == true then
        serviceSummary = "Waiting for device"
        serviceGlyph = "loader"
        serviceColor = "primary"
    end

    local navItems = {
        { "overview", "Overview", "layout-dashboard" },
        { "gestures", "Profiles", "arrows-move" },
        { "apps", "Applications", "apps" },
        { "device", "Device", "settings" },
        { "logs", "Logs", "terminal-2" },
    }
    local navigation = {}
    for _, item in ipairs(navItems) do
        local page = item[1]
        table.insert(navigation, ui.button({
            key = "page-" .. page,
            text = item[2],
            glyph = item[3],
            selected = activePage == page,
            onClick = function()
                activePage = page
                if page == "logs" then
                    start_log_stream()
                end
                render()
            end,
        }))
    end

    local pageContent = {}
    if activePage == "overview" then
        local focusedAppContent
        if lastFocusedWindow ~= nil and type(lastFocusedWindow.app_id) == "string" then
            local appId = lastFocusedWindow.app_id
            local activePresetId = config.appPresets[appId] or config.defaultPresetId
            local activePreset = config.presets[1]
            for _, item in ipairs(config.presets) do
                if item.id == activePresetId then
                    activePreset = item
                    break
                end
            end
            focusedAppContent = ui.row({ align = "center", gap = 5 }, {
                ui.glyph({ name = activePreset.glyph or "arrows-move", size = 16, color = "primary" }),
                ui.label({ text = `Active profile: {activePreset.name} ·`, color = "on_surface_variant", maxLines = 1 }),
                app_icon(appId, 18),
                ui.label({ text = appId, color = "on_surface_variant", maxLines = 1 }),
            })
        else
            focusedAppContent = ui.label({
                text = `Default profile: {preset.name}`,
                color = "on_surface_variant",
                maxLines = 2,
            })
        end
        local hero = ui.column({ flexGrow = 1, gap = 10, padding = 18, fill = "surface_container", radius = 16 }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.glyph({ name = serviceGlyph, size = 18, color = serviceColor }),
                ui.label({ text = serviceSummary, color = serviceColor, fontWeight = "semibold" }),
            }),
            ui.label({ text = deviceName, fontSize = 18, fontWeight = "bold", maxLines = 1 }),
            focusedAppContent,
            ui.row({ gap = 8 }, {
                ui.button({ text = "Refresh windows", glyph = "refresh", onClick = refresh_windows }),
                ui.button({
                    text = "Restart service",
                    glyph = "refresh",
                    enabled = not noMouseDetected,
                    onClick = restart_service,
                }),
            }),
        })
        table.insert(pageContent, hero)

        local function open_profile_control(section, actionKey, subgroup, sideButtonKey)
            local profileId = config.defaultPresetId
            if lastFocusedWindow ~= nil and type(lastFocusedWindow.app_id) == "string" then
                profileId = config.appPresets[lastFocusedWindow.app_id] or config.defaultPresetId
            end
            selectedPresetId = profileId
            local expanded = profileSectionExpanded[profileId]
            if expanded == nil then
                expanded = {
                    gestures = false,
                    thumbChords = false,
                    wheelActions = false,
                    scrollwheel = false,
                    thumbwheel = false,
                    sideButtons = false,
                    dpiScroll = false,
                }
                profileSectionExpanded[profileId] = expanded
            end
            if section ~= nil then
                expanded[section] = true
            end
            if subgroup ~= nil then
                expanded[subgroup] = true
            end
            if actionKey ~= nil then
                selectedActionKey = actionKey
            end
            if sideButtonKey ~= nil then
                selectedSideButtonKey = sideButtonKey
            end
            activePage = "gestures"
            render()
        end

        local controls = {
            {
                title = "Thumb Chords",
                glyph = "mouse",
                onClick = function()
                    open_profile_control("thumbChords", "thumbLeftClick")
                end,
            },
            {
                title = "Scrollwheel (hold thumb)",
                glyph = "arrows-up-down",
                onClick = function()
                    open_profile_control("wheelActions", "scrollUp", "scrollwheel")
                end,
            },
            {
                title = "Front side button",
                glyph = "arrow-right",
                onClick = function()
                    open_profile_control("sideButtons", nil, nil, "sideForward")
                end,
            },
            {
                title = "Back side button",
                glyph = "arrow-left",
                onClick = function()
                    open_profile_control("sideButtons", nil, nil, "sideBack")
                end,
            },
            {
                title = "Thumbwheel",
                glyph = "arrow-left-right",
                onClick = function()
                    open_profile_control("wheelActions", "thumbwheelLeft", "thumbwheel")
                end,
            },
            {
                title = "Thumb button (tap)",
                glyph = "hand-click",
                onClick = function()
                    open_profile_control("gestures", "tap")
                end,
            },
        }
        local controlButtons = {}
        for _, control in ipairs(controls) do
            table.insert(controlButtons, ui.button({
                key = `overview-control-{control.title}`,
                text = control.title,
                glyph = control.glyph,
                onClick = control.onClick,
            }))
        end
        table.insert(controlButtons, ui.button({
            key = "overview-control-gestures",
            text = "Gestures",
            glyph = "arrows-move",
            onClick = function()
                open_profile_control("gestures", "left")
            end,
        }))
        local pluginPath = noctalia.pluginDir()
        local mouseIllustration = ui.glyph({ name = "mouse", size = 96, color = "primary" })
        if type(pluginPath) == "string" and pluginPath ~= ""
            and noctalia.fileExists(pluginPath .. "/mx-master-map.png")
        then
            mouseIllustration = ui.image({
                path = pluginPath .. "/mx-master-map.png",
                width = 350,
                height = 456,
                fit = "contain",
            })
        end
        table.insert(pageContent, ui.row({
            align = "center",
            gap = 0,
            padding = 16,
            fill = "surface_container",
            radius = 14,
        }, {
            mouseIllustration,
            ui.column({ flexGrow = 1, gap = 4 }, {
                ui.label({ text = "Mouse controls", fontSize = 16, fontWeight = "bold" }),
                ui.column({ gap = 20 }, controlButtons),
            }),
        }))

        local profileButtons = {}
        for _, item in ipairs(config.presets) do
            local profileId = item.id
            table.insert(profileButtons, ui.button({
                key = "overview-profile-" .. profileId,
                text = item.name,
                glyph = item.glyph or (if item.mode == "gesture" then "arrows-move" else "keyboard"),
                selected = selectedPresetId == profileId,
                onClick = function()
                    selectedPresetId = profileId
                    activePage = "gestures"
                    render()
                end,
            }))
        end
        table.insert(profileButtons, ui.button({
            text = "New profile",
            glyph = "plus",
            onClick = function()
                add_preset()
                activePage = "gestures"
                render()
            end,
        }))
        local profileCardChildren = {
            ui.row({ align = "center", justify = "space_between" }, {
                ui.column({ flexGrow = 1, gap = 2 }, {
                    ui.label({ text = "Profiles", fontSize = 16, fontWeight = "bold" }),
                    ui.label({ text = "Choose how the thumb button behaves.", color = "on_surface_variant" }),
                }),
                ui.button({
                    text = "Manage",
                    glyph = "arrow-right",
                    onClick = function()
                        activePage = "gestures"
                        render()
                    end,
                }),
            }),
        }
        for _, row in ipairs(button_rows(profileButtons, 3)) do
            table.insert(profileCardChildren, row)
        end
        table.insert(pageContent, ui.column({ gap = 10, padding = 16, fill = "surface_container", radius = 14 }, profileCardChildren))

        local appCount = 0
        local seenApps = {}
        for _, window in ipairs(windows) do
            if type(window) == "table" and type(window.app_id) == "string" and window.app_id ~= ""
                and not seenApps[window.app_id]
            then
                appCount += 1
                seenApps[window.app_id] = true
            end
        end
        table.insert(pageContent, ui.row({
            align = "center",
            justify = "space_between",
            gap = 12,
            padding = 14,
            fill = "surface_container",
            radius = 14,
        }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = "App-specific behavior", fontWeight = "bold" }),
                ui.label({
                    text = if appCount == 0 then "Assign profiles to individual Niri apps." else `{appCount} apps detected · profiles match exact app ID`,
                    color = "on_surface_variant",
                }),
            }),
            ui.button({
                text = "Configure",
                glyph = "arrow-right",
                onClick = function()
                    activePage = "apps"
                    refresh_windows()
                    render()
                end,
            }),
        }))
    elseif activePage == "gestures" then
        local profileButtons = {}
        for _, item in ipairs(config.presets) do
            local profileId = item.id
            table.insert(profileButtons, ui.button({
                key = "gesture-profile-" .. profileId,
                text = item.name,
                glyph = item.glyph or (if item.mode == "gesture" then "arrows-move" else "keyboard"),
                selected = selectedPresetId == profileId,
                onClick = function()
                    selectedPresetId = profileId
                    render()
                end,
            }))
        end
        table.insert(profileButtons, ui.button({
            text = "Add profile",
            glyph = "plus",
            onClick = add_preset,
        }))
        local profileCardChildren = {
            ui.label({ text = "Profiles", fontSize = 16, fontWeight = "bold" }),
        }
        for _, row in ipairs(button_rows(profileButtons, 3)) do
            table.insert(profileCardChildren, row)
        end
        table.insert(pageContent, ui.column({ gap = 10, padding = 14, fill = "surface_container", radius = 14 }, profileCardChildren))
        table.insert(pageContent, preset_editor(preset))
    elseif activePage == "apps" then
        local appRows = {}
        local seenApps = {}
        for _, window in ipairs(windows) do
            if type(window) == "table" and type(window.app_id) == "string" and window.app_id ~= ""
                and not seenApps[window.app_id]
            then
                seenApps[window.app_id] = true
                local appId = window.app_id
                local currentID = config.appPresets[appId]
                local title = type(window.title) == "string" and window.title or "Window"
                local presetOptions = { "Default profile" }
                local selectedIndex = 0
                for profileIndex, item in ipairs(config.presets) do
                    table.insert(presetOptions, item.name)
                    if item.id == currentID then
                        selectedIndex = profileIndex
                    end
                end
                table.insert(appRows, ui.row({
                    key = "app-" .. appId,
                    align = "center",
                    gap = 12,
                    padding = 12,
                    fill = "surface_container",
                    radius = 12,
                }, {
                    app_icon(appId),
                    ui.column({ flexGrow = 1, gap = 3 }, {
                        ui.label({ text = appId, fontWeight = "semibold", maxLines = 1 }),
                        ui.label({ text = title, color = "on_surface_variant", maxLines = 1 }),
                    }),
                    ui.select({
                        options = presetOptions,
                        selectedIndex = selectedIndex,
                        width = 168,
                        onChange = function(value)
                            local selected = tonumber(value)
                            if selected == nil or selected < 0 or selected > #config.presets then
                                message = `Could not select a profile for {appId}.`
                                render()
                                return
                            end
                            config.appPresets[appId] = if selected == 0
                                then nil
                                else config.presets[selected].id
                            message = `Profile for {appId} changed. Save to apply.`
                            render()
                        end,
                    }),
                }))
            end
        end
        if #appRows == 0 then
            table.insert(appRows, ui.column({ gap = 8, padding = 18, fill = "surface_container", radius = 14 }, {
                ui.label({ text = "No windows found", fontSize = 16, fontWeight = "bold" }),
                ui.label({
                    text = "Open a few Niri windows, then refresh to assign profiles by app ID.",
                    color = "on_surface_variant",
                }),
            }))
        end
        table.insert(pageContent, ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = "Application profiles", fontSize = 16, fontWeight = "bold" }),
                ui.label({ text = "Each app uses its assigned profile or the default.", color = "on_surface_variant" }),
            }),
            ui.button({ text = "Refresh", glyph = "refresh", onClick = refresh_windows }),
        }))
        for _, row in ipairs(appRows) do
            table.insert(pageContent, row)
        end
    elseif activePage == "device" then
        table.insert(pageContent, ui.column({ gap = 12, padding = 16, fill = "surface_container", radius = 14 }, {
            ui.column({ gap = 3 }, {
                ui.label({ text = "Input device", fontSize = 16, fontWeight = "bold" }),
                ui.label({ text = "Choose how nnmxd connects to your mouse.", color = "on_surface_variant" }),
            }),
            ui.row({ align = "center", gap = 8 }, {
                ui.button({
                    text = if config.device.autoDetect then "Automatic detection" else "Manual device",
                    glyph = "mouse",
                    selected = config.device.autoDetect,
                    onClick = function()
                        config.device.autoDetect = not config.device.autoDetect
                        render()
                    end,
                }),
                ui.label({
                    text = if config.device.autoDetect then "Logitech device detected automatically" else "Using a specific event device",
                    color = "on_surface_variant",
                }),
            }),
            ui.column({ gap = 4 }, {
                ui.label({ text = "Device path", fontWeight = "medium" }),
                ui.input({
                    key = "device-path",
                    value = config.device.path or "",
                    placeholder = "/dev/input/eventN",
                    onChange = function(value)
                        config.device.path = value
                    end,
                }),
                ui.label({ text = "Leave empty to use automatic device discovery.", color = "on_surface_variant" }),
            }),
            ui.column({ gap = 4 }, {
                ui.row({ align = "center", gap = 6 }, {
                    ui.glyph({ name = "focus", size = 16, color = "on_surface_variant" }),
                    ui.label({ text = "Thumb button", fontWeight = "medium" }),
                }),
                ui.input({
                    key = "trigger-button",
                    value = config.device.triggerButton,
                    placeholder = "BTN_FORWARD",
                    onChange = function(value)
                        config.device.triggerButton = value
                    end,
                }),
                ui.label({ text = "BTN_FORWARD is the usual thumb button. Save settings, then press it once to apply; that press will not trigger its assigned action. Redetect manually restarts nnmxd.", color = "on_surface_variant" }),
            }),
            ui.column({ gap = 4 }, {
                ui.label({ text = "DPI", fontWeight = "medium" }),
                ui.input({
                    key = "device-dpi",
                    value = deviceDPIInput,
                    placeholder = "0",
                    onChange = function(value)
                        deviceDPIInput = value
                    end,
                }),
                ui.label({ text = "0 leaves the current hardware setting unchanged. Enter a DPI supported by the mouse; it is set when nnmxd starts or on the next thumb-button press.", color = "on_surface_variant" }),
            }),
            ui.row({ gap = 12 }, {
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Vertical scroll (%)", fontWeight = "medium" }),
                    ui.input({
                        key = "vertical-scroll",
                        value = verticalScrollInput,
                        placeholder = "100",
                        onChange = function(value)
                            verticalScrollInput = value
                        end,
                    }),
                }),
                ui.column({ flexGrow = 1, gap = 4 }, {
                    ui.label({ text = "Horizontal scroll (%)", fontWeight = "medium" }),
                    ui.input({
                        key = "horizontal-scroll",
                        value = horizontalScrollInput,
                        placeholder = "100",
                        onChange = function(value)
                            horizontalScrollInput = value
                        end,
                    }),
                }),
            }),
            ui.label({ text = "Scroll scales range from 10% to 500%. Standard and high-resolution wheel events are scaled on their matching axis.", color = "on_surface_variant" }),
        }))

        table.insert(pageContent, ui.row({
            align = "center",
            justify = "space_between",
            gap = 8,
            padding = 14,
            fill = "surface_container",
            radius = 14,
        }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = "nnmxd service", fontWeight = "semibold" }),
                ui.label({ text = serviceSummary, color = serviceColor }),
            }),
            ui.button({
                text = if noMouseDetected then "Retry detection" else "Redetect",
                glyph = "refresh",
                onClick = function()
                    restart_service(if noMouseDetected then "Retried MX mouse detection." else "Redetected input device.")
                end,
            }),
        }))
    else
        table.insert(pageContent, ui.row({
            align = "center",
            justify = "space_between",
            gap = 8,
            padding = 14,
            fill = "surface_container",
            radius = 14,
        }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = "nnmxd live logs", fontSize = 16, fontWeight = "bold" }),
                ui.label({
                    text = if logStreamError ~= nil then logStreamError
                        else if logStreamStarted then "Following the user journal · newest entries appear first"
                        else "Starting journal stream…",
                    color = if logStreamError ~= nil then "error" else "on_surface_variant",
                }),
            }),
        }))

        if #logLines == 0 then
            table.insert(pageContent, ui.column({ gap = 8, padding = 18, fill = "surface_container", radius = 14 }, {
                ui.label({ text = "Waiting for nnmxd output", fontWeight = "semibold" }),
                ui.label({
                    text = "Journal entries from nnmxd.service will appear here as they are written.",
                    color = "on_surface_variant",
                }),
            }))
        else
            local renderedLines = {}
            for index = #logLines, 1, -1 do
                table.insert(renderedLines, ui.label({
                    key = `log-line-{index}-{logLines[index]}`,
                    text = logLines[index],
                    color = "on_surface",
                    fontFamily = "monospace",
                    maxLines = 4,
                }))
            end
            table.insert(pageContent, ui.scroll({ flexGrow = 1, gap = 4, padding = 12, fill = "surface_container", radius = 14 }, renderedLines))
        end
    end

    local niriFocusError = if status ~= nil and type(status.lastError) == "string"
        and is_niri_focus_error(status.lastError)
        then status.lastError else ""
    local footerChildren = {
        ui.label({
            text = if niriFocusError ~= "" then niriFocusError
                else if message ~= "" then message else "Apply changes to update nnmxd.",
            color = if niriFocusError ~= "" or string.find(message, "Could not") or string.find(message, "failed")
                then "error" else "on_surface_variant",
            flexGrow = 1,
            maxLines = 2,
        }),
    }
    table.insert(footerChildren, ui.button({
        text = if saving then "Saving..." else "Save changes",
        glyph = "device-floppy",
        enabled = not saving,
        variant = "primary",
        onClick = save_config,
    }))

    local content = {
        ui.row({ align = "center", gap = 10 }, {
            ui.label({ text = "MX", fontSize = 22, fontWeight = "bold", color = "primary" }),
            ui.column({ flexGrow = 1, gap = 1 }, {
                ui.label({ text = "MX Mouse", fontSize = 22, fontWeight = "bold" }),
                ui.label({ text = "Niri controls for your MX Master", color = "on_surface_variant" }),
            }),
            ui.row({ align = "center", gap = 6, padding = 8, fill = "surface_container", radius = 20 }, {
                ui.glyph({ name = serviceGlyph, size = 16, color = serviceColor }),
                ui.label({ text = serviceSummary, color = serviceColor, fontWeight = "medium" }),
            }),
        }),
        ui.row({ gap = 6 }, navigation),
        ui.scroll({ flexGrow = 1, gap = 12 }, pageContent),
        ui.row({ align = "center", gap = 10, padding = 8, fill = "surface_container", radius = 12 }, footerChildren),
    }
    panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 14 }, content))
end

function onOpen(_context)
    message = ""
    panel.setWantsSecondTicks(true)
    load_config()
    load_status()
    if activePage == "logs" then
        start_log_stream()
    end
    render()
    load_action_options()
    check_daemon()
    refresh_windows()
end

function update()
    poll_service_status()
    refresh_windows()
end

function onClose()
end

function onKey(chord, pressed)
    if chord == "Escape" and pressed == "true" then
        panel.close()
    end
end
