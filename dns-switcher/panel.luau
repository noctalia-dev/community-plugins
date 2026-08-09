--!nonstrict
-- dns-switcher — provider panel. Pure renderer over the shared state: the
-- service entry (service.luau) publishes "dns_state" and executes the
-- "apply_request" entries this panel emits. Picking a provider applies it
-- immediately (one nmcli change, no reactivation).

local STATE_KEY = "dns_state" -- published by service.luau
local REQUEST_KEY = "apply_request" -- consumed by service.luau

local RESOLVE_TIMEOUT_MS = 4000

-- Read out of the plugin's own manifest (readFile resolves a relative path
-- against the plugin directory), so the header cannot drift from the version
-- the store shows. Empty when unreadable — a missing version is not worth an
-- error line in the panel.
local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then
        return ""
    end
    return ("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or ""
end)()

local snapshot = nil -- last state published by the service

-- DNS lookup tester (bottom of the panel). Entirely panel-local: it neither
-- reads nor writes the shared state, since it never changes what DNS is
-- configured — it only asks "does a name resolve through the DNS that IS
-- configured right now", which is exactly the question this plugin otherwise
-- has no way to answer.
local resolveQuery = ""
local resolveBusy = false
local resolveError = nil
local resolveResult = nil -- { tool, serverIp?, serverLabel?, lines? (dig), raw? (nslookup) }

local render

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- The nonce is monotonic across writers (widget instances and the panel):
-- each seeds from the last request already in the shared state.
local function requestApply(entry)
    if snapshot == nil or snapshot.changing == true then
        return
    end
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, id = entry.id, label = entry.label, ip = entry.ip })
end

-- A conservative hostname shape (letters/digits/dot/hyphen, no leading dot or
-- hyphen, 253 chars max — the DNS wire-format limit). shellQuote() below is
-- the actual safety net; this only keeps an obviously-wrong query from ever
-- reaching a shell as a "valid enough" no-op.
local function isValidHostname(name)
    return name ~= "" and #name <= 253 and name:match("^[%w][%w%.%-]*$") ~= nil
end

-- Name + first address of the currently active provider, if it has an
-- address of its own (built-in/custom entries do; "Default (ISP)" does not).
-- nil means "ask the system resolver", not "no server" — the lookup still
-- runs either way.
local function activeServerInfo()
    if snapshot == nil or snapshot.current == nil or type(snapshot.current.ip) ~= "string" then
        return nil
    end
    local ip = snapshot.current.ip:match("%S+")
    if ip == nil then
        return nil
    end
    return { ip = ip, label = snapshot.current.label }
end

local function parseDigShort(stdout)
    local lines = {}
    for line in stdout:gmatch("[^\n]+") do
        local clean = trim(line)
        if clean ~= "" then
            table.insert(lines, clean)
        end
    end
    return lines
end

-- Prefers `dig +short` (one line per answer, trivial to parse); falls back to
-- raw `nslookup` output, shown verbatim, when dig is not installed. Both are
-- pointed at the active provider's own address when it has one, so the
-- answer reflects that resolver specifically rather than whatever the system
-- resolver layer (systemd-resolved, etc.) does with it.
local function runResolve()
    local name = trim(resolveQuery)
    if not isValidHostname(name) then
        resolveError = tr("resolve_invalid")
        resolveResult = nil
        render()
        return
    end

    local server = activeServerInfo()
    local useDig = noctalia.commandExists("dig")
    local useNslookup = not useDig and noctalia.commandExists("nslookup")
    if not useDig and not useNslookup then
        resolveError = tr("resolve_no_tool")
        resolveResult = nil
        render()
        return
    end

    resolveBusy = true
    resolveError = nil
    resolveResult = nil
    render()

    local tool = useDig and "dig" or "nslookup"
    local cmd
    if useDig then
        cmd = "dig +time=3 +tries=1 +short "
            .. (server ~= nil and ("@" .. shellQuote(server.ip) .. " ") or "")
            .. shellQuote(name)
    else
        cmd = "nslookup " .. shellQuote(name) .. (server ~= nil and (" " .. shellQuote(server.ip)) or "")
    end

    local ok = noctalia.runAsync(cmd, function(result)
        resolveBusy = false
        if result.timedOut then
            resolveError = tr("resolve_timeout")
        elseif tool == "dig" then
            local lines = parseDigShort(result.stdout or "")
            if #lines == 0 then
                resolveError = tr("resolve_empty")
            else
                resolveResult = {
                    tool = tool,
                    serverIp = server ~= nil and server.ip or nil,
                    serverLabel = server ~= nil and server.label or nil,
                    lines = lines,
                }
            end
        else
            local raw = trim(result.stdout or "")
            if raw == "" then
                resolveError = tr("resolve_empty")
            else
                resolveResult = {
                    tool = tool,
                    serverIp = server ~= nil and server.ip or nil,
                    serverLabel = server ~= nil and server.label or nil,
                    raw = raw,
                }
            end
        end
        render()
    end, RESOLVE_TIMEOUT_MS)
    if not ok then
        resolveBusy = false
        resolveError = tr("resolve_spawn_failed")
        render()
    end
end

