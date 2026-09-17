local contracts = require("./lib/contracts.luau")
local statusIcon = require("./lib/status_icon.luau")

type UpdateStatus = contracts.UpdateStatus
type GenerationStatus = contracts.GenerationStatus
type SystemTargetStatus = contracts.SystemTargetStatus


local updateStatus: UpdateStatus? = noctalia.state.get(contracts.state.updateStatus)
local generationStatus: GenerationStatus? = noctalia.state.get(contracts.state.generationStatus)
local systemTargetStatus: SystemTargetStatus? = noctalia.state.get(contracts.state.systemTargetStatus)

local function show()
    local updateState = updateStatus and updateStatus.state or "idle"
    local generationState = generationStatus and generationStatus.state or "checking"
    local systemTargetState = systemTargetStatus and systemTargetStatus.state or "checking"

    statusIcon.show(noctalia, barWidget, updateState)

    local markers = {}
    if generationState == "different" then
        table.insert(markers, "↻")
    end
    if systemTargetState == "different" then
        table.insert(markers, "⇧")
    end
    barWidget.setText(table.concat(markers, ""))

    local tooltip = { "NixOS" }

    if generationState == "current" then
        table.insert(tooltip, "booted generation is current")
    elseif generationState == "different" then
        table.insert(tooltip, "booted generation differs")
    elseif generationState == "checking" then
        table.insert(tooltip, "checking generation…")
    elseif generationState == "error" then
        table.insert(tooltip, "generation check failed")
    end

    if systemTargetState == "current" then
        table.insert(tooltip, "configured system is active")
    elseif systemTargetState == "different" then
        table.insert(tooltip, "switch available")
    elseif systemTargetState == "checking" then
        table.insert(tooltip, "checking configured system…")
    elseif systemTargetState == "error" then
        table.insert(tooltip, "configuration check failed")
    elseif systemTargetState == "disabled" then
        table.insert(tooltip, "configuration check not configured")
    end

    if updateState == "current" then
        table.insert(tooltip, "inputs up to date")
    elseif updateState == "updates" then
        table.insert(tooltip, "inputs updated")
    elseif updateState == "unconfigured" then
        table.insert(tooltip, "flake updates not configured")
    elseif updateState == "checking" then
        table.insert(tooltip, "updating inputs…")
    elseif updateState == "error" then
        table.insert(tooltip, "input update failed")
    end

    barWidget.setTooltip(table.concat(tooltip, " · "))
end

function update()
    updateStatus = noctalia.state.get(contracts.state.updateStatus)
    generationStatus = noctalia.state.get(contracts.state.generationStatus)
    systemTargetStatus = noctalia.state.get(contracts.state.systemTargetStatus)
    show()
end

noctalia.state.watch(contracts.state.updateStatus, function(status)
    updateStatus = status
    show()
end)

noctalia.state.watch(contracts.state.generationStatus, function(status)
    generationStatus = status
    show()
end)

noctalia.state.watch(contracts.state.systemTargetStatus, function(status)
    systemTargetStatus = status
    show()
end)

function onClick()
    noctalia.togglePanel("mindnbytes/nix-status:details")
end
