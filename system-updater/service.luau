--!nonstrict

-- List of adapters for checking and installing updates.  Each adapter is a table with the following fields:
-- {
--     name = "adapter name",
--     enabled = true or false,
--     dependencies = {"list", "of", "dependencies"},
--     check_command = "command to run to check for updates",
--     update_package_command = "command to run to update a single package". Use {package_name} as a placeholder for the package name.
--                              If this field is empty, the adapter does not support updating single packages.
--     update_all_command = "command to run to update all packages",
--     phase = "ready" or "checking" or "updating". This field is filled in by the service and is not part of the adapter definition,
--     error_msg = "error message if any". This field is filled in by the service and is not part of the adapter definition,
--     total = number of updates available. This field is filled in by the service and is not part of the adapter definition,
--     updates = {"list", "of", "updates"}. This field is filled in by the service and is not part of the adapter definition,
-- }
local adapters = {}

local startup_time = os.time()
local last_check_time = nil

-- The adapter that should be rechecked after an update is completed.
-- This is used to recheck for updates after an update is completed, so that the user can see if there are any new updates available.
local recheck_adapter = {}

-- Table with pending and finished tasks for checking updates.
-- task structure:
-- {
--     cmd = "command to run",
--     adapter = "adapter name",
--     phase = "check",
--     state = "waiting" or "running" or "done" or "error",
--     error_msg = "error message if any"
-- }
local task_checking = {
    pending = {},
    finished = {}
}

-- Table with pending and finished tasks for installing updates.
-- 
local task_updating = {
    pending = {},
    finished = {}
}

local state = "idle"

local function cfg(key)
    return noctalia.getConfig(key)
end

local function log(msg)
    noctalia.log("[system-updater] " .. msg)
end

local function err(msg)
    noctalia.log("[ERR][system-updater] " .. msg)
end

-- Load the adapters from the plugin's adapters directory. Each adapter is a JSON file with a name and a check command.
local function load_adapters()
    local dirs = {
        noctalia.pluginDir() .. "/adapters",
    }
    if cfg("adapters_folder") ~= nil and cfg("adapters_folder") ~= "" then
        log("User adapters folder: " .. (cfg("adapters_folder") or "not set")) 
        if noctalia.fileExists(cfg("adapters_folder")) then
            table.insert(dirs, cfg("adapters_folder"))
        end
    end

    local out = {}

    for _, dir in ipairs(dirs) do
        local sub_dirs = noctalia.listDir(dir)
        for _, dir_name in ipairs(sub_dirs) do
            local file_info = noctalia.fileInfo(dir .. "/" .. dir_name)
            if file_info.isDir then
                local adapter_dir = dir .. "/" .. dir_name
                local adapter_json_file = adapter_dir .. "/adapter.json"
                if noctalia.fileExists(adapter_json_file) then
                    local str = noctalia.readFile(adapter_json_file)
                    local adapter = noctalia.json.decode(str) or nil
                    if adapter ~= nil and adapter.name ~= nil and adapter.check_command ~= nil then
                        if adapter.name == "PackageKit" and cfg("enable_packagekit") == false then
                            adapter.enabled = false
                        elseif adapter.name == "Flatpak" and cfg("enable_flatpak") == false then
                            adapter.enabled = false
                        elseif adapter.name == "Cargo" and cfg("enable_cargo") == false then
                            adapter.enabled = false
                        elseif adapter.name == "pipx" and cfg("enable_pipx") == false then
                            adapter.enabled = false
                        elseif adapter.name == "Gear LEver" and cfg("enable_gearlever") == false then
                            adapter.enabled = false
                        elseif adapter.name == "XBPS" and cfg("enable_xbps") == false then
                            adapter.enabled = false
                        end

                        for _, dep in ipairs(adapter.dependencies or {}) do
                            if not noctalia.commandExists(dep) then
                                err("Adapter " .. adapter.name .. " is missing dependency: " .. dep)
                                adapter.enabled = false
                            end
                        end
                        if adapter.enabled then
                            adapter.error_msg = ""
                            adapter.info = ""
                            adapter.show_actions = {}
                            adapter.total = 0
                            adapter.updates = {}
                            adapter.check_command = string.gsub(adapter.check_command, "{adapter_dir}", adapter_dir)
                            adapter.update_package_command = string.gsub(adapter.update_package_command or "", "{adapter_dir}", adapter_dir)
                            adapter.update_all_command = string.gsub(adapter.update_all_command or "", "{adapter_dir}", adapter_dir)
                            out[adapter.name] = adapter
                            log("Loaded adapter: " .. adapter.name .. " path " .. adapter_dir)
                        else
                            log("Adapter " .. adapter.name .. " is disabled")
                        end
                    else
                        err("Invalid adapter definition in " .. adapter_json_file .. ". Adapter must have a name and a check_command.")
                    end
                end
            end
        end
    end
    
    return out
