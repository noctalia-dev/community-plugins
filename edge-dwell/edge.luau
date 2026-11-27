--!nonstrict
return function(direction)
    local deadline

    local function onEdgeHover(state)
        deadline = if state == "true" then os.clock() + 0.5 else nil
        noctalia.setUpdateInterval(if deadline then 50 else 10000)
    end

    noctalia.setUpdateInterval(10000)
    layer.render(ui.column({ flexGrow = 1, onHover = onEdgeHover }, {}))

    return function()
        if not deadline or os.clock() < deadline then
            return
        end
        deadline = nil
        noctalia.setUpdateInterval(10000)
        local output = layer.outputName()
        noctalia.runAsync({ "niri", "msg", "-j", "focused-output" }, function(result)
            local focused = if result.exitCode == 0 then noctalia.json.decode(result.stdout) else nil
            if type(focused) == "table" and focused.name == output then
                noctalia.runAsync({ "niri", "msg", "action", "focus-column-" .. direction })
            end
        end)
    end
end
