--!nonstrict
local function get_batteries(): { string }
    local batteries = {}
    local files, _ = noctalia.listDir("/sys/class/power_supply")

    if files then
        for _, name in files do
            local path = "/sys/class/power_supply/" .. name
            if noctalia.fileExists(path .. "/charge_control_end_threshold") then
                table.insert(batteries, path)
            end
        end
    end

    return batteries
end

local function get_active_battery(): string?
    local configured = noctalia.getConfig("battery_device")

    if
        typeof(configured) == "string"
        and configured ~= ""
        and noctalia.fileExists(configured .. "/charge_control_end_threshold")
    then
        return configured
    end

    local list = get_batteries()
    return list[1]
end

local function shell_quote(str: string): string
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local function check_writable(path: string, callback: (boolean) -> ())
    noctalia.runAsync("test -w " .. shell_quote(path), function(res)
        callback(res.exitCode == 0)
    end)
end

local data_dir, data_dir_err = noctalia.pluginDataDir()
if not data_dir or data_dir_err then
    noctalia.log(
        "Failed to get plugin data directory: "
            .. tostring(data_dir_err or "unknown error")
    )
end
local THRESHOLD_FILE_PATH: string? = if data_dir
    then data_dir .. "/threshold.txt"
    else nil

local function set_threshold(value: number)
    local battery = get_active_battery()
    if not battery then
        return
    end
    local threshold_file = battery .. "/charge_control_end_threshold"

    local v = math.floor(value + 0.5)
    if v < 40 then
        v = 40
    end
    if v > 100 then
        v = 100
    end

    noctalia.log("Setting charge threshold to " .. tostring(v) .. "% on " .. battery)

    local ok, err = noctalia.writeFile(threshold_file, tostring(v) .. "\n")
    if ok then
        noctalia.state.set("current_threshold", v)
        if THRESHOLD_FILE_PATH then
            local save_ok, save_err =
                noctalia.writeFile(THRESHOLD_FILE_PATH, tostring(v))
            if not save_ok then
                noctalia.log(
                    "Failed to write saved threshold to "
                        .. THRESHOLD_FILE_PATH
                        .. ": "
                        .. tostring(save_err)
                )
            end
        end
    else
        noctalia.log("Failed to write threshold: " .. tostring(err))
        noctalia.notifyError(
            noctalia.tr("notification.error-title"),
            noctalia.tr("notification.error-msg", { file = threshold_file })
        )
    end
end

local function check_status()
    local battery = get_active_battery()
    if not battery then
        noctalia.state.set("is_available", false)
        noctalia.state.set("is_writable", false)
        noctalia.state.set("current_threshold", 0)
        noctalia.state.set("battery_model_name", "")
        return
    end

    noctalia.state.set("is_available", true)

    local model_name = ""
    local content, err = noctalia.readFile(battery .. "/model_name")
    if content and not err then
        model_name = noctalia.string.trim(content)
    end
    noctalia.state.set("battery_model_name", model_name)

    local threshold_file = battery .. "/charge_control_end_threshold"

    local threshold_content = noctalia.readFile(threshold_file)
    local current_val = 0
    if threshold_content then
        current_val = tonumber(noctalia.string.trim(threshold_content)) or 0
        noctalia.state.set("current_threshold", current_val)
    end

    check_writable(threshold_file, function(writable)
        noctalia.state.set("is_writable", writable)

        if writable then
            local saved_val = nil
            if THRESHOLD_FILE_PATH and noctalia.fileExists(THRESHOLD_FILE_PATH) then
                local saved_content, read_err = noctalia.readFile(THRESHOLD_FILE_PATH)
                if saved_content and not read_err then
                    saved_val = tonumber(noctalia.string.trim(saved_content))
                elseif read_err then
                    noctalia.log(
                        "Failed to read saved threshold from "
                            .. THRESHOLD_FILE_PATH
                            .. ": "
                            .. tostring(read_err)
                    )
                end
            end

            if not saved_val then
                local config_val = noctalia.getConfig("charge_threshold")
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
    end)
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

    local cmd =
        string.format("pkexec bash %s %s", shell_quote(rules_script), shell_quote(user))

    noctalia.log("Running setup script via pkexec: " .. cmd)
    noctalia.runAsync(cmd, function(result)
        if result.exitCode == 0 then
            noctalia.log("Setup completed successfully")
            noctalia.notify(
                noctalia.tr("notification.setup-title"),
                noctalia.tr("notification.setup-success")
            )
            check_status()
        else
            noctalia.log("Setup failed with exit code " .. tostring(result.exitCode))
            noctalia.notifyError(
                noctalia.tr("notification.setup-title"),
                noctalia.tr("notification.setup-fail")
            )
        end
        noctalia.state.set("run_setup_request", false)
    end)
end

noctalia.state.watch("run_setup_request", function(val)
    if val == true then
        run_setup()
    end
end)

noctalia.state.watch("set_threshold_request", function(val)
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
            if val and val >= 40 and val <= 100 then
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
