local currentSubmap = ""

local function socketPath()
    local sig = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
    if sig == nil or runtimeDir == nil then
        return nil
    end
    return `{runtimeDir}/hypr/{sig}/.socket2.sock`
end

local function render()
    local hideWhenDefault = noctalia.getConfig("hide_when_default")
    local prefix = noctalia.getConfig("prefix")
    local glyph = noctalia.getConfig("glyph")

    if glyph and glyph ~= "" then
        barWidget.setGlyph(glyph)
    end

    if currentSubmap == "" or currentSubmap == "default" then
        if hideWhenDefault then
            barWidget.setVisible(false)
            return
        end
        barWidget.setVisible(true)
        barWidget.setText(`{prefix}default`)
        return
    end

    barWidget.setVisible(true)
    barWidget.setText(`{prefix}{currentSubmap}`)
end

local sock = socketPath()
if sock ~= nil then
    noctalia.runAsync("hyprctl submap", function(result)
        if result.exitCode == 0 then
            currentSubmap = noctalia.string.trim(result.stdout)
            render()
        end
    end)
    local started = noctalia.runStream(`stdbuf -oL -eL socat -u UNIX-CONNECT:{sock} -`, function(line)
        local match = line:match("submap>>(.*)")
        if match ~= nil then
            currentSubmap = noctalia.string.trim(match)
            render()
        end
    end)
    if not started then
        noctalia.log("could not start the Hyprland event stream")
    end
else
    noctalia.log("HYPRLAND_INSTANCE_SIGNATURE or XDG_RUNTIME_DIR is not set")
end

function update()
    render()
end

function onClick()
    noctalia.runAsync("hyprctl dispatch 'hl.dsp.submap(\"reset\")' ")
end
