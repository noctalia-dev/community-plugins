-- panel.luau -- Audio Switcher: per-app audio routing

local audioData = nil
local panelOpen = false

local function tr(key, fallback)
    local v = noctalia.tr(key)
    if v == nil or v == key then return fallback or key end
    return v
end

local function getFriendlyName(sinkName)
    if not sinkName then return "?" end
    if sinkName:match("bluez") then return "Bluetooth" end
    if sinkName:match("hdmi") then return "HDMI" end
    if sinkName:match("iec958") then return "Digital" end
    local brand = sinkName:match("usb%-([^_]+)")
    if brand then
        local upper = brand:upper()
        local model = sinkName:match("usb%-" .. brand .. "_" .. upper .. "_([^_]+)")
        if model then return brand .. " " .. model end
        return brand
    end
    if sinkName:match("analog%-stereo") then return "Analogico" end
    return sinkName:sub(1, 30)
end

local function getSinkIcon(name)
    if not name then return "speakerphone" end
    if name:match("bluez") then return "bluetooth" end
    if name:match("hdmi") then return "device-desktop" end
    if name:match("iec958") then return "volume" end
    if name:match("usb") then return "headphones" end
    return "speakerphone"
end

local function getStreamIcon(appName)
    if not appName then return "app-window" end
    if appName:match("Firefox") then return "brand-firefox" end
    if appName:match("Chromium") or appName:match("Chrome") then return "brand-chrome" end
    if appName:match("Telegram") then return "brand-telegram" end
    if appName:match("Spotify") then return "brand-spotify" end
    if appName:match("mpv") then return "player-play" end
    if appName:match("Discord") then return "brand-discord" end
    return "app-window"
end

local function doMoveSinkInput(streamId, sinkId)
    noctalia.runAsync("pactl move-sink-input " .. tostring(streamId) .. " " .. tostring(sinkId), function()
        noctalia.runAsync("pactl list sink-inputs 2>/dev/null", function(result)
            if result.exitCode == 0 and result.stdout then
                local newStreams = {}
                local curId, curSink, curName = nil, nil, nil
                for line in result.stdout:gmatch("[^\n]*") do
                    local id = line:match("^Sink Input #(%d+)")
                    if id then
                        if curId and curName then
                            table.insert(newStreams, { id = curId, name = curName, sink = curSink or 0 })
                        end
                        curId = tonumber(id)
                        curName = nil
                        curSink = nil
                    end
                    local snk = line:match("^%s+Sink: (%d+)")
                    if snk and curId then curSink = tonumber(snk) end
                    local app = line:match('application.name = "(.+)"')
                    if app and curId then curName = app end
                end
                if curId and curName then
                    table.insert(newStreams, { id = curId, name = curName, sink = curSink or 0 })
                end
                if audioData then audioData.streams = newStreams end
            end
            render()
        end)
    end)
end

function onR_1_1() if audioData and audioData.streams[1] and audioData.sinks[1] then doMoveSinkInput(audioData.streams[1].id, audioData.sinks[1].id) end end
function onR_1_2() if audioData and audioData.streams[1] and audioData.sinks[2] then doMoveSinkInput(audioData.streams[1].id, audioData.sinks[2].id) end end
function onR_1_3() if audioData and audioData.streams[1] and audioData.sinks[3] then doMoveSinkInput(audioData.streams[1].id, audioData.sinks[3].id) end end
function onR_1_4() if audioData and audioData.streams[1] and audioData.sinks[4] then doMoveSinkInput(audioData.streams[1].id, audioData.sinks[4].id) end end
function onR_1_5() if audioData and audioData.streams[1] and audioData.sinks[5] then doMoveSinkInput(audioData.streams[1].id, audioData.sinks[5].id) end end

function onR_2_1() if audioData and audioData.streams[2] and audioData.sinks[1] then doMoveSinkInput(audioData.streams[2].id, audioData.sinks[1].id) end end
function onR_2_2() if audioData and audioData.streams[2] and audioData.sinks[2] then doMoveSinkInput(audioData.streams[2].id, audioData.sinks[2].id) end end
function onR_2_3() if audioData and audioData.streams[2] and audioData.sinks[3] then doMoveSinkInput(audioData.streams[2].id, audioData.sinks[3].id) end end
function onR_2_4() if audioData and audioData.streams[2] and audioData.sinks[4] then doMoveSinkInput(audioData.streams[2].id, audioData.sinks[4].id) end end
function onR_2_5() if audioData and audioData.streams[2] and audioData.sinks[5] then doMoveSinkInput(audioData.streams[2].id, audioData.sinks[5].id) end end

function onR_3_1() if audioData and audioData.streams[3] and audioData.sinks[1] then doMoveSinkInput(audioData.streams[3].id, audioData.sinks[1].id) end end
function onR_3_2() if audioData and audioData.streams[3] and audioData.sinks[2] then doMoveSinkInput(audioData.streams[3].id, audioData.sinks[2].id) end end
function onR_3_3() if audioData and audioData.streams[3] and audioData.sinks[3] then doMoveSinkInput(audioData.streams[3].id, audioData.sinks[3].id) end end
function onR_3_4() if audioData and audioData.streams[3] and audioData.sinks[4] then doMoveSinkInput(audioData.streams[3].id, audioData.sinks[4].id) end end
function onR_3_5() if audioData and audioData.streams[3] and audioData.sinks[5] then doMoveSinkInput(audioData.streams[3].id, audioData.sinks[5].id) end end

