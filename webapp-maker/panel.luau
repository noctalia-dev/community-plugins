--!nonstrict
-- Webapp Maker: a floating centered panel - a form that creates web-app
-- launchers, plus the list of installed web apps with one-click removal.
-- No bar widget; open the panel via IPC (bind it in your compositor):
--   noctalia msg panel-open umedbazarov/webapp-maker:panel
--
-- All real work happens in the bundled shell scripts (scripts/) through
-- noctalia.runAsync - the panel handlers only assemble commands, keeping
-- well inside the plugin CPU budget. webapp-launch.sh is copied into the
-- plugin's data directory on open, and .desktop entries reference that
-- stable copy, so launchers keep working across plugin updates.
--
-- ui.input is uncontrolled: value seeds once per formRev, edits flow
-- through named global onChange handlers into the `form` table.

local form = { name = "", url = "", flags = "", icon = "" }
local formRev = 0
local busy = false
local status = nil -- { ok = boolean, text = string }

local apps = {} -- installed web-app names (basename of the .desktop)
local deleting = {} -- name -> true while its removal runs

local render

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function cfg(key, fallback)
    -- getConfig returns nil until the setting is materialized in
    -- settings.toml; the manifest default is NOT substituted by the runtime.
    local value = noctalia.getConfig(key)
    if value == nil then
        return fallback
    end
    return value
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function normalizeUrl(url)
    if url ~= "" and url:match("^%a[%w+.%-]*:") == nil then
        return "https://" .. url
    end
    return url
end

local function scriptPath(name)
    return (noctalia.pluginDir() or ".") .. "/scripts/" .. name
end

-- The stable copy of the launch script that .desktop entries point at: the
-- data directory survives plugin updates, the materialized code dir may not.
local function launcherPath()
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and (dir .. "/webapp-launch") or nil
end

local launcherReady = false

local function ensureLauncher()
    local target = launcherPath()
    if target == nil then
        return
    end
    noctalia.runAsync("cp -f " .. shellQuote(scriptPath("webapp-launch.sh")) .. " " .. shellQuote(target)
        .. " && chmod +x " .. shellQuote(target), function(result)
        launcherReady = (result.exitCode or 1) == 0
    end)
end

-- Optional environment file sourced before install/launch commands (the
-- env_file setting) - e.g. to export HTTPS_PROXY for icon downloads.
local function envPrefix()
    local envFile = trim(tostring(cfg("env_file", "")))
    if envFile == "" then
        return ""
    end
    return ". " .. shellQuote(envFile) .. " 2>/dev/null; "
end

-- ── Installed list ──────────────────────────────────────────────────────────

local function refreshApps()
    local cmd = "grep -l '^Exec=.*webapp-launch' ~/.local/share/applications/*.desktop 2>/dev/null | tr '\\r' '\\n'"
    noctalia.runAsync(cmd, function(result)
        apps = {}
        for line in (result.stdout or ""):gmatch("[^\n]+") do
            local name = line:match("([^/]+)%.desktop%s*$")
            if name ~= nil then
                table.insert(apps, name)
            end
        end
        table.sort(apps)
        deleting = {}
        render()
    end)
end

local function removeApp(name)
    if deleting[name] == true then
        return
    end
    deleting[name] = true
    render()
    noctalia.runAsync("bash " .. shellQuote(scriptPath("webapp-remove.sh")) .. " " .. shellQuote(name) .. " 2>&1", function(result)
        if (result.exitCode or 1) ~= 0 then
            local out = trim(result.stdout)
            status = { ok = false, text = out ~= "" and out or tr("err_remove_failed") }
        else
            status = { ok = true, text = tr("ok_removed", { name = name }) }
        end
        refreshApps()
    end)
end

-- ── Field handlers (uncontrolled inputs accumulate into `form`) ─────────────

function onFld_name(v) form.name = tostring(v or "") end
function onFld_url(v) form.url = tostring(v or "") end
function onFld_flags(v) form.flags = tostring(v or "") end
function onFld_icon(v) form.icon = tostring(v or "") end

-- ── Creating ────────────────────────────────────────────────────────────────

