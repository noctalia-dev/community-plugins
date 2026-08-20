--!strict

-- thumbnail path/ensure/attach helpers.

local const = require("./constants.luau")
local THUMB_DIR = const.THUMB_DIR

local EXPO = {}

function EXPO.get_thumbnail_path(id: string, url: string?, callback: ((string) -> ())?): string?
    if type(id) ~= "string" or id == "" then return nil end
    local safe_id = id:gsub("[^%w%-_]", "_")
    local path = THUMB_DIR .. "/" .. safe_id .. ".jpg"

    if noctalia.fileExists(path) then
        return path
    end

    if type(url) == "string" and url ~= "" then
        noctalia.runAsync("mkdir -p '" .. THUMB_DIR .. "' && curl -s -L -o '" .. path .. "' '" .. url .. "'", function()
            if noctalia.fileExists(path) and callback then
                callback(path)
            end
        end, 10000)
    end

    return nil
end

local known_thumb_files = {}

local function preload_thumb_cache()
    noctalia.runAsync("find /tmp -name 'noctalia-ytmusic-thumb-*.jpg' 2>/dev/null", function(res)
        local out = type(res) == "table" and res.stdout or ""
        for line in out:gmatch("[^\r\n]+") do
            known_thumb_files[line] = true
        end
    end)
end
preload_thumb_cache()

function EXPO.ensure_thumbnails(items, on_updated, tag)
    if type(items) ~= "table" or #items == 0 then return end

    local missing = {}
    local updated_cached = false

    for _, item in ipairs(items) do
        if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
            if not item.thumb_path then
                local safe_id = item.id:gsub("[^%w%-_]", "_")
                local path = THUMB_DIR .. "/" .. safe_id .. ".jpg"
                if known_thumb_files[path] then
                    item.thumb_path = path
                    updated_cached = true
                else
                    local url = (type(item.thumbnail_url) == "string" and item.thumbnail_url ~= "") and item.thumbnail_url or ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg")
                    table.insert(missing, { item = item, path = path, url = url })
                end
            end
        end
    end

    if #missing == 0 then
        if updated_cached and type(on_updated) == "function" then
            on_updated()
        end
        return
    end

    local safe_tag = (type(tag) == "string" and tag ~= "") and tag:gsub("[^%w%-_]", "_") or "batch"
    local configFile = string.format("/tmp/noctalia-ytmusic-thumb-%s.txt", safe_tag)
    local lines = {}
    for _, m in ipairs(missing) do
        table.insert(lines, string.format("output = \"%s\"\nurl = \"%s\"", m.path, m.url))
    end
    noctalia.writeFile(configFile, table.concat(lines, "\n"))

    local script = ([=[
mkdir -p "%s"
if command -v curl >/dev/null 2>&1; then
  curl -s --parallel --parallel-max 16 --parallel-immediate -K "%s" >/dev/null 2>&1
fi
rm -f "%s"
echo "THUMBS_DONE=1"
]=]):format(THUMB_DIR, configFile, configFile)

    noctalia.runAsync(script, function(res)
        local out = (type(res) == "table" and res.stdout) or ""
        if out:find("THUMBS_DONE=1") then
            for _, m in ipairs(missing) do
                known_thumb_files[m.path] = true
                m.item.thumb_path = m.path
            end
            if type(on_updated) == "function" then
                on_updated()
            end
        end
    end, 15000)
end

function EXPO.attach_cached_thumbs(items: { { [string]: any } })
    if type(items) ~= "table" then return end
    local count = #items
    if count > 50 then count = 50 end
    for i = 1, count do
        local item = items[i]
        if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
            local safe_id = item.id:gsub("[^%w%-_]", "_")
            local path = THUMB_DIR .. "/" .. safe_id .. ".jpg"
            if noctalia.fileExists(path) then
                item.thumb_path = path
            end
        end
    end
end

return EXPO