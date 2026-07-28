--!nonstrict
-- arch-updater update panel. Pure renderer over the shared state: the engine
-- (service.luau) publishes "arch_state" and performs the "arch_request"
-- actions this panel emits, so closing the panel never interrupts a check or
-- a run in progress.
--
-- "Check Updates" only queries pacman, the AUR helper and (optionally)
-- Flatpak. Only then do "Update" (open a terminal and run the upgrade) and
-- "Dismiss" (keep the numbers, quiet the bar) light up.

local STATE_KEY = "arch_state"
local REQUEST_KEY = "arch_request"

local snapshot = nil
local expanded = {} -- source key -> the package list is open
local hoverKey = nil -- package row currently under the pointer
local hoverText = "" -- what the detail line shows
local listOpen = false -- at least one source is expanded this render

local render

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function request(action)
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, action = action })
end

local function shellQuote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function openUrl(url)
    if not noctalia.commandExists("xdg-open") then
        noctalia.notifyError(tr("title"), tr("err_no_xdg_open"))
        return
    end
    noctalia.runAsync("xdg-open " .. shellQuote(url) .. " >/dev/null 2>&1")
end

-- Opens a generic Arch package search instead of a per-repo mirror URL, so
-- it stays correct across Arch-based distros.
local function openPackage(sourceKey, name)
    if sourceKey == "pacman" then
        openUrl("https://archlinux.org/packages/?q=" .. noctalia.string.urlEncode(name))
    elseif sourceKey == "aur" then
        openUrl("https://aur.archlinux.org/packages/" .. noctalia.string.urlEncode(name))
    elseif sourceKey == "flatpak" then
        openUrl("https://flathub.org/apps/" .. noctalia.string.urlEncode(name))
    end
end

local function detailFor(item)
    local from = item.from ~= nil and item.from or ""
    local to = item.to ~= nil and item.to or ""
    if to == "" then
        return item.name
    end
    if from == "" then
        return item.name .. "  → " .. to
    end
    return item.name .. "  " .. from .. " → " .. to
end

local function phaseOf()
    return snapshot ~= nil and snapshot.phase or "idle"
end

local function totalOf()
    return snapshot ~= nil and tonumber(snapshot.total) or 0
end

local function busy()
    local phase = phaseOf()
    return phase == "checking" or phase == "running"
end

-- Only "checking" blocks a new check: "running" still allows one, since it
-- doubles as a manual unstick if the update's process-poll heuristic ever
-- misses the terminal finishing.
local function checking()
    return phaseOf() == "checking"
end

local function headline()
    local phase = phaseOf()
    if phase == "missing" then
        return tr("status_missing"), "error"
    elseif phase == "error" then
        return (snapshot ~= nil and snapshot.err) or tr("status_error"), "error"
    elseif phase == "checking" then
        local step = snapshot.step
        if step ~= nil and step ~= "" then
            return tr("status_checking_step", { step = step }), "secondary"
        end
        return tr("status_checking"), "secondary"
    elseif phase == "running" then
        return tr("status_running"), "secondary"
    elseif phase == "clean" then
        return tr("status_clean"), "on_surface"
    elseif phase == "ready" then
        return noctalia.trp("status_ready", totalOf(), {}), "primary"
    end
    return tr("status_idle"), "on_surface_variant"
end

local VERSION_WIDTH = 78

local function sourceLabel(key, entry)
    if key == "aur" and type(entry.helper) == "string" and entry.helper ~= "" then
        return tr("source.aur_named", { helper = entry.helper })
    end
    return tr("source." .. key)
end

-- pacman, then the AUR helper, then Flatpak. Only sources with pending
-- packages, biggest first.
local function orderedSources()
    if snapshot == nil then
        return {}
    end
    local candidates = {
        { key = "pacman", entry = snapshot.pacman },
        { key = "aur", entry = snapshot.aur },
        { key = "flatpak", entry = snapshot.flatpak },
    }
    local pending = {}
    for _, candidate in ipairs(candidates) do
        if type(candidate.entry) == "table" and (candidate.entry.n or 0) > 0 then
            table.insert(pending, candidate)
        end
    end
    table.sort(pending, function(a, b)
        return a.entry.n > b.entry.n
    end)
    return pending
end