local function create()
    if busy then
        return
    end

    local name = trim(form.name)
    local url = normalizeUrl(trim(form.url))
    if name == "" or url == "" then
        status = { ok = false, text = tr("err_required") }
        render()
        return
    end
    if name:find("/", 1, true) ~= nil then
        status = { ok = false, text = tr("err_slash") }
        render()
        return
    end

    busy = true
    status = nil
    render()

    local launcher = launcherPath()
    if launcher == nil then
        busy = false
        status = { ok = false, text = tr("err_failed") }
        render()
        return
    end
    if not launcherReady then
        -- The copy from onOpen may still be in flight on a very fresh open;
        -- fire it again so the .desktop never points at a missing file.
        ensureLauncher()
    end

    local args = { "--launcher " .. shellQuote(launcher) }
    local flags = trim(form.flags)
    if flags ~= "" then
        table.insert(args, "--flags " .. shellQuote(flags))
    end
    table.insert(args, shellQuote(name))
    table.insert(args, shellQuote(url))
    if trim(form.icon) ~= "" then
        table.insert(args, shellQuote(trim(form.icon)))
    end

    -- The script's output is a single error line at most, so 2>&1 is safe
    -- for the status label. env_file (optional) may export HTTPS_PROXY etc.
    -- for the icon download.
    local cmd = "{ " .. envPrefix() .. "bash " .. shellQuote(scriptPath("webapp-install.sh")) .. " "
        .. table.concat(args, " ") .. "; } 2>&1"

    noctalia.runAsync(cmd, function(result)
        busy = false
        if result.timedOut then
            status = { ok = false, text = tr("err_timeout") }
        elseif (result.exitCode or 1) ~= 0 then
            local out = trim(result.stdout)
            if #out > 200 then
                out = out:sub(-200)
            end
            status = { ok = false, text = out ~= "" and out or tr("err_failed") }
        else
            status = { ok = true, text = tr("ok_created", { name = name }) }
            -- A clean form for the next app; bumping formRev resets the
            -- inputs' identity, or the uncontrolled fields keep the old text.
            form = { name = "", url = "", flags = "", icon = "" }
            formRev += 1
        end
        refreshApps()
    end)
end

-- ── Render ──────────────────────────────────────────────────────────────────

local function field(key, labelKey, phKey)
    return ui.column({ gap = 2, align = "stretch" }, {
        ui.label({ text = tr(labelKey), fontSize = 11, color = "on_surface_variant" }),
        ui.input({
            key = "fld-" .. key .. "-" .. formRev,
            value = form[key],
            placeholder = tr(phKey),
            onChange = "onFld_" .. key,
        }),
    })
end

render = function()
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "world-plus", size = 18, color = "primary" }),
            ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({
                glyph = "close", variant = "ghost", tooltip = tr("tip_close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
        field("name", "field_name", "field_name_ph"),
        field("url", "field_url", "field_url_ph"),
        field("flags", "field_flags", "field_flags_ph"),
        field("icon", "field_icon", "field_icon_ph"),
    }

    if busy then
        table.insert(children, ui.label({ text = tr("status_busy"), fontSize = 11, color = "secondary" }))
    elseif status ~= nil then
        table.insert(children, ui.label({
            text = status.text,
            fontSize = 11,
            color = status.ok and "primary" or "error",
            maxLines = 3,
        }))
    end

    table.insert(children, ui.button({
        key = "create" .. (busy and "-off" or ""),
        text = tr("btn_create"),
        enabled = not busy,
        onClick = function()
            create()
        end,
    }))

    table.insert(children, ui.separator({}))
    table.insert(children, ui.label({ text = tr("installed_title"), fontSize = 11, color = "on_surface_variant" }))

    if #apps == 0 then
        table.insert(children, ui.label({ text = tr("installed_empty"), fontSize = 12, color = "on_surface_variant" }))
        table.insert(children, ui.spacer({ flexGrow = 1 }))
    else
        local rows = {}
        for _, name in ipairs(apps) do
            table.insert(rows, ui.row({ key = "app-" .. name, gap = 8, align = "center" }, {
                ui.label({ text = name, fontSize = 12, color = "on_surface", flexGrow = 1, maxLines = 1 }),
                ui.button({
                    key = "del-" .. name .. (deleting[name] and "-off" or ""),
                    glyph = "trash",
                    variant = "ghost",
                    enabled = deleting[name] ~= true,
                    tooltip = tr("tip_remove"),
                    onClick = function()
                        removeApp(name)
                    end,
                }),
            }))
        end
        table.insert(children, ui.scroll({ key = "apps", flexGrow = 1, gap = 4 }, rows))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onOpen(_context)
    -- A fresh form on every open: the panel is summoned to make a new web
    -- app, so previous input is not worth keeping.
    form = { name = "", url = "", flags = "", icon = "" }
    busy = false
    status = nil
    formRev += 1
    render()
    ensureLauncher()
    refreshApps()
end
