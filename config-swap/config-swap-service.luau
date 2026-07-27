noctalia.mkdirAll("~/Config-Swap")


type data = {
    settingsPath: string
}

local dataInsert: data = {
    settingsPath = ""
}

local dir = noctalia.pluginDataDir()
local path = dir .. "/data.json"

if not noctalia.fileExists(path) then
    noctalia.writeFile(path, noctalia.json.encode(dataInsert))
end