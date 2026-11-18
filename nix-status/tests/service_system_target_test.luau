local closureCheck = require("../lib/closure_check")
local closureDiff = require("../lib/closure_diff")
local contracts = require("../lib/contracts")
local fakeNoctalia = require("./fake_noctalia")
local flakeUpdate = require("../lib/flake_update")
local generationCheck = require("../lib/generation_check")
local nix = require("../lib/nix")
local serviceRuntime = require("../lib/service_runtime")
local systemTarget = require("../lib/system_target")
local systemTargetCheck = require("../lib/system_target_check")
local t = require("./testlib")

local CURRENT_PATH = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-vm-current"
local FLAKE_DIR = "/home/test/nixos"

local function result(fields)
    local value = { exitCode = 0, stdout = "", stderr = "", timedOut = false }
    for key, field in pairs(fields or {}) do
        value[key] = field
    end
    return value
end

local function startService(fake)
    return serviceRuntime.start(fake.host, FLAKE_DIR, {
        closureCheck = closureCheck,
        closureDiff = closureDiff,
        contracts = contracts,
        flakeUpdate = flakeUpdate,
        generationCheck = generationCheck,
        nix = nix,
        systemTarget = systemTarget,
        systemTargetCheck = systemTargetCheck,
    }, { state = "configured", configuration = "vm" })
end

t.test("runtime routes manual and successful update target refreshes", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    t.expectEqual(fake.commands[1].argv[1], "readlink")
    t.expectEqual(fake.commands[1].argv[3], "/run/current-system")
    t.expectEqual(fake.commands[2].argv[1], "readlink")
    t.expectEqual(fake.commands[2].argv[3], "/run/booted-system")

    fake.complete(1, result({ stdout = CURRENT_PATH }))
    fake.complete(3, result({ stdout = CURRENT_PATH }))
    t.expectEqual(fake.getState("system-target-status").state, "current")

    fake.setState("system-target-refresh-request", 1)
    t.expectEqual(fake.commands[4].argv[1], "readlink")
    fake.complete(4, result({ stdout = CURRENT_PATH }))
    fake.complete(5, result({ stdout = CURRENT_PATH }))

    fake.setState("check-request", 1)
    t.expectEqual(fake.commands[6].argv[1], "nix")
    t.expectEqual(fake.commands[6].argv[2], "flake")
    fake.complete(6, result())

    t.expectEqual(#fake.commands, 7)
    t.expectEqual(fake.commands[7].argv[1], "readlink")
    t.expectEqual(fake.commands[7].argv[3], "/run/current-system")
end)

return true
