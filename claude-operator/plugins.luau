--!nonstrict
-- plugins: data module for the Plugins tab. No UI state: the tab owns what is busy or
-- confirming. Ported from claude-cockpit's skills.luau (nightwatch75, MIT).
--
-- Skills and mods both ship as Claude Code plugins, so `claude plugin` is
-- the single source of truth: list/install/update/uninstall plus the
-- marketplace commands, all argv-exec'd with --json (the result is the last
-- stdout line). The one thing it does not track is a bare skill folder under
-- ~/.claude/skills (hand-copied, or a symlink from a skills installer):
-- those are listed from disk and can only be removed, never updated.
-- ~/.claude/skills/synced is claude.ai's own sync bucket and stays hidden.
--
-- Running the CLI is plugins-cli.luau; where a plugin or marketplace lives on the
-- web, and the newest version its clone offers, is plugins-links.luau.

local shared = require("./shared.luau")
local actions = require("./actions.luau")
local cli = require("./plugins-cli.luau")
local links = require("./plugins-links.luau")
local isName, trim, outcomeMessage, logFailure = cli.isName, cli.trim, cli.outcomeMessage, cli.logFailure
local cliArgv, runCli, CLI_TIMEOUT = cli.cliArgv, cli.runCli, cli.CLI_TIMEOUT
local webUrl, readJson, marketplaceUrl, pluginUrl = links.webUrl, links.readJson, links.marketplaceUrl, links.pluginUrl
local catalogEntry, latestVersion, localSkillUrl, skillLock = links.catalogEntry, links.latestVersion, links.localSkillUrl, links.skillLock
local M = {}

local LOCAL_SKILLS_DIR = noctalia.expandPath("~/.claude/skills")
M.LOCAL_SKILLS_DIR = LOCAL_SKILLS_DIR

function M.openUrl(url)
    if webUrl(url) == nil or not noctalia.runAsync({ "xdg-open", url }) then
        noctalia.notifyError("Claude Operator", "Could not open the link")
    end
end

function M.available()
    return actions.claudeBin() ~= nil
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

    local function listJson(args, field)
        local ok = noctalia.runAsync(cliArgv(args), function(result)
            local data = type(result) == "table" and result.exitCode == 0 and noctalia.json.decode(result.stdout or "")
            if type(data) ~= "table" then
                local why = type(result) ~= "table" and "no result"
                    or result.exitCode == 0 and "output was not JSON" or outcomeMessage(result)
                logFailure(args, why)
                finish(`Could not list Claude Code plugins ({why})`)
                return
            end
            out[field] = data
            finish(nil)
        end, CLI_TIMEOUT)
        if not ok then
            logFailure(args, "could not start")
            finish("Could not start claude")
        end
    end

    listJson({ "list", "--json" }, "plugins")
    listJson({ "marketplace", "list", "--json" }, "marketplaces")

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
        finish("Could not list Claude Code plugins")
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
        done(false, "Not a plugin, marketplace, repo or path")
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

-- Refreshes every marketplace, then updates the given plugins one at a time (parallel
-- runs would race on the same settings and cache). onStep(i, p) fires before plugin i.
-- done(ok, summary); ok is false when any plugin failed.
function M.updateAll(list, done, onStep)
    local updated, failed = {}, {}
    local i = 0
    local function nextPlugin()
        i += 1
        local p = list[i]
        if p == nil then
            local parts = {}
            if #updated > 0 then table.insert(parts, "Updated " .. table.concat(updated, ", ") .. ". Restart Claude Code to apply.") end
            if #failed > 0 then table.insert(parts, "Failed: " .. table.concat(failed, ", ") .. ".") end
            done(#failed == 0, #parts > 0 and table.concat(parts, " ") or "Every plugin is up to date.")
            return
        end
        onStep(i, p)
        M.updatePlugin(p, function(ok, _, data)
            if not ok then
                table.insert(failed, p.name)
            elseif data and data.updateOutcome ~= "up_to_date" then
                table.insert(updated, p.name)
            end
            nextPlugin()
        end)
    end
    -- A marketplace that fails to refresh still leaves the others' catalogs current.
    M.checkUpdates(nil, nextPlugin)
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
