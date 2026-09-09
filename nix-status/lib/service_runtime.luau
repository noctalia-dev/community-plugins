local BOOTED_SYSTEM = "/run/booted-system"
local CURRENT_SYSTEM = "/run/current-system"
local GENERATION_REFRESH_INTERVAL_MS = 60000

local function start(host, flakeDir, dependencies, targetConfig)
    local closureDiff = dependencies.closureDiff
    local stateKeys = dependencies.contracts.state
    local requestKeys = dependencies.contracts.request
    local nix = dependencies.nix
    local generation = dependencies.generationCheck.new(
        host,
        stateKeys.generationStatus,
        BOOTED_SYSTEM,
        CURRENT_SYSTEM
    )
    local closure = dependencies.closureCheck.new(
        host,
        stateKeys.closureDiffStatus,
        BOOTED_SYSTEM,
        CURRENT_SYSTEM,
        closureDiff
    )
    local flake = dependencies.flakeUpdate.new(host, stateKeys.updateStatus, flakeDir, nix)
    local systemTarget = dependencies.systemTargetCheck.new(
        host,
        stateKeys.systemTargetStatus,
        CURRENT_SYSTEM,
        dependencies.systemTarget,
        flakeDir,
        targetConfig or { state = "disabled" }
    )

    -- A retained closure comparison may describe paths from before a switch or reboot.
    -- Clear it on service load and rebuild it after the initial generation check succeeds.
    closure.reset()

    -- Preserve completed update results, but do not retain checks whose callbacks were lost on reload.
    flake.initialize()
    systemTarget.initialize()

    -- Panel buttons send incrementing numbers here whenever clicked.
    host.state.watch(requestKeys.update, function(_)
        flake.update(systemTarget.refresh)
    end)

    host.state.watch(requestKeys.generationRefresh, function(_)
        generation.check()
    end)

    host.state.watch(requestKeys.closureDiff, function(_)
        closure.compare(generation.check)
    end)

    host.state.watch(requestKeys.systemTargetRefresh, function(_)
        systemTarget.refresh()
    end)

    -- Generation state is derived from /run and intentionally rebuilt on every service load.
    generation.check(function()
        closure.compare()
    end)
    host.setUpdateInterval(GENERATION_REFRESH_INTERVAL_MS)

    return {
        update = function()
            generation.check()
            systemTarget.tick()
        end,
        configure = function(path, nextTargetConfig)
            flake.configure(path)
            systemTarget.configure(path, nextTargetConfig or { state = "disabled" })
        end,
    }
end

return {
    start = start,
}
