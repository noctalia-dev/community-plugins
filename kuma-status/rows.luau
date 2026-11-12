--!nonstrict
-- kuma-status — UI builders for the panel: a monitor row (40-cell heartbeat bar,
-- mute button, optional certificate line) and a collapsible group header. The name is a ghost
-- button because only a button has onRightClick. "row-<id>" carries the URL tooltip.

local R = {}

R.CELLS = 40
R.COLORS = { [0] = "#e06c75", [1] = "#98c379", [2] = "#e5c07b", [3] = "#61afef" }
R.EMPTY = "#4b5263"
-- Panel width minus padding, scrollbar, dot, ping, bar and gaps (see plugin.toml).
local NAME_W = 256

-- Always CELLS boxes, oldest left; missing history is padded with neutral cells.
function R.beatBar(beats, key)
    local n = #beats
    local first = math.max(1, n - R.CELLS + 1)
    local used = n - first + 1
    local cells = {}
    for _ = 1, R.CELLS - used do
        cells[#cells + 1] = ui.box({ width = 4, height = 14, radius = 1, fill = R.EMPTY, opacity = 0.5 })
    end
    local up = 0
    for i = first, n do
        if beats[i] == 1 then up += 1 end
        cells[#cells + 1] = ui.box({ width = 4, height = 14, radius = 1, fill = R.COLORS[beats[i]] or R.EMPTY })
    end
    local tip = nil
    if used > 0 then tip = noctalia.tr("panel.tip_bar", { up = up, total = used }) end
    return ui.row({ key = key, gap = 1, tooltip = tip }, cells)
end

local function pingText(row)
    if row.paused or row.noPing then return "" end
    if row.ping == nil then return "—" end
    return string.format("%d ms", math.floor(row.ping + 0.5))
end

-- Certificate level to color; expired is red.
function R.levelColor(level)
    if level == "green" then return R.COLORS[1] end
    if level == "yellow" then return R.COLORS[2] end
    return R.COLORS[0]
end

local function certLine(row)
    local days = math.floor(row.certDays)
    local color = R.levelColor(row.certLevel)
    local text = days < 0 and noctalia.tr("panel.cert_expired") or noctalia.tr("panel.cert_days", { days = days })
    return ui.row({ key = "cert-" .. row.id, gap = 4, align = "center" }, {
        ui.box({ width = 18 }),
        ui.glyph({ key = "cert-glyph-" .. row.id, name = "certificate", size = 12, color = color }),
        ui.label({ key = "cert-text-" .. row.id, text = text, fontSize = 11, color = "on_surface_variant" }),
    })
end

-- onOpen(id): left click on the name. onMenu(row): right click, nil to disable.
-- compact: no certificate line and no padding.
function R.monitorRow(row, onOpen, onMenu, onMute, compact)
    local id = row.id
    local main = ui.row({ gap = 8, align = "center", paddingV = compact and 0 or 2 }, {
        ui.box({ key = "dot-" .. id, width = 10, height = 10, radius = 5, fill = (row.paused or row.muted) and R.EMPTY or (R.COLORS[row.status] or R.EMPTY) }),
        ui.button({
            key = "name-" .. id, text = row.name, variant = "ghost", contentAlign = "start", width = NAME_W,
            onClick = function() onOpen(id) end,
            onRightClick = onMenu and function() onMenu(row) end or nil,
        }),
        ui.column({ width = 64, align = "end" }, { ui.label({ key = "ping-" .. id, text = pingText(row), color = "on_surface_variant" }) }),
        R.beatBar(row.beats, "bar-" .. id),
        onMute and ui.button({
            key = "mute-" .. id, glyph = row.muted and "eye-off" or "eye", variant = "ghost",
            tooltip = noctalia.tr(row.muted and "panel.tip_unmute" or "panel.tip_mute"), onClick = function() onMute(id) end,
        }) or ui.box({ width = 0 }),
    })
    local children = { main }
    if row.certDays ~= nil and not row.paused and not compact then children[2] = certLine(row) end
    return ui.column({ key = "row-" .. id, gap = 0, opacity = (row.paused or row.muted) and 0.55 or 1, tooltip = row.url }, children)
end

function R.groupKey(group)
    return group.name ~= "" and group.name or "_none"
end

function R.groupHeader(group, collapsed, onToggle)
    local key = R.groupKey(group)
    local label = group.name ~= "" and group.name or noctalia.tr("panel.group_none")
    local uptime = group.uptime1d and string.format("%.1f%%", group.uptime1d * 100) or ""
    local children = {
        ui.label({ text = collapsed and "▶" or "▼", width = 14 }),
        ui.label({ text = label, flexGrow = 1, maxLines = 1, fontWeight = "semibold" }),
    }
    if (group.down or 0) > 0 then
        children[3] = ui.glyph({ key = "gh-alert-" .. key, name = "alert-triangle", size = 14, color = R.COLORS[0] })
    end
    children[#children + 1] = ui.label({ text = group.up .. "/" .. group.total, color = "on_surface_variant" })
    children[#children + 1] = ui.label({ text = uptime, width = 56, textAlign = "end", color = "on_surface_variant" })
    return ui.row({ key = "gh-" .. key, gap = 8, align = "center", paddingV = 4, fill = "surface_container", radius = 6, paddingH = 8, onClick = function() onToggle(key) end }, children)
end

return R