local function cleanSources()
    if snapshot == nil then
        return {}
    end
    local names = {}
    local candidates = { { key = "pacman", entry = snapshot.pacman }, { key = "flatpak", entry = snapshot.flatpak } }
    if snapshot.aur ~= nil and (snapshot.aur.n or 0) == 0 and noctalia.getConfig("aur_helper") ~= "off" then
        table.insert(candidates, { key = "aur", entry = snapshot.aur })
    end
    for _, candidate in ipairs(candidates) do
        if type(candidate.entry) == "table" and (candidate.entry.n or 0) == 0 then
            table.insert(names, sourceLabel(candidate.key, candidate.entry))
        end
    end
    return names
end

local function packageRow(sourceKey, index, item)
    local key = "pkg-" .. sourceKey .. "-" .. index
    local children = {
        ui.label({ text = item.name, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 1 }),
    }
    local from = item.from ~= nil and item.from or ""
    local to = item.to ~= nil and item.to or ""
    if to ~= "" then
        if from ~= "" then
            table.insert(children, ui.label({
                text = from, fontSize = 11, color = "on_surface_variant", maxWidth = VERSION_WIDTH, maxLines = 1,
            }))
        end
        table.insert(children, ui.label({ text = "→", fontSize = 11, color = "on_surface_variant" }))
        table.insert(children, ui.label({
            text = to, fontSize = 11, color = "primary", fontWeight = "semibold", maxWidth = VERSION_WIDTH, maxLines = 1,
        }))
    end
    table.insert(children, ui.button({
        glyph = "copy", variant = "ghost", controlSize = "sm", tooltip = tr("tip_copy"),
        onClick = function()
            noctalia.copyToClipboard(detailFor(item), "text/plain")
        end,
    }))
    table.insert(children, ui.button({
        glyph = "external-link", variant = "ghost", controlSize = "sm", tooltip = tr("tip_open_page"),
        onClick = function()
            openPackage(sourceKey, item.name)
        end,
    }))
    return ui.row({
        key = key,
        paddingH = 18,
        gap = 4,
        align = "center",
        onHover = function(state)
            if state == "true" then
                hoverKey = key
                hoverText = detailFor(item)
            elseif hoverKey == key then
                hoverKey = nil
                hoverText = ""
            else
                return
            end
            render()
        end,
    }, children)
end

