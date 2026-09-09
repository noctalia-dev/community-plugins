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

local SYSTEM_PATH = "/nix/store/system"

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

local function completeInitialGeneration(fake)
    fake.complete(1, commandResult({
        stdout = SYSTEM_PATH .. "\n" .. SYSTEM_PATH .. "\n",
    }))
end

local function requestClosureDiff(fake, value)
    fake.setState("closure-diff-request", value or 1)
end

local function expectClosureCommand(command)
    t.expectTruthy(command)
    t.expectEqual(command.started, true)
    t.expectEqual(command.timeoutMs, 60000)
    t.expectEqual(#command.argv, 5)
    t.expectEqual(command.argv[1], "nix")
    t.expectEqual(command.argv[2], "store")
    t.expectEqual(command.argv[3], "diff-closures")
    t.expectEqual(command.argv[4], "/run/booted-system")
    t.expectEqual(command.argv[5], "/run/current-system")
end

t.test("closure request publishes running and starts the expected command", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    requestClosureDiff(fake)

    t.expectEqual(fake.getState("closure-diff-status").state, "running")
    t.expectEqual(#fake.commands, 2)
    expectClosureCommand(fake.commands[2])
end)

t.test("closure requests are discarded while a comparison is running", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    requestClosureDiff(fake, 1)
    requestClosureDiff(fake, 2)
    t.expectEqual(#fake.commands, 2)

    fake.complete(2, commandResult({ timedOut = true }))
    requestClosureDiff(fake, 3)

    t.expectEqual(#fake.commands, 3)
    expectClosureCommand(fake.commands[3])
end)

t.test("successful startup generation check runs closure comparison automatically", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    t.expectEqual(fake.getState("closure-diff-status").state, "idle")

    completeInitialGeneration(fake)
    t.expectEqual(fake.getState("closure-diff-status").state, "running")
    expectClosureCommand(fake.commands[2])

    fake.complete(2, commandResult({
        stdout = "Closure size: \27[91m12.5 MiB\27[0m\n",
        stdoutTruncated = true,
    }))

    local status = fake.getState("closure-diff-status")
    t.expectEqual(status.state, "ready")
    t.expectEqual(status.output, "Closure size: 12.5 MiB")
    t.expectEqual(status.truncated, true)
    t.expectEqual(#status.lines, 1)
    t.expectEqual(status.lines[1].prefix, "Closure size: ")
    t.expectEqual(status.lines[1].amount, "+12.5 MiB")
    t.expectEqual(status.lines[1].change, "increase")

    t.expectEqual(#fake.commands, 2)
end)

t.test("successful manual closure comparison refreshes generation", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    completeInitialGeneration(fake)
    fake.complete(2, commandResult())

    requestClosureDiff(fake)
    fake.complete(3, commandResult())

    t.expectEqual(#fake.commands, 4)
    t.expectEqual(fake.commands[4].argv[1], "readlink")
    t.expectEqual(fake.commands[4].argv[2], "-f")
end)

t.test("closure timeout publishes an error and releases its running guard", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    requestClosureDiff(fake)

    fake.complete(2, commandResult({ timedOut = true }))

    local status = fake.getState("closure-diff-status")
    t.expectEqual(status.state, "error")
    t.expectEqual(status.message, "Nix store closure comparison timed out")

    requestClosureDiff(fake, 2)
    t.expectEqual(#fake.commands, 3)
end)

t.test("closure failure prefers stderr then stdout then fallback text", function()
    local fake = fakeNoctalia.new()
    startService(fake)

    requestClosureDiff(fake, 1)
    fake.complete(2, commandResult({
        exitCode = 1,
        stderr = "  \27[31mstderr failure\27[0m  \n",
        stdout = "stdout failure",
    }))
    t.expectEqual(fake.getState("closure-diff-status").message, "stderr failure")

    requestClosureDiff(fake, 2)
    fake.complete(3, commandResult({
        exitCode = 1,
        stdout = "  stdout failure  \n",
    }))
    t.expectEqual(fake.getState("closure-diff-status").message, "stdout failure")

    requestClosureDiff(fake, 3)
    fake.complete(4, commandResult({ exitCode = 1 }))
    t.expectEqual(
        fake.getState("closure-diff-status").message,
        "Nix store closure comparison failed"
    )
end)

t.test("closure comparison handles failure to start and can retry", function()
    local fake = fakeNoctalia.new()
    startService(fake)
    fake.queueStartResult(false)

    requestClosureDiff(fake, 1)

    local status = fake.getState("closure-diff-status")
    t.expectEqual(status.state, "error")
    t.expectEqual(status.message, "Could not start Nix store closure comparison")
    t.expectEqual(fake.commands[2].started, false)

    requestClosureDiff(fake, 2)
    t.expectEqual(#fake.commands, 3)
    expectClosureCommand(fake.commands[3])
end)

t.test("service reload clears retained closure state before rebuilding it", function()
    for _, retainedState in ipairs({ "running", "ready", "error" }) do
        local fake = fakeNoctalia.new({
            ["closure-diff-status"] = {
                state = retainedState,
                output = "stale output",
                message = "stale error",
            },
        })

        startService(fake)
        local status = fake.getState("closure-diff-status")
        t.expectEqual(status.state, "idle")
        t.expectNil(status.output)
        t.expectNil(status.message)

        completeInitialGeneration(fake)
        t.expectEqual(fake.getState("closure-diff-status").state, "running")
        expectClosureCommand(fake.commands[2])
    end
end)

t.test("failed startup generation check leaves closure comparison idle", function()
    local fake = fakeNoctalia.new({
        ["closure-diff-status"] = {
            state = "ready",
            output = "stale output",
        },
    })
    startService(fake)

    fake.complete(1, commandResult({
        exitCode = 1,
        stderr = "readlink failed",
    }))

    t.expectEqual(fake.getState("generation-status").state, "error")
    t.expectEqual(fake.getState("closure-diff-status").state, "idle")
    t.expectEqual(#fake.commands, 1)
end)

return true
