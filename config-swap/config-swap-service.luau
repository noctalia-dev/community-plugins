noctalia.mkdirAll("~/Config-Swap")
local configBox = "~/Config-Swap" 	

type saveCustomPath = {
    value: string
}

local save: saveCustomPath = {
    value = configBox
}


local dir = noctalia.pluginDataDir()
local path = dir .. "/data.json"
if not noctalia.fileExists(path) then
    noctalia.writeFile(path, noctalia.json.encode(save))
end