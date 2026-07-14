-- Helper functions

function tr(key)
    return noctalia.tr(key)
end

function cfg(key)
    return noctalia.getConfig(key)
end

function getState(key)
    return noctalia.state.get(key)
end

function setState(key, val)
    noctalia.state.set(key, val)
end

function watchState(key, cb)
    noctalia.state.watch(key, cb)
end

local function labelBox(subtext, text, glyph)
    return ui.column({
        fill = "surface/0.7",
        flexGrow = 1,
        height = 100,
        radius = 8,
        align = "center",
        padding = 12,
        justify = "space_between"
    }, {
        ui.glyph({
            name = glyph,
            size = 30
        }),
        ui.label({
            text = text,
            fontWeight = "bold"
        }),
        ui.label({
            text = subtext,
            fontSize = 12,
            fontWeight = "medium"
        }),
    })
end

local function statLabel(text, glyph: string?)
    local items = {}
    if glyph ~= nil then
        table.insert(items, ui.glyph({
            name = glyph,
            size = 20
        }))
    end

    table.insert(items, ui.label({
        text = text,
        fontSize = 12,
        fontWeight = "semibold"
    }))

    return ui.row({
        gap = 8,
        align = "center"
    }, items)
end

local function render()
    local firstBtn

    if getState("isRemoteCheckRunning") then
        firstBtn = ui.button({
            text = tr("panel.cancel"),
            glyph = "cancel",
            flexGrow = 1,
            variant = "destructive",
            onClick = "onCancelClicked",
        })
    else
        if getState("isUpdateAvailable") then
            firstBtn = ui.button({
                text = tr("panel.update"),
                glyph = "progress-down",
                flexGrow = 1,
                variant = "primary",
                onClick = "onUpdateClicked",
            })
        else
            firstBtn = ui.button({
                text = tr("panel.check"),
                glyph = "search",
                flexGrow = 1,
                variant = "outline",
                onClick = "onCheckClicked",
            })
        end
    end

    local lastCheckTimeStr = getState("lastRemoteCheckTimeStr")
    local generationItems = {
        statLabel(`SYS: {getState("nixosGenerations")}`, "device-desktop"),
        statLabel(`{tr("panel.current")}: {getState("nixosCurrentGen")}`, "device-desktop-check")
    }

    if getState("hasHomeManager") then
        table.insert(generationItems,
            statLabel(`HM: {getState("hmGenerations")}`, "home")
        )

        table.insert(generationItems,
            statLabel(`{tr("panel.current")}: {getState("hmCurrentGen")}`, "home-check")
        )
    end

    panel.render(
        ui.column({
            gap = 8,
        }, {
            ui.row({
                justify = "space_between",
                align = "center"
            }, {
                ui.label({
                    text = tr("panel.title"),
                    fontSize = 20,
                }),

                ui.label({
                    text = cfg("branch"),
                    fontSize = 14,
                }),
            }),
            ui.separator({
                thickness = 2,
                orientation = "horizontal",
                spacing = 4
            }),
            ui.row({
                gap = 8,
                align = "center",
                justify = "space_between"
            }, {
                labelBox(tr("panel.local"), getState("localHash"), "devices-pc"),
                labelBox(tr("panel.remote"), getState("remoteHash"), "world"),
            }),
            ui.separator({
                thickness = 2,
                orientation = "horizontal",
                spacing = 4
            }),
            ui.row({
                fill = "surface/0.7",
                align = "center",
                justify = "space_between",
                flexGrow = 1,
                paddingV = 4,
                paddingH = 8,
                radius = 8,
            }, generationItems),
            ui.row({
                fill = "surface/0.7",
                align = "center",
                justify = "center",
                flexGrow = 1,
                paddingV = 4,
                paddingH = 8,
                radius = 8,
            }, {
                statLabel(`{tr("panel.store_size")}: {getState("storeSize")}`, "database"),
                ui.spacer({width = 16}),
                statLabel(`{tr("panel.closure_size")}: {getState("closureSize")}`, "server"),
            }),
            ui.separator({
                thickness = 2,
                orientation = "horizontal",
                spacing = 4
            }),
            ui.label({
                text = `{tr("panel.last_checked")}: {lastCheckTimeStr}`
            }),
            ui.row({
                gap = 8,
                align = "center",
                justify = "space_between"
            }, {
                firstBtn,
                ui.button({
                    text = tr("panel.clean"),
                    glyph = "trash",
                    flexGrow = 1,
                    variant = "destructive",
                    onClick = "onCleanClicked",
                }),
            })
        })
    )
end

-- State watcher
watchState("isRemoteCheckRunning", render)
watchState("lastRemoteCheckTimeStr", render)
watchState("localHash", render)
watchState("remoteHash", render)

-- Hooks
function onOpen(_ctx)
    render()
end

function update()
    render()
end

-- Click handler
function onCheckClicked()
    setState("command", "check")
end

function onCancelClicked()
    setState("command", "cancel")
end

function onUpdateClicked()
    command = cfg("update_command")
    if command == "" then
        noctalia.notifyError(tr("notification.update_command_is_empty"))
        return
    end

    if cfg("close_on_enter") then
        command = `{command} && echo && read -p "{tr("terminal.press_enter_to_exit")}"`
    end

    panel.close()
    noctalia.runInTerminal(command)
end

function onCleanClicked()
    command = cfg("clean_command")
    if command == "" then
        noctalia.notifyError(tr("notification.clean_command_is_empty"))
        return
    end

    if cfg("close_on_enter") then
        command = `{command} && echo && read -p "{tr("terminal.press_enter_to_exit")}"`
    end

    panel.close()
    noctalia.runInTerminal(command)
end
