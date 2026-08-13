--!nonstrict
-- arch-updater update panel. Pure renderer over the shared state: the engine
-- (service.luau) publishes "arch_state" and performs the "arch_request"
-- actions this panel emits, so closing the panel never interrupts a check or
-- a run in progress.
--
-- "Check Updates" only queries pacman, the AUR helper and (optionally)
-- Flatpak. Only then do "Update" (open a terminal and run the upgrade) and
-- "Dismiss" (clear the pending list and close the panel) light up.

local STATE_KEY = "arch_state"
local REQUEST_KEY = "arch_request"

local snapshot = nil
local expanded = {} -- source key -> the package list is open
local hoverKey = nil -- package row currently under the pointer
local hoverText = "" -- what the detail line shows
local activityHoverIndex = nil -- activity graph point currently under the pointer
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

local SOURCE_GLYPHS = { pacman = "package", aur = "cloud", flatpak = "app-window" }

local function sourceGlyph(key)
    return SOURCE_GLYPHS[key] or "package"
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
        glyph = "copy", variant = "ghost", controlSize = "sm", width = 22, height = 22, glyphSize = 12,
        tooltip = tr("tip_copy"),
        onClick = function()
            noctalia.copyToClipboard(detailFor(item), "text/plain")
        end,
    }))
    table.insert(children, ui.button({
        glyph = "external-link", variant = "ghost", controlSize = "sm", width = 22, height = 22, glyphSize = 12,
        tooltip = tr("tip_open_page"),
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
            ui.glyph({ name = sourceGlyph(source.key), size = 13, color = "on_surface_variant" }),
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

-- Normalizes the pending-count history to 0..1 for ui.graph, relative to the
-- min/max in the window (not a fixed scale, since pending counts vary wildly
-- between systems). A flat window (min == max, e.g. every check so far found
-- the same count) centers the line at 0.5 instead of pinning it to the top
-- edge, where it would be indistinguishable from the box border.
local function activityValues(history)
    local minN, maxN = tonumber(history[1].n) or 0, tonumber(history[1].n) or 0
    for _, entry in ipairs(history) do
        local n = tonumber(entry.n) or 0
        if n < minN then
            minN = n
        end
        if n > maxN then
            maxN = n
        end
    end
    local range = maxN - minN
    local values = {}
    for _, entry in ipairs(history) do
        local n = tonumber(entry.n) or 0
        table.insert(values, range > 0 and (n - minN) / range or 0.5)
    end
    return values
end

local ACTIVITY_GRAPH_SUBDIVISIONS = 8

local function upsampleLinear(values, subdivisions)
    if #values < 2 or subdivisions <= 1 then
        return values
    end
    local out = {}
    for i = 1, #values - 1 do
        local a, b = values[i], values[i + 1]
        for s = 0, subdivisions - 1 do
            table.insert(out, a + (b - a) * (s / subdivisions))
        end
    end
    table.insert(out, values[#values])
    return out
end

local function padGraphLookbehind(values)
    if #values == 0 then
        return values
    end
    local out = { values[1], values[1] }
    for _, v in ipairs(values) do
        table.insert(out, v)
    end
    return out
end

-- "2 hours ago", "3 days ago", etc. nil for entries migrated from the old
-- history format, which never recorded a timestamp.
local function relativeTime(at)
    local t = tonumber(at)
    if t == nil then
        return nil
    end
    local diff = os.time() - t
    if diff < 60 then
        return tr("activity.just_now")
    elseif diff < 3600 then
        local m = math.floor(diff / 60)
        return noctalia.trp("activity.minutes_ago", m, { count = m })
    elseif diff < 86400 then
        local h = math.floor(diff / 3600)
        return noctalia.trp("activity.hours_ago", h, { count = h })
    else
        local d = math.floor(diff / 86400)
        return noctalia.trp("activity.days_ago", d, { count = d })
    end
end

-- "Updated · 2 hours ago" for the check that verified an update run, else
-- "3 pending updates · 2 hours ago". Shared by the hover tooltip and the
-- top-right caption so both describe a point the same way.
local function describeEntry(entry)
    local n = tonumber(entry.n) or 0
    local text = entry.afterUpdate == true and tr("activity.updated")
        or noctalia.trp("activity.pending_at", n, { count = n })
    local when = relativeTime(entry.at)
    if when ~= nil then
        text = text .. " · " .. when
    end
    return text
end

-- ui.graph takes no pointer props of its own (only row/column/box/image/button
-- do), so per-point hover is a row of hit targets placed right under the
-- line. Each is a ghost button so it can carry a native tooltip at the
-- pointer, not just a box for the hit test. It cannot highlight the point on
-- the line itself, only drive the tooltip and the caption above it.
--
-- Real points sit at (k-1)/(#history-1) of the width (see
-- padGraphLookbehind), i.e. #history-1 equal gaps, not #history equal slots
-- - so this builds one equal-width segment per gap rather than per entry,
-- ending each segment exactly on the point at its right edge. That leaves
-- entry 1 (at the left edge, with no gap before it) without its own hover
-- zone, but keeps every other spike landing right at the end of its segment
-- instead of drifting toward the start of an oversized one.
local function activityHoverRow(history)
    local segments = {}
    for i = 2, #history do
        segments[i - 1] = ui.button({
            key = "activity-hit-" .. i,
            variant = "ghost",
            flexGrow = 1,
            height = 12,
            tooltip = describeEntry(history[i]),
            onHover = function(state)
                if state == "true" then
                    activityHoverIndex = i
                elseif activityHoverIndex == i then
                    activityHoverIndex = nil
                else
                    return
                end
                render()
            end,
        })
    end
    return ui.row({ key = "activity-hits", gap = 1 }, segments)
end

-- A small trend graph of pending-update counts across recent checks, plus
-- when the last update ran (or, while hovering a point, that point's own
-- description). Off entirely when show_activity_graph is off, and hidden
-- until there is enough history to draw a line.
local function activitySection()
    if snapshot == nil or noctalia.getConfig("show_activity_graph") ~= true then
        return nil
    end
    local history = type(snapshot.history) == "table" and snapshot.history or {}
    if #history < 2 then
        return nil
    end

    local hoveredEntry = activityHoverIndex ~= nil and history[activityHoverIndex] or nil
    local caption
    if hoveredEntry ~= nil then
        caption = describeEntry(hoveredEntry)
    else
        local lastUpdateAt = tonumber(snapshot.lastUpdateAt)
        if lastUpdateAt == nil then
            caption = tr("activity.never_updated")
        else
            local days = math.floor((os.time() - lastUpdateAt) / 86400)
            caption = days <= 0 and tr("activity.updated_today")
                or noctalia.trp("activity.updated_days_ago", days, { count = days })
        end
    end

    return ui.column({ key = "activity", gap = 4 }, {
        ui.row({ justify = "space_between", align = "center" }, {
            ui.label({ text = tr("activity.title"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
            ui.label({ text = caption, fontSize = 10, color = "on_surface_variant" }),
        }),
        ui.graph({
            values = padGraphLookbehind(upsampleLinear(activityValues(history), ACTIVITY_GRAPH_SUBDIVISIONS)),
            color = "primary",
            fillOpacity = 0.15,
            lineWidth = 2,
            height = 36,
        }),
        activityHoverRow(history),
    })
end

local function body()
    local children = {}

    local rows = sourceRows()
    if #rows > 0 then
        table.insert(children, ui.scroll({ key = "sources", flexGrow = 1, gap = 3 }, rows))
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

    local activity = activitySection()
    if activity ~= nil then
        table.insert(children, activity)
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
                text = tr("action_dismiss"), variant = "ghost", enabled = hasUpdates,
                onClick = function()
                    request("dismiss")
                    panel.close()
                end,
            }),
            ui.button({
                key = "update" .. (hasUpdates and not busy() and "" or "-off"),
                glyph = "download", text = tr("action_update"), variant = "primary", enabled = hasUpdates and not busy(),
                tooltip = tr("tip_update"),
                onClick = function()
                    request("update")
                    panel.close()
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
    activityHoverIndex = nil
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
        activityHoverIndex = nil
    end
    snapshot = value
    render()
end)
