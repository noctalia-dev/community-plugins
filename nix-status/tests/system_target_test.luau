local systemTarget = require("../lib/system_target")
local t = require("./testlib")

local CURRENT_PATH = "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-vm-current"
local TARGET_PATH = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-vm-target"

local function result(fields)
    local value = {
        exitCode = 0,
        stdout = "",
        stderr = "",
        timedOut = false,
    }
    for key, field in pairs(fields or {}) do
        value[key] = field
    end
    return value
end

local function resolve(currentFields, targetFields)
    return systemTarget.resolve(result(currentFields), result(targetFields))
end

t.test("system target reports current when evaluated and active paths match", function()
    local status = resolve(
        { stdout = "  " .. CURRENT_PATH .. "\n" },
        { stdout = CURRENT_PATH }
    )
    t.expectEqual(status.state, "current")
    t.expectEqual(status.currentPath, CURRENT_PATH)
    t.expectEqual(status.targetPath, CURRENT_PATH)
end)

t.test("system target reports different when evaluated path changed", function()
    local status = resolve(
        { stdout = CURRENT_PATH .. "\n" },
        { stdout = TARGET_PATH .. "\n" }
    )
    t.expectEqual(status.state, "different")
    t.expectEqual(status.currentPath, CURRENT_PATH)
    t.expectEqual(status.targetPath, TARGET_PATH)
end)

t.test("system target rejects blank malformed and multiline current paths", function()
    for _, output in ipairs({ "", "not-a-store-path", CURRENT_PATH .. "\n" .. TARGET_PATH }) do
        local status = resolve({ stdout = output }, { stdout = TARGET_PATH })
        t.expectEqual(status.state, "error")
        t.expectEqual(status.message, "Current NixOS system did not resolve to one Nix store path")
    end
end)

t.test("system target rejects blank malformed and multiline evaluated paths", function()
    for _, output in ipairs({ "", "/tmp/system", TARGET_PATH .. "\n" .. CURRENT_PATH }) do
        local status = resolve({ stdout = CURRENT_PATH }, { stdout = output })
        t.expectEqual(status.state, "error")
        t.expectEqual(status.message, "Configured NixOS system did not evaluate to one Nix store path")
    end
end)

t.test("system target reports current command timeout before target errors", function()
    local status = resolve(
        { timedOut = true },
        { exitCode = 1, stderr = "target failure" }
    )
    t.expectEqual(status.state, "error")
    t.expectEqual(status.message, "Timed out while resolving the current NixOS system")
end)

t.test("system target reports evaluation timeout", function()
    local status = resolve(
        { stdout = CURRENT_PATH },
        { timedOut = true }
    )
    t.expectEqual(status.state, "error")
    t.expectEqual(status.message, "Timed out while evaluating the configured NixOS system")
end)

t.test("system target command errors prefer stderr then stdout then fallback", function()
    local currentStderr = resolve(
        { exitCode = 1, stderr = "  current stderr  \n", stdout = "current stdout" },
        { stdout = TARGET_PATH }
    )
    t.expectEqual(currentStderr.message, "current stderr")

    local currentStdout = resolve(
        { exitCode = 1, stdout = "  current stdout  \n" },
        { stdout = TARGET_PATH }
    )
    t.expectEqual(currentStdout.message, "current stdout")

    local currentFallback = resolve(
        { exitCode = 1 },
        { stdout = TARGET_PATH }
    )
    t.expectEqual(currentFallback.message, "Could not resolve the current NixOS system")

    local targetStderr = resolve(
        { stdout = CURRENT_PATH },
        { exitCode = 1, stderr = "  eval stderr  \n", stdout = "eval stdout" }
    )
    t.expectEqual(targetStderr.message, "eval stderr")

    local targetStdout = resolve(
        { stdout = CURRENT_PATH },
        { exitCode = 1, stdout = "  eval stdout  \n" }
    )
    t.expectEqual(targetStdout.message, "eval stdout")

    local targetFallback = resolve(
        { stdout = CURRENT_PATH },
        { exitCode = 1 }
    )
    t.expectEqual(targetFallback.message, "Could not evaluate the configured NixOS system")
end)

return true