local function sourceRows()
    local rows = {}
    for _, source in ipairs(orderedSources()) do
        local names = type(source.entry.items) == "table" and source.entry.items or {}
        local open = expanded[source.key] == true and #names > 0
        listOpen = listOpen or open
        local header = { gap = 8, align = "center", key = "src-" .. source.key .. (open and "-open" or "") }
        if #names > 0 then
            local sourceKey = source.key
            header.onClick = function()
                expanded[sourceKey] = not expanded[sourceKey]
                hoverKey = nil
                hoverText = ""
                render()
            end
        end
        table.insert(rows, ui.row(header, {
            ui.glyph({ name = #names == 0 and "point" or (open and "chevron-down" or "chevron-right"), size = 12, color = "on_surface_variant" }),
            ui.label({ text = sourceLabel(source.key, source.entry), color = "on_surface", flexGrow = 1 }),
            ui.label({ text = tostring(source.entry.n), color = "primary", fontWeight = "bold" }),
        }))

        if open then
            for index, item in ipairs(names) do
                table.insert(rows, packageRow(source.key, index, item))
            end
            if source.entry.n > #names then
                table.insert(rows, ui.row({ key = "more-" .. source.key, paddingH = 18 }, {
                    ui.label({ text = tr("more_packages", { count = source.entry.n - #names }), fontSize = 11, color = "on_surface_variant" }),
                }))
            end
        end
    end
    return rows
end

-- Download size, reboot recommendation and Arch news. Each is its own line,
-- so turning one off in settings just removes that line.
local function extras()
    local lines = {}
    if snapshot == nil then
        return lines
    end

    if type(snapshot.downloadSizeMiB) == "number" then
        local size = snapshot.downloadSizeMiB
        local text = size >= 1024 and tr("size_gib", { value = string.format("%.2f", size / 1024) })
            or tr("size_mib", { value = string.format("%.1f", size) })
        table.insert(lines, ui.row({ key = "size", gap = 6, align = "center" }, {
            ui.glyph({ name = "download", size = 13, color = "on_surface_variant" }),
            ui.label({ text = text, fontSize = 12, color = "on_surface_variant" }),
        }))
    end

    if snapshot.rebootRecommended == true then
        table.insert(lines, ui.row({ key = "reboot", gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-triangle", size = 13, color = "warning" }),
            ui.label({ text = tr("reboot_recommended"), fontSize = 12, color = "warning", flexGrow = 1 }),
        }))
    end

    if (snapshot.newsUnread or 0) > 0 then
        table.insert(lines, ui.row({ key = "news", gap = 6, align = "center" }, {
            ui.glyph({ name = "news", size = 13, color = "on_surface" }),
            ui.label({
                text = noctalia.trp("news_unread", snapshot.newsUnread, { title = snapshot.newsLatestTitle or "" }),
                fontSize = 12,
                color = "on_surface",
                flexGrow = 1,
                maxLines = 2,
            }),
            ui.button({
                text = tr("action_open_news"), variant = "ghost", controlSize = "sm",
                onClick = function()
                    request("open_news")
                end,
            }),
        }))
    end

    return lines
end

local function body()
    local children = {}

    local rows = sourceRows()
    if #rows > 0 then
        table.insert(children, ui.scroll({ key = "sources", flexGrow = 1, gap = 6 }, rows))
    else
        table.insert(children, ui.spacer({ key = "filler", flexGrow = 1 }))
    end

    if listOpen then
        table.insert(children, ui.label({
            key = "hover-detail",
            text = hoverText ~= "" and hoverText or tr("hover_hint"),
            fontSize = 11,
            color = hoverText ~= "" and "on_surface" or "on_surface_variant",
            maxLines = 1,
        }))
    end

    for _, line in ipairs(extras()) do
        table.insert(children, line)
    end

    local clean = cleanSources()
    if #clean > 0 then
        table.insert(children, ui.label({
            text = tr("up_to_date", { sources = table.concat(clean, ", ") }),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 2,
        }))
    end

    return children
end

local function footerCaption()
    if snapshot == nil or snapshot.checkedAt == nil or snapshot.checkedAt == "" then
        return nil
    end
    local parts = { tr("caption_checked", { time = snapshot.checkedAt }) }
    local ignored = tonumber(snapshot.ignoredCount) or 0
    if ignored > 0 then
        table.insert(parts, noctalia.trp("caption_ignored", ignored, {}))
    end
    return table.concat(parts, "  ·  ")
end

render = function()
    listOpen = false

    local text, color = headline()
    local phase = phaseOf()
    local hasUpdates = totalOf() > 0 and (phase == "ready" or phase == "running")

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({
                key = "header-check" .. (checking() and "-off" or ""),
                glyph = "refresh",
                variant = "ghost",
                enabled = not checking() and phase ~= "missing",
                tooltip = tr("tip_check"),
                onClick = function()
                    request("check")
                end,
            }),
            ui.button({
                glyph = "close", variant = "ghost", tooltip = tr("tip_close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
        ui.label({ text = text, color = color, maxLines = 2 }),
    }

    for _, node in ipairs(body()) do
        table.insert(children, node)
    end

    local caption = footerCaption()
    if caption ~= nil then
        table.insert(children, ui.separator({}))
        table.insert(children, ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", maxLines = 2 }))
    end

    if phase ~= "missing" then
        table.insert(children, ui.row({ gap = 8, align = "center" }, {
            ui.button({
                key = "check" .. (checking() and "-off" or ""),
                glyph = "refresh", text = tr("action_check"), variant = "ghost", enabled = not checking(), flexGrow = 1,
                onClick = function()
                    request("check")
                end,
            }),
            ui.button({
                key = "dismiss" .. (hasUpdates and "" or "-off"),
                text = tr("action_dismiss"), variant = "ghost", enabled = hasUpdates and snapshot.dismissed ~= true,
                onClick = function()
                    request("dismiss")
                end,
            }),
            ui.button({
                key = "update" .. (hasUpdates and not busy() and "" or "-off"),
                glyph = "download", text = tr("action_update"), variant = "primary", enabled = hasUpdates and not busy(),
                tooltip = tr("tip_update"),
                onClick = function()
                    request("update")
                end,
            }),
        }))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onOpen(_context)
    snapshot = noctalia.state.get(STATE_KEY)
    expanded = {}
    hoverKey = nil
    hoverText = ""
    render()
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    if value.phase == "checking" and (snapshot == nil or snapshot.phase ~= "checking") then
        expanded = {}
        hoverKey = nil
        hoverText = ""
    end
    snapshot = value
    render()
end)
