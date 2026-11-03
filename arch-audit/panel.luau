--!nonstrict
-- Arch Audit panel: the triage view over the service snapshot.
--
-- Read-only by design. The only actions are opening the Arch Security Tracker
-- advisory, copying the system-upgrade command, copying the install command
-- when a dependency is missing, and asking the service for another check.

local audit = require("./lib/audit.luau")

local STATE_KEY = "arch_audit_state"
local REQUEST_KEY = "arch_audit_request"

local FILTERS = { "all", "critical", "high", "medium", "low", "unknown" }

local snapshot = nil
local is_open = false
local filter = "all"
local fix_only = false
local flash = nil
local flash_at = 0

local render

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function request_check()
    local previous = noctalia.state.get(REQUEST_KEY)
    local nonce = ((type(previous) == "table" and tonumber(previous.nonce)) or 0) + 1
    noctalia.state.set(REQUEST_KEY, { nonce = nonce, action = "check" })
end

local function copy_text(text)
    noctalia.copyToClipboard(text, "text/plain")
    flash = tr("toast.copied")
    flash_at = os.time()
    if is_open then
        render()
    end
end

local function open_advisory(item)
    if item.url == nil then
        return
    end
    noctalia.runAsync({ "xdg-open", item.url })
end

local function checked_age()
    if snapshot == nil or snapshot.checkedAtMs == nil then
        return tr("time.never")
    end
    return audit.age_text(snapshot.checkedAtMs, tr, noctalia.trp)
end

local function counts_text(counts)
    local parts = {}
    for _, severity in ipairs(audit.SEVERITIES) do
        local count = tonumber(counts[severity]) or 0
        if count > 0 then
            table.insert(parts, count .. " " .. tr("severity." .. severity):lower())
        end
    end
    return table.concat(parts, " · ")
end

local function subtitle()
    if snapshot == nil then
        return tr("panel.waiting")
    end
    if snapshot.phase == "checking" and (snapshot.total or 0) == 0 then
        return tr("panel.checking")
    end
    if (snapshot.total or 0) > 0 then
        local pkg_count = tonumber(snapshot.packageCount) or 0
        local base = noctalia.trp("panel.advisory_count", snapshot.total)
        if pkg_count > 0 then
            base = base .. " " .. noctalia.trp("panel.affecting_packages", pkg_count)
        end
        return base .. " · " .. counts_text(snapshot.counts or {})
    end
    if snapshot.checkedAtMs ~= nil then
        return tr("panel.clean") .. " · " .. tr("panel.checked", { age = checked_age() })
    end
    return tr("panel.never_checked")
end

local function header_color()
    if snapshot == nil then
        return "on_surface_variant"
    end
    if snapshot.binaryMissing or snapshot.err then
        return "error"
    end
    if snapshot.phase == "checking" then
        return "secondary"
    end
    if (snapshot.total or 0) > 0 then
        return audit.severity_color(snapshot.severity)
    end
    if snapshot.phase == "clean" then
        return "primary"
    end
    return "on_surface_variant"
end

local function header_glyph()
    if snapshot == nil then
        return "shield"
    end
    if snapshot.binaryMissing or snapshot.err then
        return "shield-x"
    end
    if snapshot.phase == "clean" then
        return "shield-check"
    end
    return "shield-exclamation"
end

local function status_label(status)
    local key = tostring(status or ""):lower():gsub("%s+", "_")
    local translation_key = "status." .. key
    local text = tr(translation_key)
    if text == translation_key then
        return tostring(status or "")
    end
    return text
end

local function installed_text(item)
    local parts = {}
    for _, entry in ipairs(item.installed or {}) do
        if entry.version ~= nil then
            table.insert(parts, entry.name .. " " .. entry.version)
        else
            table.insert(parts, entry.name)
        end
    end
    if #parts == 0 then
        for _, name in ipairs(item.packages or {}) do
            table.insert(parts, name)
        end
    end
    return table.concat(parts, ", ")
end