end

-- Publish the current state to the plugin's state store.
-- This is used by the widget and panel to display the current state of the system updater.
function publish_state()
    local items = {}
    local updates_count = 0
    local error = false
    for name, adapter in pairs(adapters) do
        if adapter.enabled then
            table.insert(items, {
                name = name,
                error_msg = adapter.error_msg,
                total = adapter.total,
                updates = adapter.updates,
                info = adapter.info,
                actions = adapter.show_actions,
            })
            updates_count = updates_count + adapter.total
            if adapter.error_msg ~= nil and #adapter.error_msg > 0 then
                error = true
            end
        end
    end
    noctalia.state.set("state", {
        state = state,
        error = error,
        total = updates_count,
        adapters = items,
        task_checking = task_checking,
        task_updating = task_updating,
        last_check_time = last_check_time,
    })
end

-- Forward declarations of functions that are defined later in the file.
local start_check_queue
local start_update_queue

-- Start the next command in the run queue, if any.
-- This is called after each command completes, and will start the next command in the queue.
local function next_check_task()
    table.insert(task_checking.finished, task_checking.pending[1])
    table.remove(task_checking.pending, 1)
    start_check_queue()
end

-- Start the next command in the run queue, if any.
--This is called after each command completes, and will start the next command in the queue.
local function next_update_task()
    table.insert(task_updating.finished, task_updating.pending[1])
    table.remove(task_updating.pending, 1)
    start_update_queue()
end

-- Start the next command in the run queue, if any.
-- This is called after each command completes, and will start the next command in the queue.
start_check_queue = function()
    if #task_checking.pending == 0 then
        state = "idle"
        if cfg("notify_on_updates") == true then
            local has_errors = false
            local body = ""
            for idx, task in ipairs(task_checking.finished) do
                if idx > 1 then
                    body = body .. "\n"
                end
                if task.state == "done" then
                    if #adapters[task.adapter].show_actions > 0 then
                        body = body .. noctalia.tr("notify_check_body_action", {adapter = task.adapter})
                    else
                        if adapters[task.adapter].total > 0 then
                            body = body .. noctalia.tr("notify_check_body_found", {adapter = task.adapter, total = adapters[task.adapter].total})
                        else
                            body = body .. noctalia.tr("notify_check_body_success", {adapter = task.adapter})
                        end
                    end
                elseif task.state == "error" then
                    has_errors = true
                    body = body .. noctalia.tr("notify_check_body_error", {adapter = task.adapter})
                end
            end
            if has_errors then
                noctalia.notifyError(noctalia.tr("notify_check_error_title"), body)
            else
                noctalia.notify(noctalia.tr("notify_check_finished_title"), body)
            end
        end
        publish_state()
        return
    end
    local cmd = task_checking.pending[1].cmd
    local adapter = task_checking.pending[1].adapter
    task_checking.pending[1].state = "running"
    publish_state()
    noctalia.runAsync(cmd, function (result)
        if result.timedOut or result.exitCode ~= 0 then
            task_checking.pending[1].state = "error"
            if result.timedOut then
                table.insert(adapters[adapter].error_msg, {
                    phase = task_checking.pending[1].phase,
                    message = noctalia.tr("error_timeout")
                })
                task_checking.pending[1].error_msg = noctalia.tr("error_timeout")
            else
                table.insert(adapters[adapter].error_msg, {
                    phase = task_checking.pending[1].phase,
                    message = result.stderr
                })
                task_checking.pending[1].error_msg = result.stderr
            end
            adapters[adapter].total = 0
        else
            task_checking.pending[1].state = "done"
            local data = noctalia.json.decode(result.stdout) or {info = "", updates = {}}
            adapters[adapter].updates = data.updates
            adapters[adapter].info = data.info or ""
            adapters[adapter].show_actions = data.actions or {}
            adapters[adapter].total = #adapters[adapter].updates
            for _, action in ipairs(adapters[adapter].show_actions) do
                local label_key = "adapter_actions." .. adapter:lower() .. "_" .. action.command .. ".label"
                local tip_key = "adapter_actions." .. adapter:lower() .. "_" .. action.command .. ".tip"
                local label_text = noctalia.tr(label_key)
                local tip_text = noctalia.tr(tip_key)
                if label_text ~= label_key then
                    action.name = label_text
                end
                if tip_text ~= tip_key then
                    action.tip = tip_text
                end
            end
            -- If the adapter returned an info_key, we will try to translate it and use it as the info text.
            if data.info_key ~= nil then
                local info_key = "adapter_actions." .. adapter:lower() .. "_" .. data.info_key .. ".label"
                local info_text = noctalia.tr(info_key)
                if info_text ~= info_key then
                    adapters[adapter].info = noctalia.tr(info_key) or adapters[adapter].info
                end
            end
        end
        publish_state()
        next_check_task()
    end, 60000)
