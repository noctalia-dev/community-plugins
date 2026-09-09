local closureCheck = require("./lib/closure_check.luau")
local closureDiff = require("./lib/closure_diff.luau")
local contracts = require("./lib/contracts.luau")
local config = require("./lib/config.luau")
local flakeUpdate = require("./lib/flake_update.luau")
local generationCheck = require("./lib/generation_check.luau")
local nix = require("./lib/nix.luau")
local serviceRuntime = require("./lib/service_runtime.luau")
local systemTarget = require("./lib/system_target.luau")
local systemTargetCheck = require("./lib/system_target_check.luau")

local function runtimeConfig()
    local settings = config.load(noctalia)
    local flakeDir = settings.state == "configured" and settings.flakeDir or nil
    return flakeDir, settings.systemTarget
end

local flakeDir, targetConfig = runtimeConfig()
local runtime = serviceRuntime.start(noctalia, flakeDir, {
    closureCheck = closureCheck,
    closureDiff = closureDiff,
    contracts = contracts,
    flakeUpdate = flakeUpdate,
    generationCheck = generationCheck,
    nix = nix,
    systemTarget = systemTarget,
    systemTargetCheck = systemTargetCheck,
}, targetConfig)

function update()
    runtime.update()
end

function onConfigChanged()
    local nextFlakeDir, nextTargetConfig = runtimeConfig()
    runtime.configure(nextFlakeDir, nextTargetConfig)
end