local function cve_text(item)
    if #item.issues == 0 then
        return tr("row.no_cves")
    end
    local shown = {}
    for index = 1, math.min(#item.issues, 4) do
        shown[index] = item.issues[index]
    end
    local text = table.concat(shown, ", ")
    if #item.issues > #shown then
        text = text .. " +" .. (#item.issues - #shown)
    end
    return text
end

local function filter_options()
    local options = {}
    for _, key in ipairs(FILTERS) do
        local count
        if key == "all" then
            count = snapshot ~= nil and (snapshot.total or 0) or 0
        else
            count = snapshot ~= nil and (snapshot.counts[key] or 0) or 0
        end
        local label = key == "all" and tr("severity.all") or tr("severity." .. key)
        table.insert(options, label .. " (" .. count .. ")")
    end
    return options
end

local function filter_index()
    for index, key in ipairs(FILTERS) do
        if key == filter then
            return index - 1
        end
    end
    return 0
end

local function advisory_card(item)
    local fixed = item.fixed
    local actions = {
        ui.label({ text = item.id, fontSize = 10, color = "on_surface_variant" }),
        ui.spacer({ flexGrow = 1 }),
    }
    if item.url ~= nil then
        table.insert(actions, ui.button({
            text = tr("row.open"),
            glyph = "external-link",
            controlSize = "sm",
            variant = "ghost",
            onClick = function()
                open_advisory(item)
            end,
        }))
    end
    -- The correct action is always the same for every row: a full system
    -- upgrade. Keeping the button even without a fixed version avoids implying
    -- that the safe action depends on the tracker's release state.
    table.insert(actions, ui.button({
        text = tr("row.copy_upgrade"),
        glyph = "copy",
        controlSize = "sm",
        variant = "ghost",
        tooltip = tr("row.copy_upgrade_tip"),
        onClick = function()
            copy_text(audit.upgrade_command())
        end,
    }))

    return ui.column({
        key = "advisory-" .. item.id,
        gap = 6,
        paddingH = 12,
        paddingV = 10,
        fill = "surface_container/0.35",
        border = "outline_variant/0.4",
        borderWidth = 1,
        radius = 8,
    }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.box({
                width = 8,
                height = 8,
                radius = 4,
                fill = audit.severity_color(item.severity),
            }),
            ui.label({
                text = installed_text(item),
                fontWeight = "bold",
                color = "on_surface",
                flexGrow = 1,
                maxLines = 1,
            }),
            ui.label({
                text = tr("severity." .. item.severity),
                fontSize = 10,
                fontWeight = "bold",
                color = audit.severity_color(item.severity),
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = status_label(item.status),
                fontSize = 11,
                color = "on_surface_variant",
            }),
            ui.label({ text = "·", fontSize = 11, color = "on_surface_variant" }),
            ui.label({
                text = item.type,
                fontSize = 11,
                color = "on_surface_variant",
                flexGrow = 1,
                maxLines = 1,
            }),
        }),
        ui.label({
            text = fixed ~= nil and tr("row.fixed", { version = fixed }) or tr("row.no_fix"),
            fontSize = 11,
            fontWeight = fixed ~= nil and "bold" or nil,
            color = fixed ~= nil and "primary" or "tertiary",
        }),
        ui.label({
            text = tr("row.cves") .. ": " .. cve_text(item),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 2,
        }),
        ui.row({ gap = 8, align = "center" }, actions),
    })
end

local function empty_state(glyph, color, title, body, action_label, action)
    local children = {
        ui.glyph({ name = glyph, size = 34, color = color }),
        ui.label({
            text = title,
            fontSize = 15,
            fontWeight = "bold",
            color = "on_surface",
            textAlign = "center",
        }),
        ui.label({
            text = body,
            fontSize = 12,
            color = "on_surface_variant",
            textAlign = "center",
            maxLines = 4,
        }),
    }
    if action_label ~= nil then
        table.insert(children, ui.button({
            text = action_label,
            variant = "primary",
            onClick = action,
        }))
    end
    return ui.column({
        flexGrow = 1,
        align = "center",
        justify = "center",
        gap = 10,
        padding = 20,
    }, children)
end

