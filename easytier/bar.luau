--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- bar.luau —— EasyTier mesh status on the bar
--
-- Shows the peer count by default ("not running" when core is down), switchable to the node
-- count, direct ratio, best latency, cumulative traffic or this host's virtual IP; colors by level:
--   normal → theme primary    elevated (latency/loss/relay present) → tertiary    offline or critical → error
--
-- Interaction (rebindable via component gestures in settings):
--   Left click: open the detail panel ([widget.actions] default in plugin.toml)
--   Right click: refetch immediately
--
-- Data comes from easytier-cli subprocess calls (see lib/easytier.luau), read-only,
-- never persisted, no resident process.
-- ══════════════════════════════════════════════════════════════════════════

local e = require("./lib/easytier.luau")

-- Latest snapshot and derived metrics; nil means no data yet
local snap = nil
local derived = nil
local inflight = false
local lastFetchAt = 0
local lastLevel = nil

-- ── Settings ───────────────────────────────────────────────────────────────

local function settings()
    return {
        display = e.text("display", "status"),
        glyph = e.text("glyph", "network"),
        showGlyph = e.flag("show_glyph", true),
        glyphColor = e.text("glyph_color", "level"),
        hideWhenStopped = e.flag("hide_when_stopped", false),
    }
end

local function glyphRole(cfg, level)
    local w = settings()
    if w.glyphColor == "level" then
        return e.roleOf(level)
    end
    if w.glyphColor == "theme" then
        return "on_surface"
    end
    return w.glyphColor
end

-- ── Text ───────────────────────────────────────────────────────────────────

local function barText(w, snap_, d, info)
    if snap_ == nil or snap_.node == nil then
        return e.tr("bar_off", "offline")
    end
    if w.display == "peers" then
        return tostring(d.total)
    end
    if w.display == "direct" then
        return string.format("%d/%d", d.direct, d.total)
    end
    if w.display == "latency" then
        return e.ms(d.best)
    end
    if w.display == "traffic" then
        return string.format("↓%s ↑%s", e.bytes(d.rx), e.bytes(d.tx))
    end
    if w.display == "ip" then
        return (info and info.ip) or "--"
    end
    -- status: show how many nodes are visible, only takes text space when offline
    return tostring(d.total)
end

local function buildTooltip(cfg, w, snap_, level)
    local rows = {}
    local info = e.nodeInfo(snap_)

    table.insert(rows, { key = e.tr("tt_status", "Status"), value = e.statusText(cfg, snap_) })

    if snap_ ~= nil and snap_.node == nil then
        table.insert(rows, { key = e.tr("tt_portal", "RPC portal"), value = cfg.portal ~= "" and cfg.portal or "127.0.0.1:15888" })
        table.insert(rows, { key = e.tr("tt_hint_key", "Hint"), value = e.tr("tt_hint_off", "Check that easytier-core is running; left click opens the panel") })
        return rows
    end

    local d = derived or e.derive(snap_, cfg)

    if info ~= nil then
        local where = info.hostname
        if info.ip ~= nil then
            where = string.format("%s · %s", info.hostname, info.ip)
        end
        table.insert(rows, { key = e.tr("tt_network", "Network"), value = (info.network ~= nil) and string.format("%s · %s", info.network, where) or where })
        if info.publicIp ~= nil then
            table.insert(rows, { key = e.tr("tt_public_ip", "Public address"), value = info.publicIp })
        end
        if info.nat ~= nil then
            table.insert(rows, { key = e.tr("tt_nat", "NAT type"), value = info.nat })
        end
    end

    table.insert(rows, {
        key = e.tr("tt_peers", "Peers"),
        value = string.format(e.tr("tt_peers_value", "%d (direct %d · relay %d)"), d.total, d.direct, d.relay),
    })

    if (d.servers or 0) > 0 then
        table.insert(rows, {
            key = e.tr("tt_servers", "Servers"),
            value = e.serversText(d),
        })
    end

    if d.counted > 0 then
        table.insert(rows, {
            key = e.tr("tt_latency", "Latency"),
            value = string.format(
                e.tr("tt_latency_value", "best %s · avg %s · worst %s"),
                e.ms(d.best),
                e.ms(d.avg),
                e.ms(d.worst)
            ),
        })
    end

    if d.lossy > 0 then
        table.insert(rows, {
            key = e.tr("tt_loss", "Loss"),
            value = string.format(e.tr("tt_loss_value", "%d peer(s) losing packets, worst %s"), d.lossy, e.percentText(d.lossMax)),
        })
    end

    table.insert(rows, { key = e.tr("tt_traffic", "Traffic"), value = string.format("↓%s ↑%s", e.bytes(d.rx), e.bytes(d.tx)) })

    if info ~= nil and info.version ~= "" then
        table.insert(rows, { key = e.tr("tt_version", "Version"), value = info.version })
    end

    table.insert(rows, { key = e.tr("tt_hint_key", "Hint"), value = e.tr("tt_hint", "Left: details · Right: refresh now") })
    return rows
