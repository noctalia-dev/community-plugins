--!nonstrict
-- skills — pure data module for the Skills/Mods tab, same rules as
-- sessions.luau: no UI state, the panel owns what is busy or confirming.
--
-- Skills and mods both ship as Claude Code plugins, so `claude plugin` is
-- the single source of truth: list/install/update/uninstall plus the
-- marketplace commands, all argv-exec'd with --json (the result is the last
-- stdout line). The one thing it does not track is a bare skill folder under
-- ~/.claude/skills (hand-copied, or a symlink from a skills installer):
-- those are listed from disk and can only be removed, never updated.
-- ~/.claude/skills/synced is claude.ai's own sync bucket and stays hidden.

local M = {}

local LOCAL_SKILLS_DIR = noctalia.expandPath("~/.claude/skills")
M.LOCAL_SKILLS_DIR = LOCAL_SKILLS_DIR

-- Install/update fetch over git; the host caps a command at 60s anyway.
local CLI_TIMEOUT = 60000

-- Safe folder/plugin/marketplace name: also what keeps a newline-forged or
-- "-"-leading record out of an argv list.
local function isName(s)
    return type(s) == "string" and s:match("^[%w_][%w._-]*$") ~= nil
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- One-line human outcome of a --json run: the JSON's message, else the
-- first stderr line.
local function outcomeMessage(result)
    local last = nil
    for line in (result.stdout or ""):gmatch("[^\n]+") do
        last = line
    end
    local data = last and noctalia.json.decode(last)
    if type(data) == "table" and type(data.message) == "string" and data.message ~= "" then
        return data.message
    end
    return (result.stderr or ""):match("[^\n]+") or ""
end

local function runCli(args, done)
    local argv = { "claude", "plugin" }
    for _, a in ipairs(args) do
        table.insert(argv, a)
    end
    local ok = noctalia.runAsync(argv, function(result)
        if type(result) ~= "table" then
            done(false, "")
            return
        end
        done(result.exitCode == 0, trim(outcomeMessage(result)))
    end, CLI_TIMEOUT)
    if not ok then
        done(false, "")
    end
end

-- ── project links ────────────────────────────────────────────────────────
-- Only plain http(s) URLs ever reach xdg-open.

