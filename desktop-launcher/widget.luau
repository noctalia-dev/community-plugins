-- https://github.com/noctalia-dev/noctalia/blob/main/src/system/desktop_entry_launch.cpp#L45
local function stripFieldCodes(exec)
    local result = exec:gsub("%%(.?)( ?)", function(nextChar, trailingSpace)
        if nextChar:match("[fFuUdDnNick]") then
            return ""
        elseif nextChar == "%" then
            return "%" .. trailingSpace
        else
            return "%" .. nextChar .. trailingSpace
        end
    end)

    result = result:gsub(" +$", "")

    -- Flatpak
    result = result:gsub("@@u *@@", "")

    return result
end

local function getContent(appid)
    local paths = {
        "~/.local/share/applications/",
        "~/.local/share/flatpak/exports/share/applications/",
        "/usr/local/share/applications/",
        "/usr/share/applications/",
        "/var/lib/flatpak/exports/share/applications/",
    }

    for _, path in ipairs(paths) do
        local content = noctalia.readFile(path .. appid .. ".desktop")
        if content then
            return content
        end
    end

    return nil
end

local function getKeyContent(content, key)
    return content:match("[\r\n]" .. key .. "=([^\r\n]*)")
end

local function parse(appid)
    local content = getContent(appid)
    if not content then
        return nil
    end

    local data = {}

    local name = getKeyContent(content, "Name")
    if name then
        data.name = name
    end

    local exec = getKeyContent(content, "Exec")
    if exec then
        data.exec = stripFieldCodes(exec)
    end

    local terminal = getKeyContent(content, "Terminal")
    if terminal then
        data.terminal = terminal == "true"
    end

    return data
end

local function getApps()
    local apps = noctalia.getConfig("apps")
    local appsTable = {}

    for _, app in ipairs(apps) do
        local data = parse(app)
        if not data then
            noctalia.log("desktop-launcher: invalid desktop entry, skipping " .. app)
            continue
        end

        table.insert(appsTable,
            ui.column({
                fill = "surface",
                padding = 8,
                radius = 12,
                align = "center",
                minWidth = 100,
                justify = "space_between",
                gap = 4,
                onClick = function() launchApp(data.exec, data.terminal) end
            }, {
                    ui.image({
                        path = noctalia.appIconPath(app),
                        width = 60,
                        height = 60,
                    }),
                    ui.label({
                        text = data.name,
                        fontWeight = "heavy",
                        maxWidth = 84,
                        maxLines = 1,
                        fontSize = 14,
                    })
                })
        )
    end

    return appsTable
end

local function render()
    desktopWidget.render(ui.row({ gap = 8 },
        getApps()
    ))
end

function launchApp(exec, terminal)
    if terminal then
        noctalia.runInTerminal(exec)
    else
        noctalia.runAsync(exec)
    end
end

render()
