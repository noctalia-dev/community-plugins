--!nonstrict
-- topgrade-wrapper — update panel. A pure renderer over the shared state: the
-- engine (service.luau) publishes "topgrade_state" and performs the
-- "topgrade_request" actions this panel emits, so closing the panel never
-- interrupts a check or a run in progress.
--
-- The flow is deliberately two-step. "Check Updates" only queries, and its
-- result is a per-manager breakdown plus, when something could not be counted,
-- the names of the steps it left out. Only then do "Update" (open a terminal
-- and run topgrade) and "Dismiss" (keep the numbers, quiet the bar) light up.

local STATE_KEY = "topgrade_state"
local REQUEST_KEY = "topgrade_request"

local snapshot = nil
local expanded = {} -- manager key -> the package list is open
local hoverKey = nil -- package row currently under the pointer
local hoverText = "" -- what the detail line shows
local listOpen = false -- at least one manager is expanded this render

local render

local function tr(key, args)
    return noctalia.tr(key, args)
end

-- The nonce is monotonic across writers (the panel and every widget instance):
-- each seeds from the last request already in the shared state.
local function request(action)
    local prev = noctalia.state.get(REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, action = action })
end

local function versionsShown()
    return noctalia.getConfig("show_versions") ~= false
end

-- The full text for the detail line: everything the row may have had to elide.
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

-- Version pair width. Arch git-snapshot versions run past 25 characters, so the
-- pair is capped and elided here and the hover line below the list carries the
-- full text: no plugin UI primitive can put a tooltip on a plain row.
local VERSION_WIDTH = 82

-- A single package inside an expanded manager: name, then — unless the versions
-- are switched off — `installed → available` with the incoming version in the
-- accent colour so the eye lands on what changes.
--
-- The hover callback is a closure over this row's own package, which is why it
-- needs no lookup table and no key argument: it already holds the text it will
-- show. It fills the detail line below the list, the only place a long version
-- pair fits unelided (a tooltip is not an option — the UI offers that on
-- ui.button alone), and every row feeds it whether or not it shows the pair.
local function packageRow(managerKey, index, item)
    local key = "pkg-" .. managerKey .. "-" .. index
    local children = {
        ui.label({ text = item.name, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 1 }),
    }
    -- Versions off narrows the row to the name, but the hover line below the list
    -- keeps working exactly as it does with them on: the setting is about how
    -- much every row carries at rest, not about giving up the detail.
    local from = item.from ~= nil and item.from or ""
    local to = item.to ~= nil and item.to or ""
    if versionsShown() and to ~= "" then
        if from ~= "" then
            table.insert(children, ui.label({
                text = from,
                fontSize = 11,
                color = "on_surface_variant",
                maxWidth = VERSION_WIDTH,
                maxLines = 1,
            }))
        end
        table.insert(children, ui.label({ text = "→", fontSize = 11, color = "on_surface_variant" }))
        table.insert(children, ui.label({
            text = to,
            fontSize = 11,
            color = "primary",
            fontWeight = "semibold",
            maxWidth = VERSION_WIDTH,
            maxLines = 1,
        }))
    end
    -- Only the leave of the row that is still the hovered one clears the line, so
    -- an enter that beats its predecessor's leave is not undone by it.
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

