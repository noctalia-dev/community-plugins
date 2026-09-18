local keysPath: string? = nil
local generation = 0
local GLYPH = {
    nixpkgs        = "package",
    nixos          = "snowflake",
    ["home-manager"] = "home",
    nur            = "users",
    noogle         = "lambda",
    darwin         = "brand-apple",
}

local HOME = (noctalia.pluginDataDir() or ""):match("^(.-)/%.local/") or "/root"
local USER = HOME:match("([^/]+)$") or ""

local ICON_DIRS = {
    "/run/current-system/sw/share/icons/hicolor",
    HOME .. "/.nix-profile/share/icons/hicolor",
    "/etc/profiles/per-user/" .. USER .. "/share/icons/hicolor",
}

type Info = { desc: string?, home: string?, icon: string? }

local function shellQuote(s: string): string
    local q = s:gsub("'", "'\\''")
    return "'" .. q .. "'"
end

do
    local dir = noctalia.pluginDataDir()
    if dir ~= nil then
        keysPath = dir .. "/keys.txt"
    end
end

local function packageIcon(name: string): string?
    for _, dir in ICON_DIRS do
        if noctalia.fileExists(dir .. "/scalable/apps/" .. name .. ".svg")
        or noctalia.fileExists(dir .. "/48x48/apps/" .. name .. ".png")
        or noctalia.fileExists(dir .. "/128x128/apps/" .. name .. ".png") then
            return name
        end
    end
    return nil
end

local function parsePreview(out: string): (string, string?)
    local clean = out:gsub("\27%[[%d;]*[A-Za-z]", "")
    local lines = {}
    for l in clean:gmatch("[^\n]+") do
        local t = l:gsub("^%s+", ""):gsub("%s+$", "")
        if #t > 0 then
            table.insert(lines, t)
        end
    end
    local desc = lines[2] or lines[1] or ""
    local home = clean:match("[Hh]omepage:?%s*(%S+)")
    return desc, home
end

local function actionsFor(line: string, info: Info?)
    local idx, key = line:match("^(%S+)/%s*(.+)$")
    if not idx or not key then
        return {}
    end
    local i: Info = info or {}

    local acts = {
        {
            id = "info|" .. line,
            title = key,
            subtitle = i.desc or "Loading documentation…",
            icon = i.icon,
            glyph = if i.icon == nil then (GLYPH[idx] or "search") else nil,
            query = "> " .. line,
        },
        { id = "copy|" .. key, title = "Copy “" .. key .. "”", glyph = "copy" },
    }

    if idx == "nixpkgs" then
        local nixSnippet:string = "environment.systemPackages = with pkgs; [ " .. key .. " ]"
        local homeSnippet:string = "home.packages = with pkgs; [ " .. key .. " ]"

        table.insert(acts, { id = "shell|" .. key, title = "nix shell nixpkgs#" .. key, glyph = "terminal" })
        table.insert(acts, { id = "web|https://search.nixos.org/packages?query=" .. noctalia.string.urlEncode(key), title = "Open on search.nixos.org", glyph = "world" })
        table.insert(acts, { id = "copy|" .. nixSnippet, title = "Copy snippet for nixpkgs", subtitle = nixSnippet})
        table.insert(acts, { id = "copy|" .. homeSnippet, title = "Copy snippet for home-manager", subtitle = homeSnippet})
    end
    if i.home then
        table.insert(acts, { id = "web|" .. i.home, title = "Open homepage", glyph = "link" })
    end

    return acts
end

local function showActions(text: string, line: string)
    launcher.setResults(text, actionsFor(line))
    noctalia.runAsync({ "nix-search-tv", "preview", line }, function(result)
        local desc, home = parsePreview(result.stdout)
        local idx, key = line:match("^(%S+)/%s*(.+)$")
        local icon = if idx == "nixpkgs" and key then packageIcon(key) else nil
        launcher.setResults(text, actionsFor(line, { desc = desc, home = home, icon = icon }))
    end)
end

function onQuery(text: string)
    local path = keysPath
    if path == nil then
        launcher.setResults(text, {})
        return
    end

    local sel = text:match("^>%s*(.+)$")
    if sel then
        showActions(text, sel)
        return
    end

    if #text < 2 then
        launcher.setResults(text, {})
        return
    end
    launcher.setResults(text, { { id = "loading", title = "Searching…", glyph = "loader" } })

    local cmd = "fzf --filter " .. shellQuote(text) .. " < " .. shellQuote(path) .. " | head -n 30"
    noctalia.runAsync(cmd, function(result)
        local hits = {}
        for line in result.stdout:gmatch("[^\n]+") do
            local idx, key = line:match("^(%S+)/%s*(.+)$")
            if idx and key then
                table.insert(hits, { id = line, title = key, subtitle = idx,
                    glyph = GLYPH[idx] or "search", query = "> " .. line })
            end
        end
        launcher.setResults(text, hits)
    end)
end

function onActivate(id: string)
    local kind, arg = id:match("^(%w+)|(.+)$")
    if kind == "copy" then noctalia.copyToClipboard(arg, "text/plain")
    elseif kind == "shell" then noctalia.runInTerminal("nix shell nixpkgs#" .. arg)
    elseif kind == "web" then noctalia.runAsync({ "xdg-open", arg })
    end
end
