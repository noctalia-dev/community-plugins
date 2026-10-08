--!nonstrict
local common = require("./common.luau")

local function get_batteries(): { string }
    local configured = noctalia.getConfig(common.CONFIG.BATTERY_DEVICE)

    if typeof(configured) == "table" then
        local valid = {}
        for _, device in ipairs(configured) do
            if
                typeof(device) == "string"
                and device ~= ""
                and noctalia.fileExists(device .. common.BATTERY_FILES.THRESHOLD)
            then
                table.insert(valid, device)
            end
        end
        if #valid > 0 then
            return valid
        end
    end

    local batteries = {}
    local files, _ = noctalia.listDir("/sys/class/power_supply")

    if files then
        for _, name in files do
            local path = "/sys/class/power_supply/" .. name
            if noctalia.fileExists(path .. common.BATTERY_FILES.THRESHOLD) then
                table.insert(batteries, path)
            end
        end
    end

    table.sort(batteries)
    return batteries
end

local function shell_quote(str: string): string
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local function read_trimmed(path: string): string?
    local content, err = noctalia.readFile(path)
    if content and not err then
        return noctalia.string.trim(content)
    end
    return nil
end

local function check_writable(path: string, callback: (boolean) -> ())
    noctalia.runAsync("test -w " .. shell_quote(path), function(res)
        callback(res.exitCode == 0)
    end)
end

local function set_threshold(value: number)
    local batteries = get_batteries()
    if #batteries == 0 then
        return
    end

    local v = common.clamp(math.floor(value + 0.5))

    local any_ok = false
    for _, battery in ipairs(batteries) do
        local threshold_file = battery .. common.BATTERY_FILES.THRESHOLD
        noctalia.log("Setting charge threshold to " .. tostring(v) .. "% on " .. battery)

        local ok, err = noctalia.writeFile(threshold_file, tostring(v) .. "\n")
        if ok then
            any_ok = true
        else
            noctalia.log("Failed to write threshold to " .. threshold_file .. ": " .. tostring(err))
            noctalia.notifyError(
                noctalia.tr("notification.error-title"),
                noctalia.tr("notification.error-msg", { file = threshold_file })
            )
        end
    end

    if any_ok then
        noctalia.state.set(common.STATE.CURRENT_THRESHOLD, v)
        if common.THRESHOLD_FILE_PATH then
            local save_ok, save_err = noctalia.writeFile(common.THRESHOLD_FILE_PATH, tostring(v))
            if not save_ok then
                noctalia.log(
                    "Failed to write saved threshold to " .. common.THRESHOLD_FILE_PATH .. ": " .. tostring(save_err)
                )
            end
        end
    end
end

local function check_status()
    local batteries = get_batteries()
    if #batteries == 0 then
        noctalia.state.set(common.STATE.IS_AVAILABLE, false)
        noctalia.state.set(common.STATE.IS_WRITABLE, false)
        noctalia.state.set(common.STATE.CURRENT_THRESHOLD, 0)
        noctalia.state.set(common.STATE.BATTERY_MODEL_NAME, "")
        return
    end

    noctalia.state.set(common.STATE.IS_AVAILABLE, true)

    local model_names = {}
    for _, battery in ipairs(batteries) do
        local model = read_trimmed(battery .. common.BATTERY_FILES.MODEL)
        local name = string.match(battery, "([^/]+)$") or battery
        if model and model ~= "" then
            table.insert(model_names, if #batteries > 1 then (name .. ": " .. model) else model)
        else
            table.insert(model_names, name)
        end
    end
    noctalia.state.set(common.STATE.BATTERY_MODEL_NAME, table.concat(model_names, ", "))

    local first_battery = batteries[1]
    local threshold_content = read_trimmed(first_battery .. common.BATTERY_FILES.THRESHOLD)
    local current_val = tonumber(threshold_content) or 0
    noctalia.state.set(common.STATE.CURRENT_THRESHOLD, current_val)

    local pending_checks = #batteries
    local any_writable = false

    for _, battery in ipairs(batteries) do
        local threshold_file = battery .. common.BATTERY_FILES.THRESHOLD
        check_writable(threshold_file, function(writable)
            if writable then
                any_writable = true
            end

            pending_checks -= 1
            if pending_checks == 0 then
                noctalia.state.set(common.STATE.IS_WRITABLE, any_writable)

                if any_writable then
                    local saved_val = nil
                    if common.THRESHOLD_FILE_PATH and noctalia.fileExists(common.THRESHOLD_FILE_PATH) then
                        local saved_content = read_trimmed(common.THRESHOLD_FILE_PATH)
                        if saved_content then
                            saved_val = tonumber(saved_content)
                        end
                    end

                    if not saved_val then
                        local config_val = noctalia.getConfig(common.CONFIG.CHARGE_THRESHOLD)
                        if typeof(config_val) == "number" then
                            saved_val = config_val
                        end
                    end

                    if saved_val and saved_val >= 40 and saved_val <= 100 then
                        if saved_val ~= current_val then
                            set_threshold(saved_val)
                        end
                    end
                end
            end
        end)
    end
end

local function run_setup()
    local user = noctalia.getenv("USER")
    if not user or user == "" then
        noctalia.log("Could not get USER environment variable")
        return
    end

    local plugin_dir = noctalia.pluginDir()
    if not plugin_dir then
        noctalia.log("Could not get plugin directory")
        return
    end

    local rules_script = plugin_dir .. "/setup_rules.sh"

    local cmd = string.format("bash %s %s", shell_quote(rules_script), shell_quote(user))

    noctalia.log("Launching setup script in terminal: " .. cmd)
    local launched = noctalia.runInTerminal(cmd)
    if launched then
        noctalia.log("Setup script launched in terminal")
    else
        noctalia.log("Failed to launch terminal for setup script")
        noctalia.notifyError(noctalia.tr("notification.setup-title"), noctalia.tr("notification.setup-fail"))
    end
    noctalia.state.set(common.STATE.RUN_SETUP_REQUEST, false)
end

noctalia.state.watch(common.STATE.RUN_SETUP_REQUEST, function(val)
    if val == true then
        run_setup()
    end
end)

noctalia.state.watch(common.STATE.SET_THRESHOLD_REQUEST, function(val)
    if val then
        local num = tonumber(val)
        if num then
            set_threshold(num)
        end
    end
end)

function onIpc(event, payload)
    if event == "set" then
        if payload then
            local val = tonumber(payload)
            if val and common.inRange(val) then
                set_threshold(val)
            end
        end
    elseif event == "setup" then
        run_setup()
    end
end

function onConfigChanged()
    check_status()
end

check_status()