local function webUrl(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("^git%+", ""):gsub("%.git$", "")
    return s:match("^https?://[^%s]+$")
end

local function readJson(path)
    local text = noctalia.readFile(path)
    return type(text) == "string" and noctalia.json.decode(text) or nil
end

local function marketplaceUrl(m)
    if m.source == "github" and type(m.repo) == "string" and m.repo:match("^[%w_.-]+/[%w_.-]+$") then
        return "https://github.com/" .. m.repo
    end
    return webUrl(m.url)
end

-- The plugin's own repository/homepage, else where its marketplace entry
-- points (a sub-folder of the marketplace repo, or a repo of its own),
-- else the marketplace itself.
local function pluginUrl(p, entry, market)
    local manifest = type(p.installPath) == "string" and readJson(p.installPath .. "/.claude-plugin/plugin.json")
    if type(manifest) == "table" then
        local repo = manifest.repository
        local url = webUrl(type(repo) == "table" and repo.url or repo) or webUrl(manifest.homepage)
        if url then
            return url
        end
    end
    local src = entry and entry.source
    if type(src) == "table" then
        return marketplaceUrl({ source = src.source, repo = src.repo, url = src.url }) or market.url
    end
    local path = type(src) == "string" and src:match("^%./(.*)$")
    if path and path ~= "" and market.url and market.url:match("^https://github%.com/") then
        return market.url .. "/tree/HEAD/" .. path:gsub("/$", "")
    end
    return market.url
end

-- The plugin's entry in its marketplace's local clone, or nil.
local function catalogEntry(market, name)
    if market.catalog == nil then
        local data = market.installLocation and readJson(market.installLocation .. "/.claude-plugin/marketplace.json")
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
local function latestVersion(entry, market)
    if entry == nil then
        return ""
    end
    if type(entry.version) == "string" then
        return entry.version
    end
    local path = type(entry.source) == "string" and entry.source:match("^%./(.*)$")
    local dir = path and market.installLocation and (market.installLocation .. "/" .. path):gsub("/+$", "")
    local manifest = dir and readJson(dir .. "/.claude-plugin/plugin.json")
    return type(manifest) == "table" and type(manifest.version) == "string" and manifest.version or ""
end

-- Repo of a bare skill installed by the `skills` CLI (it keeps a lock file).
local skillLock = noctalia.expandPath("~/.agents/.skill-lock.json")
local function localSkillUrl(lock, name)
    local entry = type(lock) == "table" and type(lock.skills) == "table" and lock.skills[name]
    return type(entry) == "table" and webUrl(entry.sourceUrl) or nil
end

function M.openUrl(url)
    if webUrl(url) == nil or not noctalia.runAsync({ "xdg-open", url }) then
        noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err_open_url"))
    end
end

function M.available()
    return noctalia.commandExists("claude")
end

-- Classifies what the user typed in the install box:
--   "name" / "name@marketplace"           -> "plugin"      (claude plugin install)
--   "owner/repo", https/git URL, a path   -> "marketplace" (claude plugin marketplace add)
-- nil for anything else (spaces, a leading "-" that argv would read as a flag).
function M.classifySource(text)
    text = trim(text or "")
    if text == "" or #text > 512 or text:find("%s") or text:sub(1, 1) == "-" then
        return nil
    end
    local name, market = text:match("^([^@]+)@([^@]+)$")
    if (isName(text)) or (isName(name) and isName(market)) then
        return "plugin", text
    end
    if text:match("^[%w_.-]+/[%w_.-]+$") or text:match("^https?://") or text:match("^git@")
        or text:match("^[/~]") then
        return "marketplace", text
    end
    return nil
end

-- Calls done({ plugins, marketplaces, localSkills }, err) once all three
-- listings are back; err is the first failure's message.
function M.refresh(done)
    local out = { plugins = nil, marketplaces = nil, localSkills = nil }
    local pending = 3
    local firstErr = nil
    local function finish(err)
        firstErr = firstErr or err
        pending -= 1
        if pending == 0 then
            done(firstErr == nil and out or nil, firstErr)
        end
    end

    local function listJson(argv, field)
        local ok = noctalia.runAsync(argv, function(result)
            local data = type(result) == "table" and result.exitCode == 0 and noctalia.json.decode(result.stdout or "")
            if type(data) ~= "table" then
                finish(noctalia.tr("err_skills_fetch"))
                return
            end
            out[field] = data
            finish(nil)
        end, CLI_TIMEOUT)
        if not ok then
            finish(noctalia.tr("err_skills_fetch"))
        end
    end

    listJson({ "claude", "plugin", "list", "--json" }, "plugins")
    listJson({ "claude", "plugin", "marketplace", "list", "--json" }, "marketplaces")

    -- A missing ~/.claude/skills is just "no local skills", not an error.
    local ok = noctalia.runAsync({
        "find", LOCAL_SKILLS_DIR, "-mindepth", "1", "-maxdepth", "1", "!", "-name", "synced", "-printf", "%f\n",
    }, function(result)
        local lock = readJson(skillLock)
        local list = {}
        for line in (type(result) == "table" and result.stdout or ""):gmatch("[^\n]+") do
            if isName(line) then
                table.insert(list, { name = line, url = localSkillUrl(lock, line) })
            end
        end
        table.sort(list, function(a, b)
            return a.name < b.name
        end)
        out.localSkills = list
        finish(nil)
    end)
    if not ok then
        finish(noctalia.tr("err_skills_fetch"))
    end
end

-- Groups installed plugins under their marketplace (the id's "@" suffix).
-- Every configured marketplace gets a group, even with nothing installed
-- from it, so it can still be refreshed or removed.
function M.groupByMarketplace(plugins, marketplaces)
    local byName = {}
    local order = {}
    local function group(name)
        if byName[name] == nil then
            byName[name] = { name = name, plugins = {} }
            table.insert(order, byName[name])
        end
        return byName[name]
    end
    for _, m in ipairs(marketplaces) do
        if isName(m.name) then
            local g = group(m.name)
            g.source = m.repo or m.url or m.path
            g.url = marketplaceUrl(m)
            g.installLocation = type(m.installLocation) == "string" and m.installLocation or nil
        end
    end
    for _, p in ipairs(plugins) do
        local name, market = tostring(p.id or ""):match("^([^@]+)@([^@]+)$")
        if isName(name) and isName(market) then
            local g = group(market)
            local entry = catalogEntry(g, name)
            local version = type(p.version) == "string" and p.version or ""
            local latest = latestVersion(entry, g)
            table.insert(g.plugins, {
                url = pluginUrl(p, entry, g),
                id = p.id,
                name = name,
                version = version,
                -- Set only when the clone offers a different version.
                newVersion = (latest ~= "" and latest ~= version) and latest or nil,
                scope = isName(p.scope) and p.scope or "user",
                enabled = p.enabled ~= false,
            })
        end
    end
    for _, g in ipairs(order) do
        table.sort(g.plugins, function(a, b)
            return a.name < b.name
        end)
    end
    table.sort(order, function(a, b)
        return a.name < b.name
    end)
    return order
end

function M.install(text, done)
    local kind, src = M.classifySource(text)
    if kind == "plugin" then
        runCli({ "install", src, "--json" }, done)
    elseif kind == "marketplace" then
        runCli({ "marketplace", "add", src, "--json" }, done)
    else
        done(false, noctalia.tr("err_bad_source"))
    end
end

function M.updatePlugin(p, done)
    runCli({ "update", p.id, "--scope", p.scope, "--json" }, done)
end

function M.setEnabled(p, done)
    runCli({ p.enabled and "disable" or "enable", p.id, "--scope", p.scope, "--json" }, done)
end

function M.uninstallPlugin(p, done)
    runCli({ "uninstall", p.id, "--scope", p.scope, "--json" }, done)
end

-- Re-fetches every marketplace clone, so the next listing compares the
-- installed versions against the newest catalogs. Plugins stay as they are.
function M.checkUpdates(_, done)
    -- No --json: the CLI accepts it only together with a marketplace name.
    runCli({ "marketplace", "update" }, done)
end

function M.updateMarketplace(name, done)
    runCli({ "marketplace", "update", name, "--json" }, done)
end

function M.removeMarketplace(name, done)
    runCli({ "marketplace", "remove", name, "--json" }, done)
end

-- No trailing slash: on a symlinked skill this removes the link only, never
-- the target it points at.
function M.removeLocalSkill(name, done)
    if not isName(name) then
        done(false, "")
        return
    end
    local ok = noctalia.runAsync({ "rm", "-rf", "--", LOCAL_SKILLS_DIR .. "/" .. name }, function(result)
        done(type(result) == "table" and result.exitCode == 0, "")
    end)
    if not ok then
        done(false, "")
    end
end

return M
