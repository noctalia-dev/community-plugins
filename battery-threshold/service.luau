--!nonstrict
export type BatteryInfo = {
    name: string,
    path: string,
    model_name: string,
    manufacturer: string,
    capacity: number,
    status: string,
    is_writable: boolean,
    current_threshold: number,
}

local current_batteries: { BatteryInfo } = {}

local function get_battery_paths(): { string }
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

    table.sort(batteries)
    return batteries
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

local THRESHOLDS_JSON_PATH: string? = if data_dir
    then data_dir .. "/thresholds.json"
    else nil

local function load_saved_thresholds(): { [string]: number }
    local saved: { [string]: number } = {}
    if THRESHOLDS_JSON_PATH and noctalia.fileExists(THRESHOLDS_JSON_PATH) then
        local content, err = noctalia.readFile(THRESHOLDS_JSON_PATH)
        if content and not err then
            local decoded = noctalia.json.decode(content)
            if typeof(decoded) == "table" then
                for k, v in pairs(decoded) do
                    local num = tonumber(v)
                    if num and num >= 40 and num <= 100 then
                        saved[tostring(k)] = num
                    end
                end
            end
        end
    end

    -- Fallback to legacy threshold.txt
    if THRESHOLD_FILE_PATH and noctalia.fileExists(THRESHOLD_FILE_PATH) then
        local content, err = noctalia.readFile(THRESHOLD_FILE_PATH)
        if content and not err then
            local num = tonumber(noctalia.string.trim(content))
            if num and num >= 40 and num <= 100 then
                saved["_legacy"] = num
            end
        end
    end

    return saved
end

local function save_thresholds(saved_map: { [string]: number })
    if THRESHOLDS_JSON_PATH then
        local json_str = noctalia.json.encode(saved_map, true)
        if json_str then
            local ok, err = noctalia.writeFile(THRESHOLDS_JSON_PATH, json_str)
            if not ok then
                noctalia.log("Failed to save thresholds to JSON: " .. tostring(err))
            end
        end
    end

    -- Also save first threshold to threshold.txt for backwards compatibility
    if THRESHOLD_FILE_PATH then
        local first_val = nil
        for _, b in ipairs(current_batteries) do
            if saved_map[b.name] then
                first_val = saved_map[b.name]
                break
            end
        end
        if not first_val then
            first_val = saved_map["_legacy"]
        end
        if first_val then
            noctalia.writeFile(THRESHOLD_FILE_PATH, tostring(first_val))
        end
    end
end

local function set_battery_threshold(battery_id_or_path: string, value: number)
    local v = math.floor(value + 0.5)
    if v < 40 then
        v = 40
    end
    if v > 100 then
        v = 100
    end

    local target: BatteryInfo? = nil
    for _, b in ipairs(current_batteries) do
        if b.name == battery_id_or_path or b.path == battery_id_or_path then
            target = b
            break
        end
    end

    if not target then
        local path = battery_id_or_path
        if not string.find(path, "/") then
            path = "/sys/class/power_supply/" .. battery_id_or_path
        end
        if noctalia.fileExists(path .. "/charge_control_end_threshold") then
            local name = string.match(path, "([^/]+)$") or battery_id_or_path
            target = {
                name = name,
                path = path,
                model_name = "",
                manufacturer = "",
                capacity = 0,
                status = "",
                is_writable = true,
                current_threshold = 0,
            }
            table.insert(current_batteries, target)
        end
    end

    if not target then
        noctalia.log("Battery not found: " .. tostring(battery_id_or_path))
        return
    end

    local threshold_file = target.path .. "/charge_control_end_threshold"
    noctalia.log(
        "Setting charge threshold to "
            .. tostring(v)
            .. "% on "
            .. target.name
            .. " ("
            .. target.path
            .. ")"
    )

    local ok, err = noctalia.writeFile(threshold_file, tostring(v) .. "\n")
    if ok then
        target.current_threshold = v
        local saved_map = load_saved_thresholds()
        saved_map[target.name] = v
        saved_map["_legacy"] = v
        save_thresholds(saved_map)

        noctalia.state.set("batteries", current_batteries)
        noctalia.state.set(
            "current_threshold",
            current_batteries[1] and current_batteries[1].current_threshold or v
        )
    else
        noctalia.log(
            "Failed to write threshold on "
                .. target.name
                .. ": "
                .. tostring(err)
        )
        noctalia.notifyError(
            noctalia.tr("notification.error-title"),
            noctalia.tr("notification.error-msg", { file = threshold_file })
        )
    end
end

local function set_all_thresholds(value: number)
    local v = math.floor(value + 0.5)
    if v < 40 then
        v = 40
    end
    if v > 100 then
        v = 100
    end

    if #current_batteries == 0 then
        local paths = get_battery_paths()
        for _, p in ipairs(paths) do
            set_battery_threshold(p, v)
        end
        return
    end

    for _, b in ipairs(current_batteries) do
        set_battery_threshold(b.name, v)
    end
end

local function set_threshold(value: number)
    set_all_thresholds(value)
end

