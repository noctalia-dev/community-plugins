local contracts = require("./lib/contracts.luau")

type UpdateStatus = contracts.UpdateStatus
type GenerationStatus = contracts.GenerationStatus
type ClosureDiffStatus = contracts.ClosureDiffStatus
type SystemTargetStatus = contracts.SystemTargetStatus
type InputChange = contracts.InputChange

local status: UpdateStatus? = nil
local generationStatus: GenerationStatus? = nil
local closureDiffStatus: ClosureDiffStatus? = nil
local systemTargetStatus: SystemTargetStatus? = nil

local function requestCheck()
    local n = noctalia.state.get(contracts.request.update) or 0
    noctalia.state.set(contracts.request.update, n + 1)
end

local function requestGenerationRefresh()
    local n = noctalia.state.get(contracts.request.generationRefresh) or 0
    noctalia.state.set(contracts.request.generationRefresh, n + 1)
end

local function requestClosureDiff()
    local n = noctalia.state.get(contracts.request.closureDiff) or 0
    noctalia.state.set(contracts.request.closureDiff, n + 1)
end

local function requestSystemTargetRefresh()
    local n = noctalia.state.get(contracts.request.systemTargetRefresh) or 0
    noctalia.state.set(contracts.request.systemTargetRefresh, n + 1)
end

local function closureChangeColor(change: contracts.ClosureChange?)
    if change == "increase" then
        return "error"
    elseif change == "decrease" then
        return "tertiary"
    end

    return "on_surface"
end

local function inputChangeText(input: InputChange)
    if input.kind == "added" then
        return "Added · " .. input.newDate, input.newRev
    elseif input.kind == "removed" then
        return "Removed · " .. input.oldDate, input.oldRev
    end

    return input.oldDate .. " → " .. input.newDate, input.oldRev .. " → " .. input.newRev
end

