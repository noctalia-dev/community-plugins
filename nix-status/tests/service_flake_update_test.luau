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

local FLAKE_DIR = "/home/test/nixos"

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
    return serviceRuntime.start(fake.host, FLAKE_DIR, {
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

local function requestUpdate(fake, value)
    fake.setState("check-request", value or 1)
end

local function expectUpdateCommand(command)
    t.expectTruthy(command)
    t.expectEqual(command.started, true)
    t.expectEqual(command.timeoutMs, 60000)
    t.expectEqual(#command.argv, 5)
    t.expectEqual(command.argv[1], "nix")
    t.expectEqual(command.argv[2], "flake")
    t.expectEqual(command.argv[3], "update")
    t.expectEqual(command.argv[4], "--flake")
    t.expectEqual(command.argv[5], FLAKE_DIR)
end

t.test("flake update request publishes checking and starts the mutating command", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    requestUpdate(fake)

    t.expectEqual(fake.getState("status").state, "checking")
    t.expectEqual(#fake.commands, 2)
    expectUpdateCommand(fake.commands[2])
end)

t.test("flake update requests are discarded while an update is running", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    requestUpdate(fake, 1)
    requestUpdate(fake, 2)
    t.expectEqual(#fake.commands, 2)

    fake.complete(2, commandResult({ timedOut = true }))
    requestUpdate(fake, 3)

    t.expectEqual(#fake.commands, 3)
    expectUpdateCommand(fake.commands[3])
end)

t.test("flake update success with no changes publishes current", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    requestUpdate(fake)

    fake.complete(2, commandResult({
        stdout = "Finished without changing the lock file\n",
    }))

    local status = fake.getState("status")
    t.expectEqual(status.state, "current")
    t.expectEqual(#status.changedInputs, 0)
    t.expectNil(status.message)
end)

t.test("flake update success publishes changes parsed from stdout and stderr", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    requestUpdate(fake)

    fake.complete(2, commandResult({
        stdout = [[
• Added input 'home-manager':
    'github:nix-community/home-manager/aabbccddeeff0011' (2025-03-04)
]],
        stderr = [[
• Updated input 'nixpkgs':
    'github:NixOS/nixpkgs/0123456789abcdef' (2025-01-02)
  → 'github:NixOS/nixpkgs/fedcba9876543210' (2025-02-03)
]],
    }))

    local status = fake.getState("status")
    t.expectEqual(status.state, "updates")
    t.expectEqual(#status.changedInputs, 2)

    local added = status.changedInputs[1]
    t.expectEqual(added.name, "home-manager")
    t.expectEqual(added.kind, "added")
    t.expectEqual(added.newRev, "aabbccdd")
    t.expectEqual(added.newDate, "2025-03-04")

    local updated = status.changedInputs[2]
    t.expectEqual(updated.name, "nixpkgs")
    t.expectEqual(updated.kind, "updated")
    t.expectEqual(updated.oldRev, "01234567")
    t.expectEqual(updated.newRev, "fedcba98")
end)

t.test("flake update timeout publishes an error and releases its running guard", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    requestUpdate(fake, 1)

    fake.complete(2, commandResult({ timedOut = true }))

    local status = fake.getState("status")
    t.expectEqual(status.state, "error")
    t.expectEqual(status.message, "Nix flake update timed out")

    requestUpdate(fake, 2)
    t.expectEqual(#fake.commands, 3)
end)

t.test("flake update failure prefers stderr then stdout then fallback text", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    requestUpdate(fake, 1)
    fake.complete(2, commandResult({
        exitCode = 1,
        stderr = "  stderr failure  \n",
        stdout = "stdout failure",
    }))
    t.expectEqual(fake.getState("status").message, "stderr failure")

    requestUpdate(fake, 2)
    fake.complete(3, commandResult({
        exitCode = 1,
        stdout = "  stdout failure  \n",
    }))
    t.expectEqual(fake.getState("status").message, "stdout failure")

    requestUpdate(fake, 3)
    fake.complete(4, commandResult({ exitCode = 1 }))
    t.expectEqual(fake.getState("status").message, "Nix flake update failed")
end)

t.test("flake update handles failure to start and can retry", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    fake.queueStartResult(false)

    requestUpdate(fake, 1)

    local status = fake.getState("status")
    t.expectEqual(status.state, "error")
    t.expectEqual(status.message, "Could not start nix flake update")
    t.expectEqual(fake.commands[2].started, false)

    requestUpdate(fake, 2)
    t.expectEqual(#fake.commands, 3)
    expectUpdateCommand(fake.commands[3])
end)

t.test("service reload resets interrupted update state and preserves completed state", function()
    local interrupted = fakeNoctalia.new({
        status = { state = "checking" },
    })
    startService(interrupted)
    t.expectEqual(interrupted.getState("status").state, "idle")

    for _, state in ipairs({ "current", "updates", "error" }) do
        local completedStatus = {
            state = state,
            changedInputs = {},
            message = state == "error" and "previous error" or nil,
        }
        local completed = fakeNoctalia.new({ status = completedStatus })
        startService(completed)

        t.expectEqual(completed.getState("status"), completedStatus)
    end
end)

t.test("unconfigured workflow blocks updates until configured", function()
    local fake = fakeNoctalia.new()
    local flake = flakeUpdate.new(fake.host, "status", nil, nix)
    flake.initialize()
    flake.update()
    t.expectEqual(fake.getState("status").state, "unconfigured")
    t.expectEqual(#fake.commands, 0)
    flake.configure(FLAKE_DIR)
    t.expectEqual(fake.getState("status").state, "idle")
    flake.update()
    expectUpdateCommand(fake.commands[1])
end)

t.test("runtime configuration changes reuse watchers and select the next update target", function()
    local fake = fakeNoctalia.new()
    local runtime = startService(fake)
    runtime.configure(nil)
    requestUpdate(fake, 1)
    t.expectEqual(fake.getState("status").state, "unconfigured")
    t.expectEqual(#fake.commands, 1)
    runtime.configure("/other/flake")
    runtime.configure("/other/flake")
    requestUpdate(fake, 2)
    t.expectEqual(#fake.commands, 2)
    t.expectEqual(fake.commands[2].argv[5], "/other/flake")
end)

t.test("configuration changes during update preserve target and discard stale results", function()
    local fake = fakeNoctalia.new()
    local runtime = startService(fake)
    requestUpdate(fake, 1)
    runtime.configure("/other/flake")
    requestUpdate(fake, 2)
    t.expectEqual(#fake.commands, 2)
    t.expectEqual(fake.getState("status").state, "checking")
    t.expectEqual(fake.commands[2].argv[5], FLAKE_DIR)
    fake.complete(2, commandResult())
    t.expectEqual(fake.getState("status").state, "idle")
    requestUpdate(fake, 3)
    t.expectEqual(fake.commands[3].argv[5], "/other/flake")
    runtime.configure(nil)
    fake.complete(3, commandResult({ timedOut = true }))
    t.expectEqual(fake.getState("status").state, "unconfigured")
    requestUpdate(fake, 4)
    t.expectEqual(#fake.commands, 3)
end)

t.test("unchanged configuration preserves an active update result", function()
    local fake = fakeNoctalia.new()
    local runtime = startService(fake)
    requestUpdate(fake)
    runtime.configure(FLAKE_DIR)
    fake.complete(2, commandResult())
    t.expectEqual(fake.getState("status").state, "current")
end)

return true