local function check_status()
    local paths = get_battery_paths()

    -- Check if user configured a specific battery device
    local configured = noctalia.getConfig("battery_device")
    if
        typeof(configured) == "string"
        and configured ~= ""
        and configured ~= "all"
        and noctalia.fileExists(configured .. "/charge_control_end_threshold")
    then
        paths = { configured }
    end

    if #paths == 0 then
        current_batteries = {}
        noctalia.state.set("batteries", {})
        noctalia.state.set("is_available", false)
        noctalia.state.set("is_writable", false)
        noctalia.state.set("current_threshold", 0)
        noctalia.state.set("battery_model_name", "")
        return
    end

    local saved_map = load_saved_thresholds()
    local config_val = noctalia.getConfig("charge_threshold")
    local default_threshold = if typeof(config_val) == "number"
            and config_val >= 40
            and config_val <= 100
        then config_val
        else 80

    local new_batteries = {}
    local pending_checks = #paths
    local any_writable = false
    local all_writable = true

    for i, path in ipairs(paths) do
        local name = string.match(path, "([^/]+)$") or ("BAT" .. tostring(i - 1))

        local model_name = ""
        local model_content, _ = noctalia.readFile(path .. "/model_name")
        if model_content then
            model_name = noctalia.string.trim(model_content)
        end

        local manufacturer = ""
        local mfg_content, _ = noctalia.readFile(path .. "/manufacturer")
        if mfg_content then
            manufacturer = noctalia.string.trim(mfg_content)
        end

        local capacity = 0
        local cap_content, _ = noctalia.readFile(path .. "/capacity")
        if cap_content then
            capacity = tonumber(noctalia.string.trim(cap_content)) or 0
        end

        local status = "Unknown"
        local status_content, _ = noctalia.readFile(path .. "/status")
        if status_content then
            status = noctalia.string.trim(status_content)
        end

        local threshold_file = path .. "/charge_control_end_threshold"
        local current_val = 0
        local threshold_content = noctalia.readFile(threshold_file)
        if threshold_content then
            current_val = tonumber(noctalia.string.trim(threshold_content)) or 0
        end

        local bat_info: BatteryInfo = {
            name = name,
            path = path,
            model_name = model_name,
            manufacturer = manufacturer,
            capacity = capacity,
            status = status,
            is_writable = false,
            current_threshold = current_val,
        }
        table.insert(new_batteries, bat_info)

        check_writable(threshold_file, function(writable)
            bat_info.is_writable = writable
            if writable then
                any_writable = true
                local target_threshold = saved_map[name]
                    or saved_map["_legacy"]
                    or default_threshold
                if
                    target_threshold
                    and target_threshold >= 40
                    and target_threshold <= 100
                then
                    if current_val ~= target_threshold then
                        local ok, _ = noctalia.writeFile(
                            threshold_file,
                            tostring(target_threshold) .. "\n"
                        )
                        if ok then
                            bat_info.current_threshold = target_threshold
                        end
                    end
                end
            else
                all_writable = false
            end

            pending_checks -= 1
            if pending_checks == 0 then
                current_batteries = new_batteries
                noctalia.state.set("batteries", current_batteries)
                noctalia.state.set("is_available", true)
                noctalia.state.set("is_writable", any_writable)
                noctalia.state.set(
                    "current_threshold",
                    current_batteries[1]
                            and current_batteries[1].current_threshold
                        or 0
                )

                local model_summary = ""
                if #current_batteries == 1 then
                    model_summary = current_batteries[1].model_name
                elseif #current_batteries > 1 then
                    local models = {}
                    for _, b in ipairs(current_batteries) do
                        local label = b.name
                        if b.model_name ~= "" then
                            label = label .. ": " .. b.model_name
                        end
                        table.insert(models, label)
                    end
                    model_summary = table.concat(models, ", ")
                end
                noctalia.state.set("battery_model_name", model_summary)
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

    local cmd =
        string.format("bash %s %s", shell_quote(rules_script), shell_quote(user))

    noctalia.log("Launching setup script in terminal: " .. cmd)
    local launched = noctalia.runInTerminal(cmd)
    if launched then
        noctalia.log("Setup script launched in terminal")
    else
        noctalia.log("Failed to launch terminal for setup script")
        noctalia.notifyError(
            noctalia.tr("notification.setup-title"),
            noctalia.tr("notification.setup-fail")
        )
    end
    noctalia.state.set("run_setup_request", false)
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
            set_all_thresholds(num)
        end
    end
end)

noctalia.state.watch("set_battery_threshold_request", function(val)
    if typeof(val) == "table" then
        local bat = val.battery or val.name or val.path
        local num = tonumber(val.value or val.threshold)
        if bat and num then
            set_battery_threshold(tostring(bat), num)
        end
    elseif typeof(val) == "string" then
        local bat, num_str = string.match(val, "^([^:]+):(%d+)$")
        if not bat then
            bat, num_str = string.match(val, "^(%S+)%s+(%d+)$")
        end
        if bat and num_str then
            local num = tonumber(num_str)
            if num then
                set_battery_threshold(bat, num)
            end
        end
    end
end)

function onIpc(event, payload)
    if event == "set" then
        if payload then
            local payload_str = tostring(payload)
            local bat, val_str = string.match(payload_str, "^(%S+)%s+(%d+)$")
            if not bat then
                bat, val_str = string.match(payload_str, "^([^:]+):(%d+)$")
            end
            if bat and val_str then
                local num = tonumber(val_str)
                if num and num >= 40 and num <= 100 then
                    set_battery_threshold(bat, num)
                end
            else
                local val = tonumber(payload)
                if val and val >= 40 and val <= 100 then
                    set_all_thresholds(val)
                end
            end
        end
    elseif event == "setup" then
        run_setup()
    end
end

function onConfigChanged()
    check_status()
end

function update()
    check_status()
end

if typeof(service) == "table" and typeof(service.setUpdateInterval) == "function" then
    service.setUpdateInterval(5000)
end

check_status()