end

-- Start a check for updates.  This will run the check command for each enabled adapter.
local function start_check(adapter_names)
    if adapters == nil then
        err("Adapters are empty")
        return
    end
    if state ~= "idle" then
        err("System updater is busy")
        return
    end

    table.clear(task_checking.pending)
    table.clear(task_checking.finished)

    for name, adapter in pairs(adapters) do
        if adapter.enabled and (adapter_names == nil or table.find(adapter_names, name)) then
            adapters[name].error_msg = {}
            adapters[name].total = 0
            table.insert(task_checking.pending, {
                cmd = string.gsub(adapter.check_command, "{plugin_dir}", noctalia.pluginDir()),
                adapter = name,
                phase = "check",
                state = "waiting",
                error_msg = ""
            })
        end
    end

    if #task_checking.pending > 0 then
        state = "checking"
        last_check_time = os.time()
        publish_state()
        start_check_queue()
    else
        state = "idle"
        publish_state()
    end
end

-- Helper function to check if a string starts with a given prefix.
local function starts_with(str: string, prefix: string): boolean
    return string.sub(str, 1, #prefix) == prefix
end

-- Start the next command in the run queue, if any.  This is called after each command completes, and will start the next command in the queue.
start_update_queue = function()
    if #task_updating.pending == 0 then
        state = "idle"
        if cfg("notify_on_updates") == true then
            local has_errors = false
            local body = ""
            for idx, task in ipairs(task_updating.finished) do
                if idx > 1 then
                    body = body .. "\n"
                end
                if task.state == "done" then
                    body = body .. noctalia.tr("notify_update_body_success", {adapter = task.adapter})
                    table.insert(recheck_adapter, task.adapter)
                elseif task.state == "error" then
                    has_errors = true
                    body = body .. noctalia.tr("notify_update_body_error", {adapter = task.adapter})
                end
            end
            if has_errors then
                noctalia.notifyError(noctalia.tr("notify_update_error_title"), body)
            else
                noctalia.notify(noctalia.tr("notify_update_finished_title"), body)
            end
        end
        start_check(recheck_adapter)
        return
    end

    local cmd = task_updating.pending[1].cmd
    local adapter = task_updating.pending[1].adapter
    task_updating.pending[1].state = "running"
    publish_state()
    noctalia.runStream(cmd, function(line: string)
        local start_prefix = "tordex/system-updater:pid:"
        local done_prefix = "tordex/system-updater:done:"

        if starts_with(line, start_prefix) then
            local pid = tonumber(string.sub(line, #start_prefix + 1))
            task_updating.pending[1].pid = pid
            publish_state()
        elseif starts_with(line, done_prefix) then
            local exitCode = tonumber(string.sub(line, #done_prefix + 1))
            log("Update task finished with exit code " .. tostring(exitCode))
            if exitCode ~= 0 then
                task_updating.pending[1].state = "error"
                table.insert(adapters[adapter].error_msg, {
                    phase = "update",
                    message = task_updating.pending[1].stdout
                })
            else
                task_updating.pending[1].state = "done"
                table.insert(recheck_adapter, adapter)
            end
            publish_state()
            next_update_task()
        else
            task_updating.pending[1].stdout = task_updating.pending[1].stdout .. line .. "\n"
            publish_state()
        end
    end)
end

-- Wrap the update command to capture the PID and exit code, so that we can track the progress of the update.
local function wrap_update_command(cmd)
    return "echo tordex/system-updater:pid:$$;(" .. cmd .. ") 2>&1;echo tordex/system-updater:done:$?"
end

-- Validate the package name to ensure it does not contain any invalid characters.
-- This is used to prevent command injection when updating a single package.
local function validate_package_name(package_name)
    if string.find(package_name, "[^%w%+%-%._:]") then
        err("Package name contains invalid characters: " .. package_name)
        return false
    end
    return true
end

-- Start an update for the specified adapter and package. If no adapter or package is specified, all enabled adapters will be updated.
local function start_update(adapter_name, package)
    if adapters == nil then
        err("Adapters are empty")
        return
    end
    if state ~= "idle" then
        err("System updater is busy")
        return
    end

    table.clear(task_updating.pending)
    table.clear(task_updating.finished)
    table.clear(recheck_adapter)

    if adapter_name ~= nil and package ~= nil then
        if not validate_package_name(package) then
            return
        end
        -- Update a single package using the specified adapter
        local adapter = adapters[adapter_name]
        if adapter ~= nil and adapter.enabled then
            local cmd = string.gsub(adapter.update_package_command, "{package_name}", package)
            cmd = string.gsub(cmd, "{plugin_dir}", noctalia.pluginDir())
            if cmd == nil or cmd == "" then
                err("Adapter " .. adapter_name .. " does not support updating single packages")
                return
            end
            adapters[adapter_name].error_msg = {}
            cmd = wrap_update_command(cmd)
            table.insert(task_updating.pending, {
                cmd = cmd,
                adapter = adapter_name,
                package = package,
                state = "waiting",
                stdout = "",
                pid = nil
            })
        end
    else
        -- Update all packages for all or specified enabled adapters
        for name, adapter in pairs(adapters) do
            if adapter.enabled and adapter.total > 0 and adapter.update_all_command ~= nil and (adapter_name == nil or name == adapter_name) then
                local cmd = string.gsub(adapter.update_all_command, "{plugin_dir}", noctalia.pluginDir())
                if cmd == nil or cmd == "" then
                    err("Adapter " .. name .. " does not support updating all packages")
                    continue
                end
                adapters[name].error_msg = {}
                cmd = wrap_update_command(cmd)
                table.insert(task_updating.pending, {
                    cmd = cmd,
                    adapter = name,
                    package = package,
                    state = "waiting",
                    stdout = "",
                    pid = nil
                })
            end
        end
    end

    if #task_updating.pending > 0 then
        state = "updating"
        publish_state()
        start_update_queue()
    else
        state = "idle"
        publish_state()
    end
end

local function handle(action, adapter, package)
    if action == "check" then
        if adapter ~= nil then
            start_check({adapter})
        else
            start_check()
        end
    elseif action == "update" then
        start_update(adapter, package)
    end
end

-- Scriptable control:
--   noctalia msg plugin tordex/system-updater:service all check
--   noctalia msg plugin tordex/system-updater:service all update
function onIpc(event, _payload)
    handle(event, nil, nil)
end


noctalia.state.watch("request", function(value)
    handle(value.action, value.adapter, value.package)
end)

noctalia.state.watch("del_error", function(value)
    local adapter = value.adapter
    local idx = value.idx
    if adapters[adapter] ~= nil and adapters[adapter].error_msg[idx] ~= nil then
        table.remove(adapters[adapter].error_msg, idx)
        publish_state()
    end
end)

noctalia.state.watch("adapter_action", function(value)
    local adapter = value.adapter
    local cmd = adapters[adapter].actions[value.action].command
    local check_after = adapters[adapter].actions[value.action].check_after
    state = "action"
    publish_state()
    noctalia.runAsync(cmd, function (result)
        if result.timedOut or result.exitCode ~= 0 then
            table.insert(adapters[adapter].error_msg, {
                phase = "action",
                message = result.stderr
            })
            state = "idle"
            publish_state()
        else
            if check_after then
                state = "idle"
                start_check({adapter})
            else
                state = "idle"
                publish_state()
            end
        end
    end, 60000)
end)

function update()
    local auto_check_minutes = cfg("auto_check_minutes") or 0
    if auto_check_minutes > 10 then
        if last_check_time == nil and startup_time ~= nil then
            local now = os.time()
            -- If the system updater has never checked for updates, we check for updates 5 minutes after startup.
            if os.difftime(now, startup_time) >= 5 * 60 then
                startup_time = nil
                start_check()
            end
        elseif last_check_time ~= nil then
            local now = os.time()
            if os.difftime(now, last_check_time) >= 60 * auto_check_minutes then
                last_check_time = now
                start_check()
            end
        end
    end
end

noctalia.setUpdateInterval(1000)
adapters = load_adapters()
publish_state()
