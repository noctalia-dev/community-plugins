local fakeNoctalia = require("./fake_noctalia")
local systemTarget = require("../lib/system_target")
local systemTargetCheck = require("../lib/system_target_check")
local t = require("./testlib")

local CURRENT_PATH = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-vm-current"
local TARGET_PATH = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-vm-target"
local FLAKE_DIR = "/home/test/nixos"

local function result(fields)
    local value = { exitCode = 0, stdout = "", stderr = "", timedOut = false }
    for key, field in pairs(fields or {}) do
        value[key] = field
    end
    return value
end

local function workflow(fake, flakeDir, targetConfig)
    return systemTargetCheck.new(
        fake.host,
        "system-target-status",
        "/run/current-system",
        systemTarget,
        flakeDir,
        targetConfig
    )
end

local function configured(name)
    return { state = "configured", configuration = name or "vm" }
end

local function expectCurrentCommand(command)
    t.expectEqual(command.timeoutMs, 5000)
    t.expectEqual(#command.argv, 3)
    t.expectEqual(command.argv[1], "readlink")
    t.expectEqual(command.argv[2], "-f")
    t.expectEqual(command.argv[3], "/run/current-system")
end

local function expectEvaluationCommand(command, flakeDir, name)
    t.expectEqual(command.timeoutMs, 60000)
    t.expectEqual(#command.argv, 5)
    t.expectEqual(command.argv[1], "nix")
    t.expectEqual(command.argv[2], "eval")
    t.expectEqual(command.argv[3], "--raw")
    t.expectEqual(command.argv[4], "--no-update-lock-file")
    t.expectEqual(
        command.argv[5],
        flakeDir .. "#nixosConfigurations." .. name .. ".config.system.build.toplevel.outPath"
    )
end

t.test("system target initializes disabled or invalid configuration without commands", function()
    local disabled = fakeNoctalia.new()
    workflow(disabled, FLAKE_DIR, { state = "disabled" }).initialize()
    t.expectEqual(disabled.getState("system-target-status").state, "disabled")
    t.expectEqual(#disabled.commands, 0)

    local missingFlake = fakeNoctalia.new()
    workflow(missingFlake, nil, configured()).initialize()
    t.expectEqual(missingFlake.getState("system-target-status").state, "disabled")
    t.expectContains(missingFlake.getState("system-target-status").message, "flake directory")
    t.expectEqual(#missingFlake.commands, 0)

    local invalid = fakeNoctalia.new()
    workflow(invalid, FLAKE_DIR, { state = "invalid", message = "Invalid configuration" }).initialize()
    t.expectEqual(invalid.getState("system-target-status").state, "error")
    t.expectEqual(invalid.getState("system-target-status").message, "Invalid configuration")
    t.expectEqual(#invalid.commands, 0)
end)

t.test("system target resolves current system before evaluating configured target", function()
    local fake = fakeNoctalia.new()
    local check = workflow(fake, FLAKE_DIR, configured("vm"))
    check.initialize()

    t.expectEqual(fake.getState("system-target-status").state, "checking")
    t.expectEqual(#fake.commands, 1)
    expectCurrentCommand(fake.commands[1])

    fake.complete(1, result({ stdout = CURRENT_PATH .. "\n" }))
    t.expectEqual(#fake.commands, 2)
    expectEvaluationCommand(fake.commands[2], FLAKE_DIR, "vm")

    fake.complete(2, result({ stdout = TARGET_PATH }))
    local status = fake.getState("system-target-status")
    t.expectEqual(status.state, "different")
    t.expectEqual(status.currentPath, CURRENT_PATH)
    t.expectEqual(status.targetPath, TARGET_PATH)
end)

t.test("system target current-system errors skip evaluation and allow retry", function()
    local cases = {
        {
            result = result({ timedOut = true }),
            message = "Timed out while resolving the current NixOS system",
        },
        {
            result = result({ exitCode = 1, stderr = "readlink failed" }),
            message = "readlink failed",
        },
        {
            result = result({ stdout = "/tmp/not-a-store-path" }),
            message = "Current NixOS system did not resolve to one Nix store path",
        },
    }

    for _, case in ipairs(cases) do
        local fake = fakeNoctalia.new()
        local check = workflow(fake, FLAKE_DIR, configured())
        check.initialize()
        fake.complete(1, case.result)

        t.expectEqual(#fake.commands, 1)
        t.expectEqual(fake.getState("system-target-status").state, "error")
        t.expectEqual(fake.getState("system-target-status").message, case.message)

        check.refresh()
        t.expectEqual(#fake.commands, 2)
        expectCurrentCommand(fake.commands[2])
    end
end)

t.test("system target discards refresh requests while either command is running", function()
    local fake = fakeNoctalia.new()
    local check = workflow(fake, FLAKE_DIR, configured())
    check.initialize()
    check.refresh()
    t.expectEqual(#fake.commands, 1)

    fake.complete(1, result({ stdout = CURRENT_PATH }))
    check.refresh()
    t.expectEqual(#fake.commands, 2)

    fake.complete(2, result({ stdout = CURRENT_PATH }))
    check.refresh()
    t.expectEqual(#fake.commands, 3)
    expectCurrentCommand(fake.commands[3])
end)

t.test("system target reports failures to start either command and allows retry", function()
    local currentFailure = fakeNoctalia.new()
    currentFailure.queueStartResult(false)
    local currentCheck = workflow(currentFailure, FLAKE_DIR, configured())
    currentCheck.initialize()
    t.expectEqual(currentFailure.getState("system-target-status").state, "error")
    t.expectContains(currentFailure.getState("system-target-status").message, "current")
    currentCheck.refresh()
    t.expectEqual(#currentFailure.commands, 2)

    local evalFailure = fakeNoctalia.new()
    local evalCheck = workflow(evalFailure, FLAKE_DIR, configured())
    evalCheck.initialize()
    evalFailure.queueStartResult(false)
    evalFailure.complete(1, result({ stdout = CURRENT_PATH }))
    t.expectEqual(evalFailure.getState("system-target-status").state, "error")
    t.expectContains(evalFailure.getState("system-target-status").message, "evaluation")
    evalCheck.refresh()
    t.expectEqual(#evalFailure.commands, 3)
end)

t.test("system target reruns after configuration changes during current resolution", function()
    local fake = fakeNoctalia.new()
    local check = workflow(fake, FLAKE_DIR, configured("vm"))
    check.initialize()
    check.configure("/new/flake", configured("workstation"))

    fake.complete(1, result({ stdout = CURRENT_PATH }))
    t.expectEqual(#fake.commands, 2)
    expectCurrentCommand(fake.commands[2])
    t.expectEqual(fake.getState("system-target-status").state, "checking")

    fake.complete(2, result({ stdout = CURRENT_PATH }))
    expectEvaluationCommand(fake.commands[3], "/new/flake", "workstation")
end)

t.test("system target reruns after configuration changes during evaluation", function()
    local fake = fakeNoctalia.new()
    local check = workflow(fake, FLAKE_DIR, configured("vm"))
    check.initialize()
    fake.complete(1, result({ stdout = CURRENT_PATH }))
    check.configure("/new/flake", configured("workstation"))

    fake.complete(2, result({ stdout = TARGET_PATH }))
    t.expectEqual(#fake.commands, 3)
    expectCurrentCommand(fake.commands[3])
    t.expectEqual(fake.getState("system-target-status").state, "checking")
end)

t.test("system target tick waits fifteen minutes while manual refresh is immediate", function()
    local fake = fakeNoctalia.new()
    local check = workflow(fake, FLAKE_DIR, configured())
    check.initialize()
    fake.complete(1, result({ stdout = CURRENT_PATH }))
    fake.complete(2, result({ stdout = CURRENT_PATH }))

    fake.advanceTime(15 * 60 * 1000 - 1)
    check.tick()
    t.expectEqual(#fake.commands, 2)
    fake.advanceTime(1)
    check.tick()
    t.expectEqual(#fake.commands, 3)

    fake.complete(3, result({ stdout = CURRENT_PATH }))
    fake.complete(4, result({ stdout = CURRENT_PATH }))
    check.refresh()
    t.expectEqual(#fake.commands, 5)
end)

return true
