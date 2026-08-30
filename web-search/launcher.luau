--!nonstrict

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function mruPath()
    return noctalia.pluginDir() .. "/cache/mru.txt"
end

-- Last-use ledger: one "used <seq>|<url>" line per opened site, where <seq>
-- is a monotonically increasing counter (higher = more recently used).
local function loadUsage()
    local usage = {}
    local ok, content = pcall(noctalia.readFile, mruPath())
    if not ok or type(content) ~= "string" then
        return usage
    end
    for line in content:gmatch("[^\r\n]+") do
        local n, url = line:match("^used%s+(%d+)|(.+)$")
        if n ~= nil and url ~= nil then
            usage[url] = tonumber(n)
        end
    end
    return usage
end

local function recordUse(url)
    local usage = loadUsage()
    local max = 0
    for _, n in pairs(usage) do
        if n > max then max = n end
    end
    usage[url] = max + 1

    local lines = {}
    for u, n in pairs(usage) do
        table.insert(lines, "used " .. n .. "|" .. u)
    end
    table.sort(lines)

    local path = mruPath()
    noctalia.mkdirAll(noctalia.pluginDir() .. "/cache")
    local content = table.concat(lines, "\n") .. "\n"
    local written = false
    if type(noctalia.writeFile) == "function" then
        written = pcall(noctalia.writeFile, path, content)
    end
    if not written then
        noctalia.runAsync("cat > " .. shellQuote(path) .. " <<'NOCT_MRU_EOF'\n" .. content .. "NOCT_MRU_EOF\n")
    end
end

local function loadLinks()
    local raw = noctalia.getConfig("links")
    local links = {}
    if type(raw) ~= "table" then
        return links
    end

    for _, line in ipairs(raw) do
        local name, url = line:match("^([^|]+)|(.+)$")
        if name ~= nil and url ~= nil then
            name = trim(name)
            url = trim(url)
            if name ~= "" and url:match("^https?://") then
                table.insert(links, { name = name, url = url })
            end
        end
    end
    return links
end

local function domainFor(url)
    local domain = url:match("^https?://([^/]+)")
    return domain and domain:gsub("^.*@", "") or nil
end

local function iconPath(domain)
    local cacheDir = noctalia.pluginDir() .. "/cache"
    local safeDomain = domain:gsub("[^%w%.%-]", "_")
    return cacheDir .. "/" .. safeDomain .. ".png", cacheDir
end

local function loadIcon(domain, query, refresh)
    local path, cacheDir = iconPath(domain)
    if noctalia.fileExists(path) then
        return path
    end

    noctalia.mkdirAll(cacheDir)
    local url = "https://www.google.com/s2/favicons?sz=64&domain=" .. noctalia.string.urlEncode(domain)
    noctalia.download(url, path, function(ok)
        if ok then
            refresh(query)
        end
    end)
    return nil
end

local function websiteResults(text, query, refresh)
    local links = loadLinks()
    local usage = loadUsage()
    local configOrder = {}
    for i, link in ipairs(links) do
        configOrder[link.url] = i
    end
    -- Most recently used first; never-used entries keep their configured order.
    table.sort(links, function(a, b)
        local ua, ub = usage[a.url] or 0, usage[b.url] or 0
        if ua ~= ub then
            return ua > ub
        end
        return configOrder[a.url] < configOrder[b.url]
    end)

    local results = {}
    for _, link in ipairs(links) do
        local domain = domainFor(link.url)
        local icon = domain and loadIcon(domain, query, refresh) or nil
        local score = text == "" and 0 or noctalia.fuzzyScore(text, link.name)
        if score ~= nil then
            table.insert(results, {
                id = "open:" .. link.url,
                title = link.name,
                subtitle = link.url,
                glyph = icon and nil or "world",
                icon = icon,
                score = score,
            })
        end
    end
    return results
end

local function makeResults(query)
    local text = trim(query)
    local function refresh(activeQuery)
        launcher.setResults(activeQuery, makeResults(activeQuery))
    end

    local results = websiteResults(text, query, refresh)
    if text ~= "" then
        local icon = loadIcon("www.google.com", query, refresh)
        table.insert(results, 1, {
            id = "search:" .. text,
            title = "Search Google",
            subtitle = text,
            glyph = icon and nil or "world-search",
            icon = icon,
            score = 2048,
        })
    end
    return results
end

function onQuery(query)
    launcher.setResults(query, makeResults(query))
end

function onActivate(id)
    local url = id:match("^open:(https?://.+)$")
    if url ~= nil then
        recordUse(url)
        noctalia.runAsync("xdg-open " .. shellQuote(url) .. " >/dev/null 2>&1")
        return
    end

    local query = id:match("^search:(.*)$")
    if query == nil or query == "" then
        return
    end
    local command = "xdg-open \"$(python3 -c 'import sys, urllib.parse; print(\"https://www.google.com/search?q=\" + urllib.parse.quote_plus(sys.argv[1]))' "
        .. shellQuote(query)
        .. ")\" >/dev/null 2>&1"
    noctalia.runAsync(command)
end