-- One row per manager that answered, biggest first so the row that matters is
-- at the top. Managers that answered zero are kept out of the list and summed
-- up in the footer caption instead.
--
-- A row with names behind it is a click target that expands into them. The
-- expanded set is panel-local on purpose: which rows you opened is a property of
-- looking at the list, not of the check, so it is neither published nor kept
-- across a re-check.
local function countRows()
    local rows = {}
    if snapshot == nil or type(snapshot.counts) ~= "table" then
        return rows
    end
    local pending = {}
    for _, entry in ipairs(snapshot.counts) do
        if (tonumber(entry.n) or 0) > 0 then
            table.insert(pending, entry)
        end
    end
    table.sort(pending, function(a, b)
        if a.n == b.n then
            return tostring(a.key) < tostring(b.key)
        end
        return a.n > b.n
    end)

    for _, entry in ipairs(pending) do
        local names = type(entry.items) == "table" and entry.items or {}
        local open = expanded[entry.key] == true and #names > 0
        listOpen = listOpen or open
        local header = { gap = 8, align = "center", key = "count-" .. entry.key .. (open and "-open" or "") }
        if #names > 0 then
            local managerKey = entry.key
            header.onClick = function()
                expanded[managerKey] = not expanded[managerKey]
                -- Folding removes the rows the detail line was describing.
                hoverKey = nil
                hoverText = ""
                render()
            end
        end
        table.insert(rows, ui.row(header, {
            ui.glyph({
                name = #names == 0 and "point" or (open and "chevron-down" or "chevron-right"),
                size = 12,
                color = "on_surface_variant",
            }),
            ui.label({ text = tr("count." .. entry.key), color = "on_surface", flexGrow = 1 }),
            ui.label({ text = tostring(entry.n), color = "primary", fontWeight = "bold" }),
        }))

        if open then
            for index, item in ipairs(names) do
                table.insert(rows, packageRow(entry.key, index, item))
            end
            -- The engine caps the stored list; say so rather than let the rows
            -- silently disagree with the count beside the manager.
            if entry.n > #names then
                table.insert(rows, ui.row({ key = "more-" .. entry.key, paddingH = 18 }, {
                    ui.label({
                        text = tr("more_packages", { count = entry.n - #names }),
                        fontSize = 11,
                        color = "on_surface_variant",
                    }),
                }))
            end
        end
    end
    return rows
end

-- Managers that answered "0" — worth showing, because "checked and up to date"
-- and "never checked" must not look the same.
local function cleanNames()
    local names = {}
    if snapshot == nil or type(snapshot.counts) ~= "table" then
        return names
    end
    for _, entry in ipairs(snapshot.counts) do
        if (tonumber(entry.n) or 0) == 0 then
            table.insert(names, tr("count." .. entry.key))
        end
    end
    return names
end

local function body()
    local phase = phaseOf()
    local children = {}

    if phase == "checking" then
        table.insert(children, ui.progress({ key = "check-progress", progress = tonumber(snapshot.progress) or 0 }))
    end

    local rows = countRows()
    if #rows > 0 then
        table.insert(children, ui.scroll({ key = "counts", flexGrow = 1, gap = 6 }, rows))
    else
        table.insert(children, ui.spacer({ key = "filler", flexGrow = 1 }))
    end

    -- The detail line is rendered for as long as any list is open, hovered or
    -- not: a line that appeared on hover would resize the list under the pointer
    -- and flicker the row straight back out from under it.
    if listOpen then
        table.insert(children, ui.label({
            key = "hover-detail",
            text = hoverText ~= "" and hoverText or tr("hover_hint"),
            fontSize = 11,
            color = hoverText ~= "" and "on_surface" or "on_surface_variant",
            maxLines = 1,
        }))
    end

    -- Everything topgrade would run but nothing could count: listed by step
    -- name, never folded into the total.
    if snapshot ~= nil and type(snapshot.uncounted) == "table" and #snapshot.uncounted > 0 then
        table.insert(children, ui.label({
            text = tr("uncounted", { steps = table.concat(snapshot.uncounted, ", ") }),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 3,
        }))
    end

    local clean = cleanNames()
    if #clean > 0 then
        table.insert(children, ui.label({
            text = tr("up_to_date", { steps = table.concat(clean, ", ") }),
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 2,
        }))
    end

    return children
end

-- Shortens $HOME to ~ for display. The prefix is pattern-escaped: a home
-- directory holding a dash or a dot would otherwise be read as a pattern.
local function tildify(path)
    local home = noctalia.getenv("HOME")
    if home == nil or home == "" then
        return path
    end
    local escaped = home:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    return (path:gsub("^" .. escaped, "~"))
end

-- Config file and exclusion count: the two things that decide what the number
-- above actually covers.
local function configCaption()
    if snapshot == nil then
        return nil
    end
    local parts = {}
    local path = snapshot.configPath
    if path ~= nil and path ~= "" then
        table.insert(parts, tr("caption_config", { path = tildify(path) }))
    else
        table.insert(parts, tr("caption_config_default"))
    end
    local excluded = tonumber(snapshot.excluded) or 0
    if excluded > 0 then
        table.insert(parts, noctalia.trp("caption_excluded", excluded, {}))
    end
    if snapshot.checkedAt ~= nil and snapshot.checkedAt ~= "" then
        table.insert(parts, tr("caption_checked", { time = snapshot.checkedAt }))
    end
    return table.concat(parts, "  ·  ")
end

render = function()
    -- Recomputed from the tree that is about to be produced.
    listOpen = false

    local text, color = headline()
    local phase = phaseOf()
    local hasUpdates = totalOf() > 0 and (phase == "ready" or phase == "running")

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.button({
                key = "header-check" .. (busy() and "-off" or ""),
                glyph = "refresh",
                variant = "ghost",
                enabled = not busy() and phase ~= "missing",
                tooltip = tr("tip_check"),
                onClick = function()
                    request("check")
                end,
            }),
            ui.button({
                glyph = "close",
                variant = "ghost",
                tooltip = tr("tip_close"),
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

    local caption = configCaption()
    if caption ~= nil then
        table.insert(children, ui.separator({}))
        table.insert(children, ui.label({ text = caption, fontSize = 11, color = "on_surface_variant", maxLines = 3 }))
    end

    if phase ~= "missing" then
        table.insert(children, ui.row({ gap = 8, align = "center" }, {
            ui.button({
                key = "check" .. (busy() and "-off" or ""),
                glyph = "refresh",
                text = tr("action_check"),
                variant = "ghost",
                enabled = not busy(),
                flexGrow = 1,
                onClick = function()
                    request("check")
                end,
            }),
            ui.button({
                key = "dismiss" .. (hasUpdates and "" or "-off"),
                text = tr("action_dismiss"),
                variant = "ghost",
                enabled = hasUpdates and snapshot.dismissed ~= true,
                onClick = function()
                    request("dismiss")
                end,
            }),
            ui.button({
                key = "update" .. (hasUpdates and not busy() and "" or "-off"),
                glyph = "download",
                text = tr("action_update"),
                variant = "primary",
                enabled = hasUpdates and not busy(),
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
    -- A new check invalidates the rows the old one produced, so start it folded.
    if value.phase == "checking" and (snapshot == nil or snapshot.phase ~= "checking") then
        expanded = {}
        hoverKey = nil
        hoverText = ""
    end
    snapshot = value
    render()
end)
