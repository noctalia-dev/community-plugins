--!nonstrict

local M = {}

local function configPath()
    local config = noctalia.getenv("XDG_CONFIG_HOME")
    if not config or config == "" or config:sub(1, 1) ~= "/" then
        config = noctalia.expandPath("~/.config")
    end
    return config .. "/obsidian/obsidian.json"
end

local function encode(value)
    return (value:gsub("([^%w%-%.%_%~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function M.onQuery(query, showHint)
    local raw = noctalia.readFile(configPath())
    local data = raw and noctalia.json.decode(raw)
    local vaults = type(data) == "table" and data.vaults or nil
    local filter = noctalia.string.trim(query)
    local results = {}

    if type(vaults) == "table" then
        for id, vault in pairs(vaults) do
            if type(id) == "string" and id ~= "" and type(vault) == "table" and type(vault.path) == "string" and vault.path ~= "" then
                local path = vault.path:gsub("/+$", "")
                local name = path:match("([^/]+)$") or path
                local score = filter == "" and 0 or noctalia.fuzzyScore(filter, name)
                if score == nil then
                    score = noctalia.fuzzyScore(filter, path)
                end
                if score ~= nil then
                    table.insert(results, { id = id, title = name, subtitle = path, glyph = "book", score = score })
                end
            end
        end
    end

    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.title ~= b.title then return a.title:lower() < b.title:lower() end
        return a.subtitle < b.subtitle
    end)
    if #results == 0 and showHint then
        table.insert(results, {
            id = "",
            title = noctalia.tr("no_vaults"),
            subtitle = noctalia.tr("no_vaults_hint"),
            glyph = "folder-x",
        })
    end
    launcher.setResults(query, results)
end

function M.onActivate(id)
    if type(id) ~= "string" or id == "" then return end
    local started = noctalia.runAsync({ "xdg-open", "obsidian://open?vault=" .. encode(id) })
    if not started then
        noctalia.notifyError(noctalia.tr("open_failed"), noctalia.tr("open_failed_hint"))
    end
end

return M