-- A row names its provider and the addresses it would set, so picking one is not
-- a guess about what it does. The ISP default has no fixed addresses -- whatever
-- the LAN hands out -- so it stays a bare label, and the footer shows what is
-- actually in use. A button carries one run of text, so the two are joined with a
-- separator rather than styled apart.
local function providerRow(entry)
    local active = snapshot.current ~= nil and snapshot.current.id == entry.id
    local text = entry.label
    if entry.ip ~= nil and entry.ip ~= "" then
        text = text .. "  ·  " .. entry.ip
    end
    return ui.button({
        key = "dns-" .. entry.id .. (active and "-on" or ""),
        glyph = entry.glyph,
        text = text,
        variant = active and "primary" or "ghost",
        contentAlign = "start",
        onClick = function()
            if not active then
                requestApply(entry)
            end
        end,
    })
end

local function statusFooter()
    if snapshot.changing == true then
        return ui.label({ text = tr("status_switching"), fontSize = 11, color = "secondary" })
    end
    local servers = snapshot.servers
    if servers == nil or servers == "" then
        servers = tr("status_auto")
    end
    local caption = servers
    if snapshot.conName ~= nil and snapshot.conName ~= "" then
        caption = snapshot.conName .. "  ·  " .. servers
    end
    return ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
        ui.button({ glyph = "copy", variant = "ghost", tooltip = tr("tip_copy"), onClick = "onCopyServers" }),
    })
end

-- Bottom-of-panel lookup tester: a name, a button, and whatever the active
-- resolver (or the system one, with no provider address of its own) answers.
local function resolveSection()
    local children = {
        ui.separator({}),
        ui.label({ key = "resolve-title", text = tr("resolve_title"), fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
        ui.row({ key = "resolve-row", gap = 6, align = "center" }, {
            ui.input({
                key = "resolve-input",
                value = resolveQuery,
                placeholder = tr("resolve_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    resolveQuery = value
                end,
                onSubmit = function(value)
                    resolveQuery = value
                    runResolve()
                end,
            }),
            ui.button({
                key = "resolve-go" .. (resolveBusy and "-off" or ""),
                glyph = "search",
                variant = "primary",
                enabled = not resolveBusy,
                tooltip = tr("tip_resolve"),
                onClick = function()
                    runResolve()
                end,
            }),
        }),
    }

    if resolveBusy then
        table.insert(children, ui.label({ key = "resolve-status", text = tr("resolve_busy"), fontSize = 11, color = "secondary" }))
    elseif resolveError ~= nil then
        table.insert(children, ui.label({ key = "resolve-status", text = resolveError, fontSize = 11, color = "error", maxLines = 2 }))
    elseif resolveResult ~= nil then
        local via
        if resolveResult.serverIp ~= nil then
            via = tr("resolve_via", { name = resolveResult.serverLabel or resolveResult.serverIp, server = resolveResult.serverIp })
        else
            via = tr("resolve_via_system")
        end
        local body = resolveResult.lines ~= nil and table.concat(resolveResult.lines, ", ") or resolveResult.raw
        -- The answer first, then which server gave it — the label is set
        -- apart with a slightly larger font since it names what answered.
        table.insert(children, ui.label({ key = "resolve-body", text = body, fontSize = 14, color = "primary", maxLines = 6 }))
        table.insert(children, ui.label({ key = "resolve-via", text = via, fontSize = 13, fontWeight = "medium", color = "on_surface_variant" }))
    end

    return ui.column({ key = "resolve", gap = 6 }, children)
end

render = function()
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                key = "title",
                text = tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
            }),
            -- Version off the manifest, small and dimmed: it answers "which
            -- build am I running" without competing with the title. The spacer
            -- rather than a flexGrow title keeps the two together on the left.
            ui.label({ key = "version", text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
            ui.spacer({ key = "gap", flexGrow = 1 }),
            ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = "onOpenSettings" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
        }),
    }

    if snapshot == nil or snapshot.list == nil then
        table.insert(children, ui.label({ text = tr("status_checking"), color = "on_surface_variant" }))
    elseif snapshot.error ~= nil then
        table.insert(children, ui.label({ text = snapshot.error, color = "error" }))
    else
        local rows = {}
        for _, entry in ipairs(snapshot.list) do
            table.insert(rows, providerRow(entry))
        end
        table.insert(children, ui.scroll({ flexGrow = 1, gap = 4 }, rows))
        table.insert(children, statusFooter())
    end

    -- Always present, independent of detection state: it asks a question
    -- about a name, not about which provider is active.
    table.insert(children, resolveSection())

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

function onOpen(_context)
    snapshot = noctalia.state.get(STATE_KEY)
    render()
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) == "table" then
        snapshot = value
        render()
    end
end)

function onCopyServers()
    if snapshot == nil then
        return
    end
    local text = snapshot.servers
    if (text == nil or text == "") and snapshot.current ~= nil then
        text = snapshot.current.ip
    end
    if text == nil or text == "" then
        return
    end
    noctalia.copyToClipboard(text, "text/plain")
    noctalia.notify(tr("title"), tr("copied", { ip = text }))
end

-- Opens the settings window on this plugin's own page (the host supplies the
-- plugin id, so a plugin can only ever open its own). It closes the panel on
-- the way, which is why nothing is rendered afterwards.
function onOpenSettings()
    noctalia.openSettings()
end

function onClosePanel()
    panel.close()
end