local function render()
    local children = {}
    local isChecking = status ~= nil and status.state == "checking"
    local isGenerationChecking = generationStatus == nil
        or generationStatus.state == "checking"
        or generationStatus.refreshing == true
    local isComparingClosures = closureDiffStatus ~= nil and closureDiffStatus.state == "running"

    table.insert(children, ui.label({
        text = "NixOS Status",
        fontSize = 18,
        fontWeight = "bold",
    }))

    table.insert(children, ui.label({
        text = "System Generation",
        fontWeight = "bold",
    }))

    if generationStatus == nil or generationStatus.state == "checking" then
        table.insert(children, ui.label({
            text = "Checking booted and current generations…",
            color = "on_surface_variant",
        }))
    elseif generationStatus.state == "current" then
        table.insert(children, ui.label({
            text = "Booted generation is current.",
            color = "primary",
        }))
    elseif generationStatus.state == "different" then
        table.insert(children, ui.label({
            text = "↻ Booted generation differs from current.",
            fontWeight = "bold",
            color = "secondary",
        }))
    elseif generationStatus.state == "error" then
        table.insert(children, ui.label({
            text = generationStatus.message or "Generation check failed",
            color = "error",
        }))
    end

    if generationStatus ~= nil and generationStatus.refreshing then
        table.insert(children, ui.label({
            text = "Refreshing…",
            fontSize = 11,
            color = "on_surface_variant",
        }))
    end

    if closureDiffStatus ~= nil and closureDiffStatus.state ~= "idle" then
        local output = closureDiffStatus.state == "ready" and closureDiffStatus.output or ""
        local headerChildren = {
            ui.label({
                text = "Closure Changes",
                fontWeight = "bold",
            }),
        }

        if closureDiffStatus.state == "ready" and output ~= "" then
            table.insert(headerChildren, ui.button({
                text = "Copy",
                controlSize = "sm",
                variant = "ghost",
                onClick = "onCopyClosureDiffClicked",
            }))
        end

        table.insert(children, ui.row({
            align = "center",
            justify = "space_between",
        }, headerChildren))

        if closureDiffStatus.state == "running" then
            table.insert(children, ui.label({
                text = "Comparing booted and current system closures…",
                color = "on_surface_variant",
            }))
        elseif closureDiffStatus.state == "error" then
            table.insert(children, ui.label({
                text = closureDiffStatus.message or "Closure comparison failed",
                color = "error",
            }))
        elseif closureDiffStatus.state == "ready" then
            if output == "" then
                table.insert(children, ui.label({
                    text = "No closure changes reported.",
                    color = "on_surface_variant",
                }))
            else
                local outputChildren = {}
                local lines = closureDiffStatus.lines or {}

                if #lines == 0 then
                    table.insert(outputChildren, ui.markdown({
                        text = "```text\n" .. output .. "\n```",
                    }))
                else
                    for _, line in ipairs(lines) do
                        if line.amount ~= nil then
                            table.insert(outputChildren, ui.row({
                                gap = 4,
                                align = "start",
                                justify = "space_between",
                            }, {
                                ui.label({
                                    text = line.prefix or "",
                                    flexGrow = 1,
                                }),
                                ui.label({
                                    text = line.amount,
                                    color = closureChangeColor(line.change),
                                    fontWeight = line.change ~= nil and "semibold" or "normal",
                                }),
                            }))
                        else
                            table.insert(outputChildren, ui.label({
                                text = line.text or "",
                            }))
                        end
                    end
                end

                table.insert(children, ui.column({
                    gap = 2,
                    padding = 8,
                    fill = "surface_variant",
                    radius = 8,
                }, outputChildren))
            end

            if closureDiffStatus.truncated then
                table.insert(children, ui.label({
                    text = "Output was truncated by Noctalia.",
                    fontSize = 11,
                    color = "error",
                }))
            end
        end
    end

    table.insert(children, ui.row({
        gap = 8,
    }, {
        ui.button({
            text = "Refresh Generation",
            flexGrow = 1,
            variant = "outline",
            enabled = not isGenerationChecking,
            onClick = "onRefreshClicked",
        }),
        ui.button({
            text = isComparingClosures and "Comparing…" or "Compare Closures",
            flexGrow = 1,
            enabled = not isComparingClosures,
            onClick = "onCompareClosuresClicked",
        }),
    }))

    table.insert(children, ui.separator({}))
    table.insert(children, ui.label({
        text = "Configured System",
        fontWeight = "bold",
    }))

    if systemTargetStatus == nil or systemTargetStatus.state == "checking" then
        table.insert(children, ui.label({
            text = "Checking the evaluated NixOS configuration…",
            color = "on_surface_variant",
        }))
    elseif systemTargetStatus.state == "disabled" then
        table.insert(children, ui.label({
            text = systemTargetStatus.message or "Configure a flake directory and NixOS configuration to enable this check.",
            color = "on_surface_variant",
        }))
    elseif systemTargetStatus.state == "current" then
        table.insert(children, ui.label({
            text = "Evaluated configuration is already active.",
            color = "primary",
        }))
    elseif systemTargetStatus.state == "different" then
        table.insert(children, ui.label({
            text = "⇧ Switch available: evaluated configuration differs from the active system.",
            fontWeight = "bold",
            color = "secondary",
        }))
    elseif systemTargetStatus.state == "error" then
        table.insert(children, ui.label({
            text = systemTargetStatus.message,
            color = "error",
        }))
    end

    table.insert(children, ui.button({
        text = systemTargetStatus ~= nil and systemTargetStatus.state == "checking"
            and "Checking…"
            or "Refresh Configuration",
        variant = "outline",
        enabled = systemTargetStatus ~= nil
            and systemTargetStatus.state ~= "checking"
            and systemTargetStatus.state ~= "disabled",
        onClick = "onRefreshSystemTargetClicked",
    }))

    table.insert(children, ui.separator({}))
    table.insert(children, ui.label({
        text = "Flake Inputs",
        fontWeight = "bold",
    }))

    if status == nil or status.state == "idle" then
        table.insert(children, ui.label({
            text = "Run an update to check the flake inputs.",
        }))

    elseif status.state == "unconfigured" then
        table.insert(children, ui.label({
            text = status.message,
            color = "on_surface_variant",
        }))

    elseif status.state == "checking" then
        table.insert(children, ui.label({
            text = "Updating flake inputs…",
        }))

    elseif status.state == "current" then
        table.insert(children, ui.label({
            text = "All inputs are up to date.",
        }))

    elseif status.state == "updates" then
        table.insert(children, ui.label({
            text = "Inputs updated:",
        }))

        for _, input in ipairs(status.changedInputs or {}) do
            local dateText, revisionText = inputChangeText(input)

            table.insert(children, ui.row({
                gap = 16,
                align = "start",
                justify = "space_between",
            }, {
                ui.label({
                    text = input.name,
                    fontWeight = "bold",
                    flexGrow = 1,
                }),

                ui.column({
                    gap = 2,
                    align = "end",
                }, {
                    ui.label({
                        text = dateText,
                        textAlign = "right",
                    }),

                    ui.label({
                        text = revisionText,
                        textAlign = "right",
                        fontSize = 11,
                        color = "on_surface_variant",
                    }),
                }),
            }))
        end

    elseif status.state == "error" then
        table.insert(children, ui.label({
            text = status.message or "Unknown error",
        }))
    end

    table.insert(children, ui.row({
        gap = 8,
    }, {
        ui.button({
            text = "Update Flake Inputs",
            flexGrow = 1,
            enabled = not isChecking and status ~= nil and status.state ~= "unconfigured",
            onClick = "onCheckClicked",
        }),
        ui.button({
            text = "Open Settings",
            flexGrow = 1,
            variant = "outline",
            onClick = "onSettingsClicked",
        }),
    }))


    panel.render(ui.scroll({
        key = "panel-scroll",
        flexGrow = 1,
        gap = 12,
    }, children))
end

function onOpen(_)
    status = noctalia.state.get(contracts.state.updateStatus)
    generationStatus = noctalia.state.get(contracts.state.generationStatus)
    closureDiffStatus = noctalia.state.get(contracts.state.closureDiffStatus)
    systemTargetStatus = noctalia.state.get(contracts.state.systemTargetStatus)
    render()
    requestGenerationRefresh()
end

function onRefreshClicked()
    requestGenerationRefresh()
end

function onCompareClosuresClicked()
    requestClosureDiff()
end

function onRefreshSystemTargetClicked()
    requestSystemTargetRefresh()
end

function onCopyClosureDiffClicked()
    if closureDiffStatus ~= nil and closureDiffStatus.state == "ready" then
        noctalia.copyToClipboard(closureDiffStatus.output, "text/plain")
    end
end

function onCheckClicked()
    requestCheck()
end

function onSettingsClicked()
    noctalia.openSettings()
end

noctalia.state.watch(contracts.state.updateStatus, function(value)
    status = value
    render()
end)

noctalia.state.watch(contracts.state.generationStatus, function(value)
    generationStatus = value
    render()
end)

noctalia.state.watch(contracts.state.closureDiffStatus, function(value)
    closureDiffStatus = value
    render()
end)

noctalia.state.watch(contracts.state.systemTargetStatus, function(value)
    systemTargetStatus = value
    render()
end)
