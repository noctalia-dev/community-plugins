--!nonstrict
-- SERVICE_SOURCE is injected by run.py. Only the Noctalia host boundary is faked;
-- startup, device parsing, migration, command dispatch, and playback are real code.
local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function keyboard(name, event, ev)
    return 'N: Name="' .. name .. '"\nH: Handlers=kbd event' .. event
        .. '\nB: EV=' .. (ev or '120013')
        .. '\nB: KEY=ffffffffffffffff fffffffffffffffe\n\n'
end

local function boot(options)
    options = options or {}
    local files = options.files or {}
    local dirs = options.dirs or {}
    local state, watchers, commands, errors = {}, {}, {}, {}
    local env = options.env or { HOME = "/home/test" }
    local config = { executable_path = "wayvibes", soundpacks_dir = "", default_volume = 3, auto_start = false }
    for key, value in pairs(options.config or {}) do
        config[key] = value
    end
    noctalia = {
        getenv = function(key) return env[key] end,
        getConfig = function(key) return config[key] end,
        pluginDataDir = function() return "/state/wayvibes" end,
        fileExists = function(path) return files[path] ~= nil or dirs[path] ~= nil end,
        readFile = function(path) return files[path] end,
        listDir = function(path) return dirs[path] end,
        mkdirAll = function(path) dirs[path] = dirs[path] or {}; return true end,
        writeFile = function(path, content)
            if options.failWrites then return false, "Permission denied" end
            files[path] = content
            return true
        end,
        removeFile = function(path) files[path] = nil; return true end,
        tr = function(key) return key end,
        notify = function() end,
        notifyError = function(_, message) table.insert(errors, message) end,
        commandExists = function() return options.executableMissing ~= true end,
        runAsync = function(command, callback)
            table.insert(commands, command)
            local exitCode = 0
            if options.startFails and type(command) == "string" and command:find("pgrep", 1, true) then
                exitCode = 1
            end
            if callback then callback({ exitCode = exitCode, stdout = "", stderr = "" }) end
            return true
        end,
        state = {
            set = function(key, value) state[key] = value end,
            get = function(key) return state[key] end,
            watch = function(key, callback) watchers[key] = callback end,
        },
    }
    assert(os.getenv == nil, "Run these tests in Luau, where os.getenv is unavailable")
    assert(loadstring(SERVICE_SOURCE, "service.luau"))()
    return {
        files = files, state = state, commands = commands, errors = errors,
        send = function(command) assert(watchers.wayvibes_cmd, "command watcher missing")(command) end,
    }
end

