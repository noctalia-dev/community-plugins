--!nonstrict
-- dns-switcher — provider panel. Pure renderer over the shared state: the
-- service entry (service.luau) publishes "dns_state" and executes the
-- "apply_request" entries this panel emits. Picking a provider applies it
-- immediately (one nmcli change, no reactivation).
--
-- Right-clicking a provider raises a native context menu (plugin_api >= 28):
-- apply it, copy its addresses, or send the name in the lookup box THROUGH it
-- without switching to it — which is the question the panel could not answer
-- before, since the tester only ever queried the resolver already in use.

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
-- hyphen, 253 chars max — the DNS wire-format limit). Since 0.2.0 the lookup
-- runs as an argv (plugin_api >= 24), so there is no shell to defend against
-- and no quoting to get right: the name is one argument, whatever is in it.
-- This check is now only about not sending an obviously-wrong query at all.
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
--
-- `serverOverride` ({ ip, label }) aims the query at a provider that is NOT
-- active — the row menu's lookup entry — which is a read-only question about
-- that resolver and changes no configuration at all.
local function runResolve(serverOverride)
    local name = trim(resolveQuery)
    if not isValidHostname(name) then
        resolveError = tr("resolve_invalid")
        resolveResult = nil
        render()
        return
    end

    local server = serverOverride or activeServerInfo()
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
        cmd = { "dig", "+time=3", "+tries=1", "+short" }
        if server ~= nil then
            table.insert(cmd, "@" .. server.ip)
        end
        table.insert(cmd, name)
    else
        cmd = { "nslookup", name }
        if server ~= nil then
            table.insert(cmd, server.ip)
        end
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

-- The provider row's right-click menu (plugin_api >= 28). Only a ui.button's
-- onRightClick reports the pointer serial openContextMenu needs, and the row IS
-- a button, so it raises this itself. `onActivate` must NAME a global
-- (openContextMenu is a raw binding, not a UI tree prop, so closures are not
-- registered for it); the provider id rides along in `context` and onProviderMenu
-- looks the entry up again in the current snapshot rather than capturing it.
--
-- Apply stays enabled on the active row too: `nmcli con mod` + `device reapply`
-- is idempotent, so re-applying is a real action (it pushes the profile back
-- onto the live connection). That also guarantees the one enabled entry the
-- host requires, whatever the other two are doing.
local function openProviderMenu(entry, active, text)
    local hasIp = type(entry.ip) == "string" and entry.ip ~= ""
    local name = trim(resolveQuery)
    panel.openContextMenu({
        onActivate = "onProviderMenu",
        context = entry.id,
        items = {
            { kind = "header", label = text },
            { id = "apply", label = tr(active and "menu.reapply" or "menu.apply") },
            { id = "copy", label = tr("menu.copy"), enabled = hasIp },
            -- Named after the hostname it would send, so the entry says what
            -- it does; with nothing usable in the box it turns into the hint
            -- for how to make it work, disabled.
            {
                id = "test",
                label = isValidHostname(name) and tr("menu.test", { name = name }) or tr("menu.test_hint"),
                enabled = hasIp and isValidHostname(name),
            },
        },
    })
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
        onRightClick = function()
            openProviderMenu(entry, active, text)
        end,
    })
end

local function copyServers(text)
    if text == nil or text == "" then
        return
    end
    noctalia.copyToClipboard(text, "text/plain")
    noctalia.notify(tr("title"), tr("copied", { ip = text }))
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
    copyServers(text)
end

-- Dispatch for a provider row's context menu. `action` is the id of the entry
-- picked, `context` the provider id it was opened on — looked up again here,
-- since a poll may have replaced the whole list in between.
function onProviderMenu(action, context)
    if snapshot == nil or type(snapshot.list) ~= "table" then
        return
    end
    local entry = nil
    for _, candidate in ipairs(snapshot.list) do
        if candidate.id == context then
            entry = candidate
            break
        end
    end
    if entry == nil then
        return
    end
    if action == "apply" then
        requestApply(entry)
    elseif action == "copy" then
        copyServers(entry.ip)
    elseif action == "test" then
        local ip = type(entry.ip) == "string" and entry.ip:match("%S+") or nil
        if ip ~= nil then
            runResolve({ ip = ip, label = entry.label })
        end
    end
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
