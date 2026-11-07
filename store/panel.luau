--!nonstrict
-- Software browser for Nix, Flatpak and Pacman. Every source is queried by its
-- own asynchronous backend call; stale replies are dropped by a request serial.
-- Transactions run in a detached worker and always need explicit confirmation.
local BACKEND = "@backend@"
if string.sub(BACKEND, 1, 1) == "@" then BACKEND = "noctalia-software" end

local ORDER = {"nix", "flatpak", "pacman"}
local LABEL = {all = "All", nix = "Nix", flatpak = "Flatpak", pacman = "Pacman"}
local GLYPH = {all = "apps", nix = "snowflake", flatpak = "package", pacman = "box"}
local TONE = {nix = "primary", flatpak = "secondary", pacman = "tertiary"}
local VIEWS = {"discover", "installed", "updates", "activity"}
local VIEW_LABELS = {"Discover", "Installed", "Updates", "Activity"}
local PAGE = 6

local sources, filter, view, query = {}, "all", "discover", ""
local resultsBy, merged, selected, history = {}, {}, 1, {}
local pending, job, busy, showLog = nil, {}, false, false
local open, serial, debounce, queued, searchRev = false, 0, 0, false, 0
local pulse, lastPoll, lastIndexPoll, message = 0, 0, 0, ""
-- appIconPath() searches icon themes synchronously; Noctalia gives each script
-- callback a 25 ms CPU budget, so new lookups are spread across frames.
local icons, iconLookups, iconsPending = {}, 0, false
local ICON_LOOKUPS_PER_RENDER = 2
local render, refresh, poll

-- ---- backend ----------------------------------------------------------------
local function call(args, callback, timeout)
    local argv = {BACKEND}
    for _, value in ipairs(args) do table.insert(argv, tostring(value)) end
    local started = noctalia.runAsync(argv, function(result)
        if not open then return end
        local value = noctalia.json.decode(result.stdout or "")
        if result.timedOut then callback(nil, "The " .. tostring(args[1]) .. " request timed out")
        elseif type(value) ~= "table" then callback(nil, "The software backend did not return valid data")
        elseif value.error then callback(nil, tostring(value.error))
        else callback(value, nil) end
    end, timeout or 30000)
    if not started then callback(nil, "Could not start the software backend") end
end

local function available(key) return sources[key] ~= nil and sources[key].available == true end

local function activeSources()
    local list = {}
    for _, key in ipairs(ORDER) do
        if (filter == "all" or filter == key) and available(key) then table.insert(list, key) end
    end
    return list
end

