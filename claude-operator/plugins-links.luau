--!nonstrict
-- Project links: where a plugin, a marketplace or a bare skill lives on the web, read
-- from the plugin's manifest, its marketplace's local clone (which also gives the newest
-- version it offers) or the skills CLI's lock file. Only plain http(s) URLs come out,
-- so only those ever reach xdg-open. Ported from claude-cockpit's skills.luau
-- (nightwatch75, MIT).

local M = {}

function M.webUrl(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^git%+", ""):gsub("%.git$", "")
    return s:match("^https?://[^%s]+$")
end

function M.readJson(path)
    local text = noctalia.readFile(path)
    return type(text) == "string" and noctalia.json.decode(text) or nil
end

function M.marketplaceUrl(m)
    if m.source == "github" and type(m.repo) == "string" and m.repo:match("^[%w_.-]+/[%w_.-]+$") then
        return "https://github.com/" .. m.repo
    end
    return M.webUrl(m.url)
end

-- The plugin's own repository/homepage, else where its marketplace entry
-- points (a sub-folder of the marketplace repo, or a repo of its own),
-- else the marketplace itself.
function M.pluginUrl(p, entry, market)
    local manifest = type(p.installPath) == "string" and M.readJson(p.installPath .. "/.claude-plugin/plugin.json")
    if type(manifest) == "table" then
        local repo = manifest.repository
        local url = M.webUrl(type(repo) == "table" and repo.url or repo) or M.webUrl(manifest.homepage)
        if url then
            return url
        end
    end
    local src = entry and entry.source
    if type(src) == "table" then
        return M.marketplaceUrl({ source = src.source, repo = src.repo, url = src.url }) or market.url
    end
    local path = type(src) == "string" and src:match("^%./(.*)$")
    if path and path ~= "" and market.url and market.url:match("^https://github%.com/") then
        return market.url .. "/tree/HEAD/" .. path:gsub("/$", "")
    end
    return market.url
end

-- The plugin's entry in its marketplace's local clone, or nil.
function M.catalogEntry(market, name)
    if market.catalog == nil then
        local data = market.installLocation and M.readJson(market.installLocation .. "/.claude-plugin/marketplace.json")
        market.catalog = type(data) == "table" and type(data.plugins) == "table" and data.plugins or {}
    end
    for _, entry in ipairs(market.catalog) do
        if type(entry) == "table" and entry.name == name then
            return entry
        end
    end
    return nil
end

-- Newest version the marketplace clone offers: the catalog entry's own
-- `version`, else the plugin.json inside the clone. "" when the plugin
-- lives in another repo (object source): that would need a fetch per plugin.
function M.latestVersion(entry, market)
    if entry == nil then
        return ""
    end
    if type(entry.version) == "string" then
        return entry.version
    end
    local path = type(entry.source) == "string" and entry.source:match("^%./(.*)$")
    local dir = path and market.installLocation and (market.installLocation .. "/" .. path):gsub("/+$", "")
    local manifest = dir and M.readJson(dir .. "/.claude-plugin/plugin.json")
    return type(manifest) == "table" and type(manifest.version) == "string" and manifest.version or ""
end

-- Repo of a bare skill installed by the `skills` CLI (it keeps a lock file).
M.skillLock = noctalia.expandPath("~/.agents/.skill-lock.json")
function M.localSkillUrl(lock, name)
    local entry = type(lock) == "table" and type(lock.skills) == "table" and lock.skills[name]
    return type(entry) == "table" and M.webUrl(entry.sourceUrl) or nil
end

return M