end

-- ── Rendering ──────────────────────────────────────────────────────────────

local function render()
    local cfg = e.cfg()
    local w = settings()
    local level = e.level(cfg, snap, derived)

    -- When offline and hidden per settings, collapse the whole widget (frees the slot for others)
    if w.hideWhenStopped and level == "off" then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    -- On state change (running ⇄ offline), notify once per settings
    if cfg.notify and lastLevel ~= nil and level ~= lastLevel then
        if level == "off" and (lastLevel == "ok" or lastLevel == "warn") then
            noctalia.notifyError(e.tr("notify_down_title", "EasyTier disconnected"), e.tr("notify_down_body", "easytier-cli can no longer reach the core; the mesh may be down"))
        elseif (level == "ok" or level == "warn") and lastLevel == "off" then
            noctalia.notify(e.tr("notify_up_title", "EasyTier recovered"), e.tr("notify_up_body", "the core is reachable again"))
        end
    end
    lastLevel = level

    local info = e.nodeInfo(snap)
    local d = derived or e.derive(snap, cfg)
    local role = e.roleOf(level)

    if w.showGlyph then
        barWidget.setGlyph(w.glyph)
        barWidget.setGlyphColor(glyphRole(cfg, level))
    else
        barWidget.setGlyph("")
    end

    barWidget.setText(barText(w, snap, d, info))
    -- When normal, fall back to the widget's own text color; only take over on error/warning
    if level == "ok" or level == "loading" then
        barWidget.setColor("on_surface")
    else
        barWidget.setColor(role)
    end

    barWidget.setTooltip(buildTooltip(cfg, w, snap, level))
end

-- ── Fetching ───────────────────────────────────────────────────────────────

local function request()
    if inflight then
        return
    end
    local cfg = e.cfg()
    inflight = true
    e.fetch(cfg, e.FAST_SUBS, function(result)
        inflight = false
        lastFetchAt = os.time()
        snap = result
        derived = e.derive(result, cfg)
        render()
    end)
end

-- ── Pointer callbacks ──────────────────────────────────────────────────────

--- Left click: bound to panel-toggle by default in the manifest; fallback when the user rebinds it to none
function onClick()
    noctalia.togglePanel("ylxc/easytier:panel")
end

--- Right click: refetch immediately (ignores the refresh interval)
function onRightClick()
    if e.cliAvailable(e.cfg()) then
        request()
    end
    noctalia.log("[easytier] manual refresh")
end

function onIpc(event, _payload)
    if event == "refresh" then
        request()
    elseif event == "panel" then
        noctalia.togglePanel("ylxc/easytier:panel")
    end
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

function update()
    local cfg = e.cfg()
    noctalia.setUpdateInterval(math.max(1, math.floor(cfg.refresh / 2)) * 1000)
    -- Fetch when due (tick is denser than the refresh interval, so a 10s refresh is not slowed by a 12s tick)
    if not inflight and os.time() - lastFetchAt >= cfg.refresh then
        request()
    end
end

update()
