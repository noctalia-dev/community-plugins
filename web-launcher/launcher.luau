local function loadLinks()
    local raw = noctalia.getConfig("links")
    local links = {}

    if type(raw) ~= "table" then
        return links
    end

    for _, line in ipairs(raw) do
        local name, url = line:match("^([^|]+)|(.+)$")
        if name and url then
            name = noctalia.string.trim(name)
            url = noctalia.string.trim(url)
            if url:match("^https?://") then
                table.insert(links, { name = name, url = url })
            else
                noctalia.log("web-launcher: skipped non-http(s) URL: " .. tostring(line))
            end
        else
            noctalia.log("web-launcher: skipped malformed line (expected Name|https://url): " .. tostring(line))
        end
    end

    return links
end

local links = loadLinks()

local function extractDomain(url)
    local domain = url:match("^https?://([^/]+)")
    if domain then
        domain = domain:gsub("^.*@", "")
    end
    return domain
end

local function faviconUrl(domain)
    local provider = noctalia.getConfig("icon_provider")
    local encoded = noctalia.string.urlEncode(domain)

    if provider == "duckduckgo" then
        return "https://icons.duckduckgo.com/ip3/" .. encoded .. ".ico"
    elseif provider == "direct" then
        return "https://" .. domain .. "/favicon.ico"
    else
        return "https://www.google.com/s2/favicons?sz=64&domain=" .. encoded
    end
end

local function faviconCachePath(domain)
    local provider = noctalia.getConfig("icon_provider")

    local dir = noctalia.pluginDir() .. "/cache"
    local safe = domain:gsub("[^%w%.%-]", "_")

    local path = dir .. "/" .. safe .. "_" .. provider .. ".png"
    return path, dir
end

local function downloadFavicon(domain, onDone)
    local path, dir = faviconCachePath(domain)
    if noctalia.fileExists(path) then
        onDone(path)
        return
    end

    noctalia.mkdirAll(dir)
    noctalia.download(faviconUrl(domain), path, function(ok)
        if ok then
            onDone(path)
        end
    end)
end

local function makeResults(text, query)
    local results = {}

    for _, link in ipairs(links) do
        local domain = extractDomain(link.url)
        local iconPath = faviconCachePath(domain)
        local hasIcon = noctalia.fileExists(iconPath)

        local glyphValue = hasIcon and nil or "world"
        local iconValue = hasIcon and iconPath or nil

        if not hasIcon then
            downloadFavicon(domain, function()
                launcher.setResults(query, makeResults(text, query))
            end)
        end

        if text == "" then
            table.insert(results, {
                id = link.url,
                title = link.name, subtitle = link.url,
                glyph = glyphValue, icon = iconValue
            })
        else
            local score = noctalia.fuzzyScore(text, link.name)
            if score ~= nil then
                table.insert(results, {
                    id = link.url,
                    title = link.name, subtitle = link.url,
                    glyph = glyphValue, icon = iconValue,
                    score = score
                })
            end
        end
    end

    return results
end

function onQuery(query)
    local text = noctalia.string.trim(query)
    launcher.setResults(query, makeResults(text, query))
end

local function shellEscape(raw)
    return "'" .. raw:gsub("'", "'\\''") .. "'"
end

function onActivate(id)
    local command = noctalia.getConfig("command")
    noctalia.runAsync(command .. " " .. shellEscape(id))

    if noctalia.getConfig("notify") then
        noctalia.notify(
            noctalia.tr("notify.title"),
            noctalia.tr("notify.message", { name = id })
        )
    end
end
