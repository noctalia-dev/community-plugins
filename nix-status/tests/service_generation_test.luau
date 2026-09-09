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

local BOOTED_SYSTEM = "/nix/store/booted-system"
local CURRENT_SYSTEM = "/nix/store/current-system"

local function commandResult(fields)
    local result = {
        exitCode = 0,
        stdout = "",
        stderr = "",
        timedOut = false,
        stdoutTruncated = false,
        stderrTruncated = false,
    }

    for key, value in pairs(fields or {}) do
        result[key] = value
    end

    return result
end

local function startService(fake)
    return serviceRuntime.start(fake.host, "/flake", {
        closureCheck = closureCheck,
        closureDiff = closureDiff,
        contracts = contracts,
        flakeUpdate = flakeUpdate,
        generationCheck = generationCheck,
        nix = nix,
        systemTarget = systemTarget,
        systemTargetCheck = systemTargetCheck,
    })
end

local function expectGenerationCommand(command)
    t.expectTruthy(command)
    t.expectEqual(command.started, true)
    t.expectEqual(command.timeoutMs, 5000)
    t.expectEqual(#command.argv, 4)
    t.expectEqual(command.argv[1], "readlink")
    t.expectEqual(command.argv[2], "-f")
    t.expectEqual(command.argv[3], "/run/booted-system")
    t.expectEqual(command.argv[4], "/run/current-system")
end

t.test("service starts a generation check and initializes workflow states", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    local generation = fake.getState("generation-status")
    t.expectEqual(generation.state, "checking")
    t.expectEqual(fake.getState("closure-diff-status").state, "idle")
    t.expectEqual(fake.getState("status").state, "idle")
    t.expectEqual(fake.getUpdateInterval(), 60000)
    t.expectEqual(#fake.commands, 1)
    expectGenerationCommand(fake.commands[1])
end)

t.test("generation refresh preserves the previous result while running", function()
    local fake = fakeNoctalia.new({
        ["generation-status"] = {
            state = "different",
            bootedPath = BOOTED_SYSTEM,
            currentPath = CURRENT_SYSTEM,
            message = "previous message",
        },
    })

    startService(fake)

    local generation = fake.getState("generation-status")
    t.expectEqual(generation.state, "different")
    t.expectEqual(generation.bootedPath, BOOTED_SYSTEM)
    t.expectEqual(generation.currentPath, CURRENT_SYSTEM)
    t.expectEqual(generation.message, "previous message")
    t.expectEqual(generation.refreshing, true)
end)

t.test("generation requests are discarded while a check is running", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    fake.setState("generation-refresh-request", 1)
    fake.setState("generation-refresh-request", 2)
    t.expectEqual(#fake.commands, 1)

    fake.complete(1, commandResult({
        stdout = BOOTED_SYSTEM .. "\n" .. CURRENT_SYSTEM .. "\n",
    }))
    fake.setState("generation-refresh-request", 3)

    t.expectEqual(#fake.commands, 3)
    expectGenerationCommand(fake.commands[3])
end)

t.test("generation check reports equal and different system paths", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    fake.complete(1, commandResult({
        stdout = BOOTED_SYSTEM .. "\n" .. BOOTED_SYSTEM .. "\n",
    }))

    local current = fake.getState("generation-status")
    t.expectEqual(current.state, "current")
    t.expectEqual(current.bootedPath, BOOTED_SYSTEM)
    t.expectEqual(current.currentPath, BOOTED_SYSTEM)
    t.expectNil(current.refreshing)

    fake.setState("generation-refresh-request", 1)
    fake.complete(3, commandResult({
        stdout = BOOTED_SYSTEM .. "\n" .. CURRENT_SYSTEM .. "\n",
    }))

    local different = fake.getState("generation-status")
    t.expectEqual(different.state, "different")
    t.expectEqual(different.bootedPath, BOOTED_SYSTEM)
    t.expectEqual(different.currentPath, CURRENT_SYSTEM)
    t.expectNil(different.refreshing)
end)

t.test("generation check reports timeout and releases its running guard", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    fake.complete(1, commandResult({ timedOut = true }))

    local generation = fake.getState("generation-status")
    t.expectEqual(generation.state, "error")
    t.expectEqual(generation.message, "Timed out while resolving NixOS system generations")

    fake.setState("generation-refresh-request", 1)
    t.expectEqual(#fake.commands, 2)
end)

t.test("generation check uses stderr and fallback errors for command failures", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    fake.complete(1, commandResult({
        exitCode = 1,
        stderr = "  readlink failed  \n",
    }))
    t.expectEqual(fake.getState("generation-status").message, "readlink failed")

    fake.setState("generation-refresh-request", 1)
    fake.complete(2, commandResult({ exitCode = 1 }))
    t.expectEqual(
        fake.getState("generation-status").message,
        "Could not resolve NixOS system generations"
    )
end)

t.test("generation check rejects malformed successful output", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    fake.complete(1, commandResult({ stdout = BOOTED_SYSTEM .. "\n" }))

    local generation = fake.getState("generation-status")
    t.expectEqual(generation.state, "error")
    t.expectEqual(generation.message, "Expected booted and current NixOS system paths")
end)

t.test("generation check handles failure to start and can retry", function()
    local fake = fakeNoctalia.new()
    fake.queueStartResult(false)

    startService(fake)

    local generation = fake.getState("generation-status")
    t.expectEqual(generation.state, "error")
    t.expectEqual(generation.message, "Could not start generation check")
    t.expectEqual(fake.commands[1].started, false)

    fake.setState("generation-refresh-request", 1)
    t.expectEqual(#fake.commands, 2)
    expectGenerationCommand(fake.commands[2])
end)

return true
