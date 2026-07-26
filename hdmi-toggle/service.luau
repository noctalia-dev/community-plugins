-- service.luau -- Monitor Manager: poll niri outputs

local monitors = {}
local monitorCount = 0

local function parseOutputs(text)
    local list = {}
    local currentName = ""
    local currentOn = false
    for line in text:gmatch("[^\n]+") do
        local name = line:match('^Output%s+".+"%s+%(([^)]+)%)%s*$')
        if name then
            if currentName ~= "" then
                table.insert(list, { name = currentName, on = currentOn })
            end
            currentName = name
            currentOn = false
        elseif line:find("Current mode") then
            currentOn = true
        end
    end
    if currentName ~= "" then
        table.insert(list, { name = currentName, on = currentOn })
    end
    return list
end

local function refresh()
    noctalia.runAsync("niri msg outputs", function(result)
        if result.exitCode == 0 and result.stdout ~= "" then
            monitors = parseOutputs(result.stdout)
            monitorCount = #monitors
            local json = noctalia.json.encode(monitors)
            noctalia.state.set("monitors", json)
        end
    end)
end

local interval = noctalia.getConfig("refreshInterval") or 10
noctalia.setUpdateInterval(interval * 1000)

function update()
    refresh()
end

refresh()
