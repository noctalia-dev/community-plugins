--!nonstrict
-- Dropover bar widget for Noctalia
local STATE_KEY = "dropover_count"
local PANEL_ID = "pyrider3/dropover:dropover-panel"

local function getShelfFilePath()
    if noctalia.pluginDataDir then
        local dataDir = noctalia.pluginDataDir()
        if dataDir and dataDir ~= "" then
            return dataDir .. "/shelf.json"
        end
    end
    local standardPath = noctalia.expandPath("~/.local/state/noctalia/plugins/data/pyrider3/dropover/shelf.json")
    if noctalia.fileExists(standardPath) then
        return standardPath
    end
    local dir = noctalia.pluginDir() or "~/.config/noctalia/plugins/dropover"
    return noctalia.expandPath(dir) .. "/shelf.json"
end

local function refreshCount(count)
    if count == nil then
        local raw = noctalia.readFile(getShelfFilePath())
        if raw then
            local data = noctalia.json.decode(raw)
            if type(data) == "table" then
                count = #data
            else
                count = 0
            end
        else
            count = 0
        end
    end

    if count > 0 then
        barWidget.setGlyph("archive")
        barWidget.setText(tostring(count))
        barWidget.setColor("primary")
        barWidget.setTooltip("Dropover: " .. tostring(count) .. " 个暂存文件 (点击展开)")
    else
        barWidget.setGlyph("inbox")
        barWidget.setText("")
        barWidget.setColor("on_surface")
        barWidget.setTooltip("Dropover 暂存架 (空)")
    end
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function update()
    refreshCount(nil)
end

noctalia.setUpdateInterval(1500)
noctalia.state.watch(STATE_KEY, refreshCount)
refreshCount(nil)
