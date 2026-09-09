local config = require("../lib/config")
local t = require("./testlib")

local function load(value, expandPath, nixosConfiguration)
    return config.load({
        getConfig = function(key)
            if key == "flake_dir" then
                return value
            elseif key == "nixos_configuration" then
                return nixosConfiguration
            end
            error("Unexpected config key: " .. tostring(key))
        end,
        expandPath = expandPath or function(path)
            return path
        end,
    })
end

local function expectUnconfigured(value)
    local result = load(value, function(_)
        error("Unconfigured values must not be expanded")
    end)
    t.expectEqual(result.state, "unconfigured")
    t.expectNil(result.flakeDir)
    t.expectContains(result.message, "Configure a flake directory")
    t.expectEqual(result.systemTarget.state, "disabled")
end

t.test("config requires a missing flake directory to be configured", function()
    expectUnconfigured(nil)
end)

t.test("config rejects non-string flake directories", function()
    local invalidValues: { any } = { false, true, 42, {}, { "/etc/nixos" } }
    for _, value in ipairs(invalidValues) do
        expectUnconfigured(value)
    end
end)

t.test("config rejects empty and whitespace-only flake directories", function()
    expectUnconfigured("")
    expectUnconfigured(" \t\n ")
end)

t.test("config accepts an absolute flake directory", function()
    local result = load("/etc/nixos")
    t.expectEqual(result.state, "configured")
    t.expectEqual(result.flakeDir, "/etc/nixos")
end)

t.test("config trims surrounding whitespace and preserves spaces within paths", function()
    local result = load(" \t/home/test/Nix Config \n", function(path)
        t.expectEqual(path, "/home/test/Nix Config")
        return path
    end)
    t.expectEqual(result.flakeDir, "/home/test/Nix Config")
end)

t.test("config delegates tilde expansion to the host", function()
    local result = load("~/nixos", function(path)
        t.expectEqual(path, "~/nixos")
        return "/home/test/nixos"
    end)
    t.expectEqual(result.state, "configured")
    t.expectEqual(result.flakeDir, "/home/test/nixos")
end)

t.test("config disables system target monitoring when its name is missing or blank", function()
    t.expectEqual(load("/etc/nixos").systemTarget.state, "disabled")
    t.expectEqual(load("/etc/nixos", nil, " \t\n ").systemTarget.state, "disabled")
end)

t.test("config trims and accepts simple NixOS configuration names", function()
    for _, name in ipairs({ "vm", "workstation-x1", "_test", "host_2" }) do
        local result = load("/etc/nixos", nil, "  " .. name .. "  ")
        t.expectEqual(result.systemTarget.state, "configured")
        t.expectEqual(result.systemTarget.configuration, name)
    end
end)

t.test("config reports invalid NixOS configuration values", function()
    local invalidValues: { any } = { false, 42, {}, "9host", "work station", "host.prod", "host/path" }
    for _, value in ipairs(invalidValues) do
        local result = load("/etc/nixos", nil, value)
        t.expectEqual(result.systemTarget.state, "invalid")
        t.expectContains(result.systemTarget.message, "NixOS configuration name")
    end
end)

t.test("system target configuration remains available without a flake directory", function()
    local result = load("", nil, "vm")
    t.expectEqual(result.state, "unconfigured")
    t.expectEqual(result.systemTarget.state, "configured")
    t.expectEqual(result.systemTarget.configuration, "vm")
end)

return true