local function banner()
    if snapshot == nil then
        return nil
    end

    if snapshot.binaryMissing then
        return ui.row({
            key = "banner-missing",
            gap = 10,
            align = "center",
            paddingH = 10,
            paddingV = 8,
            fill = "error/0.12",
            radius = 8,
        }, {
            ui.glyph({ name = "alert-triangle", size = 18, color = "error" }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = tr("missing.title"), fontWeight = "bold", color = "error" }),
                ui.label({
                    text = tr("missing.short"),
                    fontSize = 11,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }),
            ui.button({
                text = tr("missing.action"),
                controlSize = "sm",
                variant = "outline",
                onClick = function()
                    copy_text("sudo pacman -S arch-audit")
                end,
            }),
        })
    end

    if snapshot.err ~= nil and snapshot.phase ~= "checking" then
        return ui.row({
            key = "banner-error",
            gap = 10,
            align = "center",
            paddingH = 10,
            paddingV = 8,
            fill = "tertiary/0.12",
            radius = 8,
        }, {
            ui.glyph({ name = "alert-triangle", size = 18, color = "tertiary" }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({ text = tr("error.banner"), fontWeight = "bold", color = "tertiary" }),
                ui.label({
                    text = tostring(snapshot.err),
                    fontSize = 11,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }),
            ui.button({
                text = tr("error.action"),
                controlSize = "sm",
                variant = "outline",
                onClick = function()
                    request_check()
                end,
            }),
        })
    end

    return nil
end

local function footer()
    local children = {
        ui.label({
            text = tr("panel.checked", { age = checked_age() }),
            fontSize = 11,
            color = "on_surface_variant",
            flexGrow = 1,
        }),
    }
    if snapshot ~= nil and (tonumber(snapshot.ignoredCount) or 0) > 0 then
        table.insert(children, ui.label({
            text = noctalia.trp("panel.ignored", snapshot.ignoredCount),
            fontSize = 11,
            color = "on_surface_variant",
        }))
    end
    if flash ~= nil then
        table.insert(children, ui.label({ text = flash, fontSize = 11, color = "primary" }))
    end
    return ui.row({ gap = 8, align = "center" }, children)
end

render = function()
    if not is_open then
        return
    end

    local checking = snapshot ~= nil and snapshot.phase == "checking"
    local parts = {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = header_glyph(), size = 24, color = header_color() }),
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({
                    text = tr("panel.title"),
                    fontSize = 16,
                    fontWeight = "bold",
                    color = "on_surface",
                }),
                ui.label({
                    text = subtitle(),
                    fontSize = 11,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }),
            ui.button({
                glyph = "refresh",
                variant = "ghost",
                tooltip = tr("panel.recheck"),
                enabled = not checking,
                onClick = function()
                    request_check()
                end,
            }),
            ui.button({
                glyph = "settings",
                variant = "ghost",
                tooltip = tr("panel.settings"),
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                glyph = "close",
                variant = "ghost",
                tooltip = tr("panel.close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
    }

    local banner_node = banner()
    if banner_node ~= nil then
        table.insert(parts, banner_node)
    end

    local total = snapshot ~= nil and (snapshot.total or 0) or 0
    if snapshot == nil then
        table.insert(parts, empty_state(
            "shield",
            "secondary",
            tr("waiting.title"),
            tr("waiting.body")
        ))
    elseif checking and total == 0 then
        table.insert(parts, empty_state(
            "shield",
            "secondary",
            tr("panel.checking"),
            tr("panel.checking_body")
        ))
    elseif total == 0 and snapshot.binaryMissing then
        table.insert(parts, empty_state(
            "shield-x",
            "error",
            tr("missing.title"),
            tr("missing.body"),
            tr("missing.action"),
            function()
                copy_text("sudo pacman -S arch-audit")
            end
        ))
    elseif total == 0 and snapshot.err ~= nil then
        table.insert(parts, empty_state(
            "alert-triangle",
            "error",
            tr("error.title"),
            tostring(snapshot.err),
            tr("error.action"),
            function()
                request_check()
            end
        ))
    elseif total == 0 and snapshot.phase == "clean" then
        table.insert(parts, empty_state(
            "shield-check",
            "primary",
            tr("empty.title"),
            tr("empty.body")
        ))
    elseif total == 0 then
        table.insert(parts, empty_state(
            "shield",
            "secondary",
            tr("idle.title"),
            tr("idle.body"),
            tr("panel.recheck"),
            function()
                request_check()
            end
        ))
    else
        table.insert(parts, ui.row({ gap = 8, align = "center" }, {
            ui.select({
                key = "severity-filter",
                options = filter_options(),
                selectedIndex = filter_index(),
                flexGrow = 1,
                onChange = function(value)
                    local index = (tonumber(value) or 0) + 1
                    filter = FILTERS[index] or "all"
                    render()
                end,
            }),
            ui.button({
                key = "fix-only",
                text = tr("panel.fix_only"),
                glyph = "download",
                controlSize = "sm",
                selected = fix_only,
                variant = fix_only and "primary" or "default",
                tooltip = tr("panel.fix_only_tip"),
                onClick = function()
                    fix_only = not fix_only
                    render()
                end,
            }),
        }))

        local filtered = audit.filter(snapshot.items or {}, filter, fix_only)
        if #filtered == 0 then
            table.insert(parts, ui.column({
                flexGrow = 1,
                align = "center",
                justify = "center",
            }, {
                ui.label({
                    text = tr("panel.filter_empty"),
                    color = "on_surface_variant",
                    textAlign = "center",
                }),
            }))
        else
            local cards = {}
            for _, item in ipairs(filtered) do
                table.insert(cards, advisory_card(item))
            end
            table.insert(parts, ui.scroll({ flexGrow = 1, gap = 8 }, cards))
        end
    end

    table.insert(parts, ui.separator({}))
    table.insert(parts, footer())

    panel.render(ui.column({
        flexGrow = 1,
        gap = 10,
        padding = 14,
        align = "stretch",
    }, parts))
end

function onOpen()
    is_open = true
    snapshot = noctalia.state.get(STATE_KEY) or snapshot
    panel.setWantsSecondTicks(true)
    render()
end

function onClose()
    is_open = false
end

function update()
    if flash ~= nil and os.time() - flash_at >= 2 then
        flash = nil
        if is_open then
            render()
        end
    end
end

function onIpc(event)
    if event == "check" or event == "refresh" then
        request_check()
    end
end

noctalia.state.watch(STATE_KEY, function(value)
    if type(value) ~= "table" then
        return
    end
    snapshot = value
    if is_open then
        render()
    end
end)

snapshot = noctalia.state.get(STATE_KEY)