test("fresh profile without packs or devices still initializes its command handler", function()
    local app = boot()
    assert(app.state.wayvibes_ready == true)
    assert(#app.state.wayvibes_packs == 0)
    assert(#app.state.wayvibes_devices == 0)
    assert(#app.commands == 0)
    app.send({ action = "scan" })
    app.send({ action = "play", packPath = "/packs/cream" })
    assert(app.state.wayvibes_playing == false)
    assert(app.errors[1] == "no_device_warning")
end)

test("missing executable reports the installation problem before stopping any daemon", function()
    local app = boot({ executableMissing = true, files = {
        ["/home/test/.config/wayvibes/input_device"] = "NAME:USB Keyboard\n",
    } })
    app.send({ action = "play", packPath = "/packs/cream" })
    assert(app.state.wayvibes_playing ~= true)
    assert(app.errors[1] == "daemon_missing", "missing binary misreported as a permissions failure")
    assert(#app.commands == 0, "missing binary must not stop an existing daemon")
end)

test("failed daemon startup never publishes successful playback", function()
    local app = boot({ startFails = true, files = {
        ["/home/test/.config/wayvibes/input_device"] = "NAME:USB Keyboard\n",
    } })
    app.send({ action = "play", packPath = "/packs/cream" })
    assert(app.state.wayvibes_playing == false)
    assert(#app.errors == 1)
    assert(app.files["/state/wayvibes/state.json"] == nil)
end)

test("startup discovers keyboards and soundpacks without os.getenv", function()
    local app = boot({
        files = {
            ["/proc/bus/input/devices"] = keyboard("USB Keyboard", 7)
                .. 'N: Name="Power Button"\nH: Handlers=kbd event0\nB: EV=3\nB: KEY=8000\n\n',
            ["/home/test/.local/share/soundpacks/cream/config.json"] = '{"name":"Cream"}',
        },
        dirs = { ["/home/test/.local/share/soundpacks"] = { "cream" } },
    })
    assert(app.state.wayvibes_ready == true)
    assert(#app.state.wayvibes_devices == 1)
    assert(app.state.wayvibes_devices[1].path == "/dev/input/event7")
    assert(app.state.wayvibes_packs[1].name == "Cream")
    assert(app.files["/home/test/.config/wayvibes/input_device"] == "NAME:USB Keyboard\n")
    app.send({ action = "scan" })
    assert(#app.commands == 0, "discovery must not call unsupported daemon options")
end)

test("current NAME configuration under XDG_CONFIG_HOME permits playback", function()
    local app = boot({
        env = { HOME = "/home/test", XDG_CONFIG_HOME = "/custom/config" },
        files = { ["/custom/config/wayvibes/input_device"] = "NAME:USB Keyboard\n" },
    })
    assert(app.state.wayvibes_device == "USB Keyboard")
    app.send({ action = "play", packPath = "/packs/cream", packName = "Cream" })
    assert(app.state.wayvibes_playing == true)
    assert(#app.errors == 0)
    assert(app.files["/home/test/.config/wayvibes/input_device"] == nil)
end)

test("current PATH configuration works when XDG_CONFIG_HOME is empty", function()
    local app = boot({
        env = { HOME = "/home/test", XDG_CONFIG_HOME = "" },
        files = { ["/home/test/.config/wayvibes/input_device"] = "PATH:/dev/input/by-id/usb-kbd\n" },
    })
    assert(app.state.wayvibes_device == "/dev/input/by-id/usb-kbd")
    app.send({ action = "play", packPath = "/packs/cream" })
    assert(app.state.wayvibes_playing == true)
end)

test("legacy path is migrated and removed after a successful write", function()
    local app = boot({ files = { ["/home/test/.config/wayvibes/input_device_path"] = "/dev/input/event7\n" } })
    assert(app.files["/home/test/.config/wayvibes/input_device"] == "PATH:/dev/input/event7\n")
    assert(app.files["/home/test/.config/wayvibes/input_device_path"] == nil)
    assert(app.state.wayvibes_device == "/dev/input/event7")
end)

test("legacy name is migrated using the current format", function()
    local app = boot({ files = { ["/home/test/.config/wayvibes/input_device_name"] = "USB Keyboard\n" } })
    assert(app.files["/home/test/.config/wayvibes/input_device"] == "NAME:USB Keyboard\n")
    assert(app.files["/home/test/.config/wayvibes/input_device_name"] == nil)
end)

test("migration preserves the original file when saving fails", function()
    local app = boot({ failWrites = true, files = {
        ["/home/test/.config/wayvibes/input_device_path"] = "/dev/input/event7\n",
    } })
    assert(app.files["/home/test/.config/wayvibes/input_device_path"] == "/dev/input/event7\n", "legacy config lost")
    assert(app.files["/home/test/.config/wayvibes/input_device"] == nil)
end)

test("existing current configuration takes precedence over legacy files", function()
    local app = boot({ files = {
        ["/home/test/.config/wayvibes/input_device"] = "NAME:Current Keyboard\n",
        ["/home/test/.config/wayvibes/input_device_path"] = "/dev/input/event1\n",
    } })
    assert(app.state.wayvibes_device == "Current Keyboard")
    assert(app.files["/home/test/.config/wayvibes/input_device_path"] ~= nil)
end)

test("invalid device records do not pass the playback configuration check", function()
    local app = boot({ files = { ["/home/test/.config/wayvibes/input_device"] = "invalid\n" } })
    app.send({ action = "play", packPath = "/packs/cream" })
    assert(app.state.wayvibes_playing ~= true)
    assert(#app.errors == 1)
end)

test("keyboard detection accepts KEY_A without repeat capability", function()
    local app = boot({ files = { ["/proc/bus/input/devices"] = keyboard("Virtual Keyboard", 9, "3") } })
    assert(#app.state.wayvibes_devices == 1, "keyboard omitted")
end)

test("by-id fallback saves a PATH rather than its synthetic display name", function()
    local app = boot({ dirs = { ["/dev/input/by-id"] = { "usb-Acme_Keyboard-event-kbd" } } })
    assert(app.files["/home/test/.config/wayvibes/input_device"] == "PATH:/dev/input/by-id/usb-Acme_Keyboard-event-kbd\n")
    app.send({ action = "select_device", devicePath = "/dev/input/by-id/usb-Acme_Keyboard-event-kbd", deviceName = "Acme Keyboard" })
    assert(app.files["/home/test/.config/wayvibes/input_device"] == "PATH:/dev/input/by-id/usb-Acme_Keyboard-event-kbd\n")
end)

test("identical keyboard names are selected by path", function()
    local app = boot({ files = {
        ["/proc/bus/input/devices"] = keyboard("USB Keyboard", 7) .. keyboard("USB Keyboard", 8),
    } })
    app.send({ action = "select_device", devicePath = "/dev/input/event8", deviceName = "USB Keyboard" })
    assert(app.files["/home/test/.config/wayvibes/input_device"] == "PATH:/dev/input/event8\n")
end)

test("failed device writes report an error without changing selection", function()
    local app = boot({ failWrites = true, files = { ["/home/test/.config/wayvibes/input_device"] = "NAME:Existing\n" } })
    app.send({ action = "select_device", devicePath = "/dev/input/event8", deviceName = "USB Keyboard" })
    assert(app.state.wayvibes_device == "Existing")
    assert(#app.errors == 1)
end)

print(tostring(passed) .. " passed, " .. tostring(failed) .. " failed")
assert(failed == 0, "Service regression tests failed")
