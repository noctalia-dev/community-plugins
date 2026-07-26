-- service.luau -- Audio Switcher: per-app audio routing

local function parseSinkInputs(text)
    local list = {}
    if not text or text == "" then return list end
    local curId, curSink, curName = nil, nil, nil
    for line in text:gmatch("[^\n]*") do
        local id = line:match("^Sink Input #(%d+)")
        if id then
            if curId and curName then
                table.insert(list, { id = curId, name = curName, sink = curSink or 0 })
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
        table.insert(list, { id = curId, name = curName, sink = curSink or 0 })
    end
    return list
end

local function parseSinksShort(text)
    local list = {}
    if not text or text == "" then return list end
    for line in text:gmatch("[^\n]*") do
        local id, name = line:match("^(%d+)\t([^\t]+)")
        if id and name then
            table.insert(list, {
                id = tonumber(id),
                name = name,
            })
        end
    end
    return list
end

local function refresh()
    noctalia.runAsync("pactl list sink-inputs 2>/dev/null", function(inputResult)
        local streams = {}
        if inputResult.exitCode == 0 and inputResult.stdout and inputResult.stdout ~= "" then
            streams = parseSinkInputs(inputResult.stdout)
        end

        noctalia.runAsync("pactl list sinks short 2>/dev/null", function(sinkResult)
            local sinks = {}
            if sinkResult.exitCode == 0 and sinkResult.stdout and sinkResult.stdout ~= "" then
                sinks = parseSinksShort(sinkResult.stdout)
            end

            noctalia.runAsync("pactl get-default-sink 2>/dev/null", function(defaultResult)
                local defaultSink = ""
                if defaultResult.exitCode == 0 and defaultResult.stdout then
                    defaultSink = defaultResult.stdout:gsub("%s+", "")
                end

                local state = {
                    streams = streams,
                    sinks = sinks,
                    default = defaultSink,
                }
                noctalia.state.set("audio", noctalia.json.encode(state))
            end)
        end)
    end)
end

local interval = noctalia.getConfig("refreshInterval") or 3
noctalia.setUpdateInterval(interval * 1000)

function update()
    refresh()
end

refresh()