function onR_4_1() if audioData and audioData.streams[4] and audioData.sinks[1] then doMoveSinkInput(audioData.streams[4].id, audioData.sinks[1].id) end end
function onR_4_2() if audioData and audioData.streams[4] and audioData.sinks[2] then doMoveSinkInput(audioData.streams[4].id, audioData.sinks[2].id) end end
function onR_4_3() if audioData and audioData.streams[4] and audioData.sinks[3] then doMoveSinkInput(audioData.streams[4].id, audioData.sinks[3].id) end end
function onR_4_4() if audioData and audioData.streams[4] and audioData.sinks[4] then doMoveSinkInput(audioData.streams[4].id, audioData.sinks[4].id) end end
function onR_4_5() if audioData and audioData.streams[4] and audioData.sinks[5] then doMoveSinkInput(audioData.streams[4].id, audioData.sinks[5].id) end end

function onR_5_1() if audioData and audioData.streams[5] and audioData.sinks[1] then doMoveSinkInput(audioData.streams[5].id, audioData.sinks[1].id) end end
function onR_5_2() if audioData and audioData.streams[5] and audioData.sinks[2] then doMoveSinkInput(audioData.streams[5].id, audioData.sinks[2].id) end end
function onR_5_3() if audioData and audioData.streams[5] and audioData.sinks[3] then doMoveSinkInput(audioData.streams[5].id, audioData.sinks[3].id) end end
function onR_5_4() if audioData and audioData.streams[5] and audioData.sinks[4] then doMoveSinkInput(audioData.streams[5].id, audioData.sinks[4].id) end end
function onR_5_5() if audioData and audioData.streams[5] and audioData.sinks[5] then doMoveSinkInput(audioData.streams[5].id, audioData.sinks[5].id) end end

function onR_6_1() if audioData and audioData.streams[6] and audioData.sinks[1] then doMoveSinkInput(audioData.streams[6].id, audioData.sinks[1].id) end end
function onR_6_2() if audioData and audioData.streams[6] and audioData.sinks[2] then doMoveSinkInput(audioData.streams[6].id, audioData.sinks[2].id) end end
function onR_6_3() if audioData and audioData.streams[6] and audioData.sinks[3] then doMoveSinkInput(audioData.streams[6].id, audioData.sinks[3].id) end end
function onR_6_4() if audioData and audioData.streams[6] and audioData.sinks[4] then doMoveSinkInput(audioData.streams[6].id, audioData.sinks[4].id) end end
function onR_6_5() if audioData and audioData.streams[6] and audioData.sinks[5] then doMoveSinkInput(audioData.streams[6].id, audioData.sinks[5].id) end end

function render()
    local body = {}

    if not audioData or not audioData.streams or #audioData.streams == 0 then
        table.insert(body, ui.column({ align = "center", justify = "center", flexGrow = 1, padding = 30 }, {
            ui.glyph({ name = "speaker-off", size = 28, color = "secondary" }),
            ui.label({ text = tr("panel.noStreams", "Nenhum audio tocando"), fontSize = 14, color = "on_surface/0.6" }),
        }))
    else
        for i, stream in ipairs(audioData.streams) do
            local sinkLabel = "?"
            local sinkIcon = "speakerphone"
            if audioData.sinks then
                for _, s in ipairs(audioData.sinks) do
                    if s.id == stream.sink then
                        sinkLabel = getFriendlyName(s.name)
                        sinkIcon = getSinkIcon(s.name)
                        break
                    end
                end
            end
            local appIcon = getStreamIcon(stream.name)

            table.insert(body, ui.column({ gap = 4, paddingH = 8, paddingV = 8, fill = "surface_variant", radius = 8 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = appIcon, size = 18, color = "primary" }),
                    ui.label({ text = stream.name, fontSize = 14, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
                }),
                ui.row({ gap = 4, align = "center" }, {
                    ui.glyph({ name = sinkIcon, size = 12, color = "on_surface/0.5" }),
                    ui.label({ text = sinkLabel, fontSize = 11, color = "on_surface/0.5", flexGrow = 1 }),
                }),
            }))

            if audioData.sinks then
                local sinkButtons = {}
                for j, sink in ipairs(audioData.sinks) do
                    if j <= 5 then
                        local isSelected = (stream.sink == sink.id)
                        local variant = isSelected and "default" or "outline"
                        local icon = getSinkIcon(sink.name)
                        local label = getFriendlyName(sink.name)
                        local cb = "onR_" .. i .. "_" .. j
                        table.insert(sinkButtons, ui.button({
                            text = label,
                            glyph = icon,
                            variant = variant,
                            controlSize = "sm",
                            onClick = cb,
                        }))
                    end
                end
                table.insert(body, ui.column({ gap = 4, paddingH = 8 }, {
                    ui.row({ gap = 4, wrap = true }, sinkButtons),
                }))
            end

            table.insert(body, ui.separator({ padding = 0 }))
        end
    end

    panel.render(ui.column({ flexGrow = 1, gap = 6, padding = 12, fill = "surface", radius = 12 }, {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "speakerphone", size = 18, color = "primary" }),
            ui.label({ text = tr("panel.title", "Audio Switcher"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", onClick = "onCloseClicked" }),
        }),
        ui.scroll({ flexGrow = 1, gap = 8 }, body),
    }))
end

function onOpen(_context)
    panelOpen = true
    local raw = noctalia.state.get("audio")
    if raw and raw ~= "" then
        local ok, d = pcall(noctalia.json.decode, raw)
        if ok then
            audioData = d
        else
            audioData = nil
        end
    else
        audioData = nil
    end
    render()
end

function onClose()
    panelOpen = false
    audioData = nil
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("audio", function(value)
    if value and value ~= "" then
        local ok, d = pcall(noctalia.json.decode, value)
        if ok then
            audioData = d
        else
            audioData = nil
        end
    else
        audioData = nil
    end
    if panelOpen then render() end
end)