-- ---- merging & comparison ------------------------------------------------------
local function merge()
    merged = {}
    for _, key in ipairs(activeSources()) do
        local r = resultsBy[key]
        if r and r.items then for _, item in ipairs(r.items) do table.insert(merged, item) end end
    end
    if view == "discover" and query ~= "" then
        table.sort(merged, function(a, b)
            local sa, sb = a.score or 0, b.score or 0
            if sa ~= sb then return sa > sb end
            return string.lower(a.name) < string.lower(b.name)
        end)
    else
        table.sort(merged, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    end
    selected = math.max(1, math.min(selected, #merged))
end

local function alternatives(item)
    local found = {}
    for key, r in pairs(resultsBy) do
        if key ~= item.source and r.items then
            for _, other in ipairs(r.items) do
                if other.match_key == item.match_key or other.alt_key == item.match_key
                    or other.match_key == item.alt_key then
                    table.insert(found, other)
                    break
                end
            end
        end
    end
    return found
end

-- ---- actions ---------------------------------------------------------------------
local function primaryAction(item)
    if item.protected then return nil end
    if item.update_available and item.source == "flatpak" then return "update" end
    if item.installed then
        if item.source == "nix" and not item.managed then return nil end
        return "remove"
    end
    return "install"
end

local function actionLabel(op, source)
    if op == "install" then return "Install with " .. LABEL[source] end
    if op == "remove" then return "Remove" end
    if op == "update" then return "Update" end
    return op
end

local function explain(op, item, source)
    local src = sources[source] or {}
    if source == "nix" and (op == "update-system" or op == "rebuild") then
        return "Builds the complete NixOS system before activating it and keeps the previous generation for rollback. Requires administrator authentication."
    elseif source == "nix" and src.mode == "system" then
        return (op == "install" and "Adds " or "Removes ") .. item.pkg ..
            (op == "install" and " to" or " from") .. " the installer's managed NixOS package list, builds the whole system, then activates it. A failed build restores the list. Requires administrator authentication."
    elseif source == "nix" then
        return (op == "install" and "Installs into" or "Removes from") .. " your per-user nix profile. No administrator rights needed." ..
            (item.unfree and " This package has an unfree license." or "")
    elseif source == "flatpak" then
        if op == "add-remote" then return "Adds https://dl.flathub.org/repo/flathub.flatpakrepo as a per-user remote. Downloads its metadata." end
        if op == "refresh" then return "Downloads fresh application metadata for this remote." end
        return "Runs flatpak " .. op .. " for the " .. tostring(item.scope) .. " installation from " .. tostring(item.remote) ..
            "." .. (item.scope == "system" and " System installations ask for authentication." or "")
    elseif source == "pacman" then
        if op == "upgrade-system" then return "Runs pacman -Syu: refreshes the databases and upgrades every package (no partial upgrades). Requires administrator authentication." end
        return "Runs pacman " .. (op == "install" and "-S --needed" or "-R") .. " " .. item.pkg ..
            ". Dependency conflicts are shown in the log. Requires administrator authentication."
    end
    return ""
end

local function propose(op, item, source, ident, title)
    if busy then return end
    pending = {op = op, item = item or {}, source = source or item.source, id = ident or (item and item.id) or "",
        title = title or (actionLabel(op, source or item.source) .. " · " .. (item and item.name or "")),
        unfree = item and item.unfree or false}
    pending.detail = explain(op, pending.item, pending.source)
    render()
end

local function apply()
    if not pending or busy then return end
    local request = pending
    pending, busy, showLog = nil, true, true
    job = {state = "running", message = "Starting…", summary = request.title}
    local args = {"start", "--source", request.source, "--op", request.op, "--id", request.id, "--confirmed"}
    if request.unfree then table.insert(args, "--unfree") end
    call(args, function(_value, err)
        if err then busy = false; job = {state = "failed", message = err} end
        lastPoll = 0
        render()
    end)
    render()
end

-- ---- loading -------------------------------------------------------------------------
refresh = function()
    serial += 1
    local request = serial
    if view == "activity" then
        call({"history"}, function(value, err)
            if request ~= serial then return end
            history = value and value.history or {}
            message = err or ""
            render()
        end)
        render()
        return
    end
    resultsBy = {}
    for _, key in ipairs(activeSources()) do
        resultsBy[key] = {state = "loading", items = {}}
        local args
        if view == "discover" then args = {"search", "--source", key, "--query", query}
        elseif view == "installed" then args = {"installed", "--source", key}
        else args = {"updates", "--source", key} end
        call(args, function(value, err)
            if request ~= serial then return end
            if err then resultsBy[key] = {state = "error", message = err, items = {}}
            else resultsBy[key] = value end
            merge()
            render()
        end, view == "updates" and 45000 or 30000)
    end
    merge()
    render()
end

local function loadSources()
    call({"sources"}, function(value, err)
        if err then message = err; render(); return end
        sources = {}
        for _, info in ipairs(value.sources or {}) do sources[info.key] = info end
        if filter ~= "all" and not available(filter) then filter = "all" end
        refresh()
    end)
end

poll = function()
    call({"status"}, function(value, _err)
        if not value then return end
        local wasBusy = busy
        job = value
        busy = value.state == "running"
        if wasBusy and not busy then loadSources() end
        render()
    end)
end

-- ---- view helpers ---------------------------------------------------------------------
local function badge(text, tone)
    return ui.row({paddingH = 7, paddingV = 2, radius = 6, fill = tone .. "/0.16"}, {
        ui.label({text = text, fontSize = 11, fontWeight = "bold", color = tone}),
    })
end

local function iconFor(item, size)
    if item.icon and item.icon ~= "" then return ui.image({path = item.icon, width = size, height = size, radius = 6}) end
    local key = item.pkg or item.name
    if icons[key] == nil then
        if iconLookups >= ICON_LOOKUPS_PER_RENDER then
            iconsPending = true
            return ui.glyph({name = GLYPH[item.source] or "package", size = size - 6, color = TONE[item.source] or "primary"})
        end
        iconLookups += 1
        icons[key] = noctalia.appIconPath(key, size) or false
    end
    if icons[key] then return ui.image({path = icons[key], width = size, height = size}) end
    return ui.glyph({name = GLYPH[item.source] or "package", size = size - 6, color = TONE[item.source] or "primary"})
end

local function stateBadge(item)
    if item.update_available then return badge("Update " .. tostring(item.new_version or ""), "tertiary") end
    if item.protected then return badge("In system config", "on_surface_variant") end
    if item.installed then return badge("Installed", "primary") end
    if item.installed_elsewhere then return badge("Installed elsewhere", "on_surface_variant") end
    return nil
end

local function resultRow(i, item)
    local isSelected = i == selected
    local op = primaryAction(item)
    local right = {}
    local state = stateBadge(item)
    table.insert(right, badge(LABEL[item.source], TONE[item.source]))
    if state then table.insert(right, state) end
    return ui.row({key = item.source .. ":" .. item.id, gap = 12, padding = 10, radius = 10, align = "center",
        fill = isSelected and "primary/0.12" or "surface_container",
        border = isSelected and "primary/0.55" or "surface_container", borderWidth = 1,
        onClick = function() selected = i; render() end}, {
        iconFor(item, 36),
        ui.column({gap = 3, flexGrow = 1}, {
            ui.label({text = item.name .. ((item.version or "") ~= "" and ("  " .. item.version) or ""), fontWeight = "bold", maxLines = 1}),
            ui.label({text = item.summary ~= "" and item.summary or item.origin or "", color = "on_surface_variant", fontSize = 12, maxLines = 1}),
        }),
        ui.row({gap = 6, align = "center"}, right),
        op and ui.button({text = actionLabel(op, item.source), controlSize = "sm",
            variant = op == "remove" and "outline" or "primary", enabled = not busy,
            onClick = function() selected = i; propose(op, item) end}) or nil,
    })
end

local function detailPane(item)
    if not item then
        return ui.column({width = 320, gap = 8, padding = 16, radius = 12, fill = "surface_container", align = "center"}, {
            ui.glyph({name = "info-circle", size = 28, color = "on_surface_variant"}),
            ui.label({text = "Select an application to see its details", color = "on_surface_variant", textAlign = "center", maxLines = 2}),
        })
    end
    local rows = {
        ui.row({gap = 12, align = "center"}, {
            iconFor(item, 56),
            ui.column({gap = 3, flexGrow = 1}, {
                ui.label({text = item.name, fontSize = 18, fontWeight = "bold", maxLines = 2}),
                ui.label({text = (item.version or "") ~= "" and ("Version " .. item.version) or "Version unknown", color = "on_surface_variant", fontSize = 12}),
            }),
        }),
        ui.row({gap = 6}, {badge(LABEL[item.source], TONE[item.source]), stateBadge(item) or ui.spacer({}),
            item.unfree and badge("Unfree", "error") or ui.spacer({})}),
    }
    if (item.summary or "") ~= "" then table.insert(rows, ui.label({text = item.summary, maxLines = 4})) end
    local facts = {
        {"Source", tostring(item.origin or LABEL[item.source])},
        {"Package", tostring(item.pkg or item.id)},
        {"Publisher", tostring(item.publisher or "")},
        {"License", tostring(item.license or "")},
        {"Website", tostring(item.homepage or "")},
    }
    if item.installed_version and item.installed_version ~= "" and item.installed_version ~= item.version then
        table.insert(facts, {"Installed", item.installed_version})
    end
    for _, fact in ipairs(facts) do
        if fact[2] ~= "" then
            table.insert(rows, ui.column({gap = 1}, {
                ui.label({text = fact[1], fontSize = 11, color = "on_surface_variant"}),
                ui.label({text = fact[2], fontSize = 12, maxLines = 2}),
            }))
        end
    end
    local op = primaryAction(item)
    local buttons = {}
    if op then
        table.insert(buttons, ui.button({text = actionLabel(op, item.source), glyph = op == "install" and "download" or op == "update" and "refresh" or "trash",
            variant = op == "remove" and "destructive" or "primary", enabled = not busy, onClick = function() propose(op, item) end}))
    end
    if op == "update" then
        table.insert(buttons, ui.button({text = "Remove", variant = "outline", enabled = not busy, onClick = function() propose("remove", item) end}))
    end
    if item.protected then
        table.insert(rows, ui.label({text = "Installed by your NixOS configuration outside this installer, so it cannot be removed here.", color = "on_surface_variant", fontSize = 12, maxLines = 3}))
    end
    if #buttons > 0 then table.insert(rows, ui.row({gap = 8}, buttons)) end
    local others = alternatives(item)
    if #others > 0 then
        table.insert(rows, ui.separator({}))
        table.insert(rows, ui.label({text = "Also available from", fontWeight = "bold", fontSize = 12}))
        for _, other in ipairs(others) do
            local otherOp = primaryAction(other)
            table.insert(rows, ui.row({key = "alt-" .. other.source .. other.id, gap = 8, align = "center"}, {
                badge(LABEL[other.source], TONE[other.source]),
                ui.label({text = tostring(other.version or "?") .. (other.installed and " · installed" or ""), fontSize = 12, flexGrow = 1, maxLines = 1}),
                otherOp and ui.button({text = otherOp == "install" and "Install" or actionLabel(otherOp, other.source), controlSize = "sm",
                    enabled = not busy, onClick = function() propose(otherOp, other) end}) or nil,
            }))
        end
    end
    return ui.scroll({key = "detail", width = 320, gap = 10, padding = 16, radius = 12, fill = "surface_container"}, rows)
end

local function sourceChips()
    local chips = {}
    for _, key in ipairs({"all", "nix", "flatpak", "pacman"}) do
        local ok = key == "all" or available(key)
        local reason = key ~= "all" and sources[key] and sources[key].reason or ""
        table.insert(chips, ui.button({text = LABEL[key], glyph = GLYPH[key], controlSize = "sm",
            variant = filter == key and "primary" or "outline", selected = filter == key, enabled = ok,
            tooltip = ok and ((sources[key] and sources[key].detail) or ("Show " .. LABEL[key] .. " results")) or reason,
            onClick = function() filter = key; selected = 1; pending = nil; refresh() end}))
    end
    table.insert(chips, ui.spacer({flexGrow = 1}))
    local status = {}
    for _, key in ipairs(activeSources()) do
        local r = resultsBy[key] or {}
        local text = r.state == "loading" and "…" or r.state == "indexing" and "indexing" or r.state == "error" and "error"
            or tostring(r.total or #(r.items or {}))
        table.insert(status, LABEL[key] .. " " .. text)
    end
    for _, key in ipairs(ORDER) do
        if not available(key) and sources[key] and filter == "all" then table.insert(status, LABEL[key] .. " off") end
    end
    table.insert(chips, ui.label({text = table.concat(status, " · "), color = "on_surface_variant", fontSize = 12}))
    return ui.row({gap = 8, align = "center"}, chips)
end

local function notices()
    local list = {}
    for _, key in ipairs(activeSources()) do
        local r = resultsBy[key]
        if r and (r.message or "") ~= "" and (r.state ~= "ok" or view ~= "discover") then
            table.insert(list, ui.row({gap = 8, align = "center"}, {
                ui.glyph({name = r.state == "error" and "alert-circle" or "info-circle", size = 16, color = r.state == "error" and "error" or "on_surface_variant"}),
                ui.label({text = LABEL[key] .. ": " .. r.message, fontSize = 12, color = r.state == "error" and "error" or "on_surface_variant", maxLines = 2, flexGrow = 1}),
            }))
        elseif r and (r.message or "") ~= "" then
            table.insert(list, ui.label({text = LABEL[key] .. ": " .. r.message, fontSize = 12, color = "on_surface_variant", maxLines = 2}))
        end
    end
    local flatpak = sources.flatpak
    if flatpak and flatpak.available and flatpak.needs_remote and (filter == "all" or filter == "flatpak") then
        table.insert(list, ui.row({gap = 10, padding = 10, radius = 10, align = "center", border = "secondary/0.5", borderWidth = 1}, {
            ui.glyph({name = "package", size = 20, color = "secondary"}),
            ui.label({text = "Flatpak has no remote configured, so there is nothing to browse yet.", flexGrow = 1, maxLines = 2}),
            ui.button({text = "Add Flathub…", controlSize = "sm", enabled = not busy,
                onClick = function() propose("add-remote", {name = "Flathub"}, "flatpak", "flathub", "Add the Flathub remote (per user)") end}),
        }))
    end
    if view == "updates" then
        local actions = {}
        if available("nix") and sources.nix.mode == "system" and (filter == "all" or filter == "nix") then
            table.insert(actions, ui.button({text = "Update NixOS system…", glyph = "snowflake", controlSize = "sm", enabled = not busy,
                onClick = function() propose("update-system", {name = "NixOS"}, "nix", "", "Update nixpkgs and rebuild NixOS") end}))
        end
        if available("flatpak") and (filter == "all" or filter == "flatpak") then
            for _, remote in ipairs(sources.flatpak.remotes or {}) do
                table.insert(actions, ui.button({text = "Refresh " .. remote.name .. " (" .. remote.scope .. ")", glyph = "refresh", controlSize = "sm", enabled = not busy,
                    onClick = function() propose("refresh", {name = remote.name, scope = remote.scope, remote = remote.name}, "flatpak", remote.scope .. "/" .. remote.name, "Refresh " .. remote.name .. " metadata") end}))
            end
        end
        if available("pacman") and (filter == "all" or filter == "pacman") then
            table.insert(actions, ui.button({text = "Full system upgrade…", glyph = "box", controlSize = "sm", enabled = not busy,
                onClick = function() propose("upgrade-system", {name = "system"}, "pacman", "", "Full pacman system upgrade") end}))
        end
        if #actions > 0 then table.insert(list, ui.row({gap = 8}, actions)) end
    end
    return list
end

local function jobCard()
    if not job or job.state == nil or job.state == "idle" then return nil end
    local running = job.state == "running"
    local tone = job.state == "failed" and "error" or job.state == "interrupted" and "error" or "primary"
    local children = {
        ui.row({gap = 10, align = "center"}, {
            ui.glyph({name = running and "loader-2" or job.state == "complete" and "circle-check" or "alert-circle", size = 20, color = tone}),
            ui.column({gap = 2, flexGrow = 1}, {
                ui.label({text = tostring(job.summary or "Package operation"), fontWeight = "bold", maxLines = 1}),
                ui.label({text = tostring(job.message or ""), fontSize = 12, color = tone, maxLines = 3}),
            }),
            ui.button({text = showLog and "Hide log" or "Show log", controlSize = "sm", onClick = function() showLog = not showLog; render() end}),
            (not running) and ui.button({glyph = "x", controlSize = "sm", tooltip = "Dismiss", onClick = function() job = {}; showLog = false; render() end}) or nil,
        }),
    }
    if running then
        table.insert(children, ui.progress({progress = job.progress or pulse, height = 6, radius = 3}))
    end
    if showLog then
        table.insert(children, ui.scroll({key = "log", height = 150, stickToBottom = true, fill = "surface", radius = 8, padding = 8}, {
            ui.label({text = (job.log or "") ~= "" and job.log or "No output yet", fontFamily = "monospace", fontSize = 11, maxLines = 200}),
        }))
    end
    return ui.column({gap = 8, padding = 12, radius = 12, fill = "surface_container", border = tone .. "/0.4", borderWidth = 1}, children)
end

local function confirmCard()
    return ui.column({gap = 10, padding = 16, radius = 12, fill = "surface_container", border = (pending.op == "remove" and "error" or "primary") .. "/0.6", borderWidth = 1}, {
        ui.row({gap = 10, align = "center"}, {
            ui.glyph({name = pending.op == "remove" and "trash" or "shield-check", size = 22, color = pending.op == "remove" and "error" or "primary"}),
            ui.label({text = pending.title .. "?", fontSize = 16, fontWeight = "bold", maxLines = 2, flexGrow = 1}),
        }),
        ui.label({text = pending.detail, maxLines = 5}),
        ui.row({gap = 10}, {
            ui.button({text = "Cancel", onClick = function() pending = nil; render() end}),
            ui.button({text = pending.op == "remove" and "Remove" or "Continue", variant = pending.op == "remove" and "destructive" or "primary", onClick = apply}),
            ui.label({text = "Ctrl+Enter confirms · Esc closes", fontSize = 11, color = "on_surface_variant"}),
        }),
    })
end

local function emptyState()
    local loading, indexing = false, false
    for _, key in ipairs(activeSources()) do
        local r = resultsBy[key] or {}
        if r.state == "loading" then loading = true end
        if r.state == "indexing" then indexing = true end
    end
    local text = "No results"
    if #activeSources() == 0 then text = "No package source is available. Hover the source buttons for details."
    elseif loading then text = "Searching…"
    elseif indexing then text = "Building the package index…"
    elseif view == "discover" and query == "" then text = "Featured results load here; type to search"
    elseif view == "updates" then text = "Everything is up to date"
    elseif view == "installed" then text = "Nothing installed from these sources" end
    return ui.column({gap = 8, padding = 32, align = "center"}, {
        ui.glyph({name = loading and "loader-2" or "search", size = 30, color = "on_surface_variant"}),
        ui.label({text = text, color = "on_surface_variant", textAlign = "center", maxLines = 3}),
    })
end

render = function()
    if not open then return end
    iconLookups, iconsPending = 0, false
    local viewIndex = 0
    for i, v in ipairs(VIEWS) do if v == view then viewIndex = i - 1 end end
    local children = {
        ui.row({gap = 12, align = "center"}, {
            ui.glyph({name = "packages", size = 28, color = "primary"}),
            ui.column({gap = 2, flexGrow = 1}, {
                ui.label({text = "Noctalia Store", fontSize = 22, fontWeight = "bold"}),
                ui.label({text = "Nix · Flatpak · Pacman", color = "on_surface_variant", fontSize = 12}),
            }),
            ui.select({options = VIEW_LABELS, selectedIndex = viewIndex, width = 140, controlSize = "sm",
                onChange = function(index) view = VIEWS[(tonumber(index) or 0) + 1] or "discover"; selected = 1; pending = nil; refresh() end}),
            ui.button({glyph = "refresh", tooltip = "Reload sources · Ctrl+R", controlSize = "sm", onClick = function() loadSources() end}),
            ui.button({glyph = "x", tooltip = "Close · Esc", controlSize = "sm", onClick = function() panel.close() end}),
        }),
        ui.input({key = "search-" .. tostring(searchRev), value = query, focus = true,
            placeholder = view == "discover" and "Search applications and packages" or "Search is available in Discover",
            enabled = view == "discover",
            onChange = function(value) query = value; queued = true; debounce = 280; selected = 1; panel.setNeedsFrameTick(true) end,
            onSubmit = function()
                local item = merged[selected]
                local op = item and primaryAction(item)
                if op then propose(op, item) end
            end}),
        sourceChips(),
    }
    if message ~= "" then table.insert(children, ui.label({text = message, color = "error", fontSize = 12, maxLines = 2})) end
    for _, notice in ipairs(notices()) do table.insert(children, notice) end
    local card = jobCard()
    if card then table.insert(children, card) end
    if pending then table.insert(children, confirmCard()) end

    if view == "activity" then
        local list = {}
        for i = 1, math.min(80, #history) do
            local entry = history[i]
            local ok = entry.state == "complete"
            table.insert(list, ui.row({key = "h" .. tostring(i), gap = 10, padding = 10, radius = 10, fill = "surface_container", align = "center"}, {
                ui.glyph({name = ok and "circle-check" or "alert-circle", size = 18, color = ok and "primary" or "error"}),
                ui.column({gap = 2, flexGrow = 1}, {
                    ui.label({text = tostring(entry.op) .. " " .. tostring(entry.id or ""), fontWeight = "bold", maxLines = 1}),
                    ui.label({text = tostring(entry.time) .. " · " .. tostring(entry.message or ""), fontSize = 12, color = "on_surface_variant", maxLines = 2}),
                }),
                badge(LABEL[entry.source] or tostring(entry.source), TONE[entry.source] or "primary"),
            }))
        end
        if #list == 0 then table.insert(list, ui.label({text = "No operations yet", color = "on_surface_variant"})) end
        table.insert(children, ui.scroll({key = "history", gap = 8, flexGrow = 1}, list))
    else
        local list = {}
        local start = math.floor((selected - 1) / PAGE) * PAGE + 1
        for i = start, math.min(start + PAGE - 1, #merged) do table.insert(list, resultRow(i, merged[i])) end
        if #list == 0 then table.insert(list, emptyState()) end
        if #merged > PAGE then
            table.insert(list, ui.row({gap = 8, align = "center"}, {
                ui.button({text = "Previous", controlSize = "sm", enabled = start > 1, onClick = function() selected = math.max(1, start - PAGE); render() end}),
                ui.label({text = tostring(start) .. "–" .. tostring(math.min(start + PAGE - 1, #merged)) .. " of " .. tostring(#merged), flexGrow = 1, textAlign = "center", fontSize = 12}),
                ui.button({text = "Next", controlSize = "sm", enabled = start + PAGE <= #merged, onClick = function() selected = math.min(#merged, start + PAGE); render() end}),
            }))
        end
        table.insert(children, ui.row({gap = 12, flexGrow = 1}, {
            ui.scroll({key = "results-" .. tostring(serial), gap = 8, flexGrow = 1}, list),
            detailPane(merged[selected]),
        }))
    end
    table.insert(children, ui.label({text = "↑ ↓ select · Enter act · Ctrl+1–4 source · Ctrl+F search · Ctrl+L log · Esc close",
        color = "on_surface_variant", fontSize = 11}))
    panel.render(ui.column({gap = 10, padding = 8, flexGrow = 1}, children))
    if iconsPending then panel.setNeedsFrameTick(true) end
end

-- ---- lifecycle ------------------------------------------------------------------------
function onOpen()
    open, pending = true, nil
    panel.setWantsSecondTicks(true)
    render()
    loadSources()
    poll()
end

function onClose()
    open = false
    serial += 1
    pending = nil
end

function update()
    local now = os.time()
    if busy and now - lastPoll >= 1 then lastPoll = now; poll() end
    local indexing = false
    for _, r in pairs(resultsBy) do if r.state == "indexing" then indexing = true end end
    if indexing and now - lastIndexPoll >= 3 then lastIndexPoll = now; refresh() end
    if busy and (job.progress == nil) then panel.setNeedsFrameTick(true) end
end

function onFrameTick(deltaMs)
    local animating = busy and job.progress == nil
    if animating then pulse = (pulse + deltaMs / 1600) % 1 end
    if animating or iconsPending then render() end
    if queued then
        debounce -= deltaMs
        if debounce <= 0 then queued = false; refresh() end
    end
    if not queued and not animating and not iconsPending then panel.setNeedsFrameTick(false) end
end

function onKey(chord, pressed)
    if not pressed then return end
    if chord == "ctrl+Return" and pending then apply(); return end
    if chord == "ctrl+f" then searchRev += 1; view = "discover"; render(); return end
    if chord == "ctrl+r" then loadSources(); return end
    if chord == "ctrl+l" then showLog = not showLog; render(); return end
    local keys = {["ctrl+1"] = "all", ["ctrl+2"] = "nix", ["ctrl+3"] = "flatpak", ["ctrl+4"] = "pacman"}
    if keys[chord] then
        if keys[chord] == "all" or available(keys[chord]) then filter = keys[chord]; selected = 1; refresh() end
        return
    end
    if chord == "down" then selected = math.min(#merged, selected + 1); render()
    elseif chord == "up" then selected = math.max(1, selected - 1); render() end
end
