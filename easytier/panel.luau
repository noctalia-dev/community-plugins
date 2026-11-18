--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau — EasyTier detail panel
--
-- Top to bottom:
--   Self card   virtual IP, network name, version, NAT type, public address, instance ID, listeners
--   Overview    peer count / direct / relay / best and average latency / cumulative traffic
--   Peers       per peer: cost, latency, loss, tunnel protocol, NAT type, rx/tx bytes
--   Routes      ipv4, next hop, path hops, path latency (next_hop_lat / path_latency)
--   Connectors  reachability of each --peer address
--   Proxies     subnet proxy CIDRs (node.proxy_cidrs)
--   Forwards    configured port-forward entries
--
-- Open via: left click on the bar widget, or
--   noctalia msg panel-toggle ylxc/easytier:panel
-- ══════════════════════════════════════════════════════════════════════════

local e = require("./lib/easytier.luau")

local snap = nil
local derived = nil
local inflight = false
local lastFetchAt = 0
local open = false
local expanded = false
local serversOpen = false -- server peers (public shared nodes) collapsed by default
local routesOpen = false -- route table collapsed by default
local connectorsOpen = false -- connector list collapsed by default

local draw, request -- forward declarations (draw for card callbacks, request for offlineCard)

local function tr(key, fallback)
    return e.tr(key, fallback)
end

-- ── Colors and icons ──────────────────────────────────────────────────

local function costGlyph(cost)
    if cost == "p2p" then
        return "plug"
    end
    if cost == "relay" then
        return "route"
    end
    return "server"
end

local function lossRole(cfg, loss)
    if loss == nil or loss <= 0 then
        return "on_surface_variant"
    end
    if loss >= cfg.lossCrit then
        return "error"
    end
    return "tertiary"
end

-- ── Small widgets ───────────────────────────────────────────────────────

--- One tile in the overview: small label + large number.
--- flexGrow = 1 makes tiles on the same row share the width (four columns stay aligned);
--- minWidth keeps long values such as "cumulative traffic" from wrapping on a narrow panel.
local function tile(label, value, glyph, role)
    return ui.column({
        gap = 2,
        padding = 8,
        radius = 8,
        fill = "surface_container/0.35",
        flexGrow = 1,
        minWidth = 84,
    }, {
        ui.row({ gap = 5, align = "center" }, {
            ui.glyph({ name = glyph, size = 12, color = role or "on_surface_variant" }),
            ui.label({ text = label, color = "on_surface_variant", fontSize = 10, maxLines = 1 }),
        }),
        -- Long values (e.g. "↓13M ↑2.2M") drop one font size so four equal columns never wrap
        ui.label({
            text = value,
            fontWeight = "bold",
            fontSize = (#value > 9 and 11) or (#value > 6 and 12) or 13,
            color = role or "on_surface",
            maxLines = 1,
        }),
    })
end

--- One "key value key value …" row, used for the self card metadata
local function pairsRow(items)
    local children = {}
    for index, item in ipairs(items) do
        if index > 1 then
            table.insert(children, ui.spacer({ flexGrow = 1 }))
        end
        table.insert(children, ui.label({ text = item[1], color = "on_surface_variant", fontSize = 10 }))
        table.insert(children, ui.label({ text = item[2], fontSize = 11, maxLines = 1 }))
    end
    return ui.row({ gap = 6, align = "center" }, children)
end

local function sectionHead(glyph, text, count, extra)
    local head = {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = text, fontWeight = "semibold" }),
    }
    if count then
        table.insert(head, ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 11 }))
    end
    table.insert(head, ui.spacer({ flexGrow = 1 }))
    if extra then
        table.insert(head, extra)
    end
    return ui.row({ gap = 8, align = "center" }, head)
end

-- ── Collapsible section headers ────────────────────────────────────

--- Toggle header for a collapsible section: the whole row is clickable, right side shows "expand / collapse".
--- ui.button is avoided on purpose: a button must be the last child of its container, and cards follow here.
local function toggleHead(glyph, text, count, isOpen, toggle, tooltipText, extra)
    local head = {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = text, fontWeight = "semibold" }),
        ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 11 }),
        ui.spacer({ flexGrow = 1 }),
    }
    if extra ~= nil then
        table.insert(head, extra)
    end
    table.insert(head, ui.label({
        text = isOpen and tr("panel_collapse", "Collapse") or tr("panel_show", "Show"),
        color = "on_surface_variant",
        fontSize = 10,
    }))
    return ui.row({ gap = 8, align = "center", onClick = toggle, tooltip = tooltipText }, head)
end

-- ── Self card ──────────────────────────────────────────────────────────

local function selfCard(cfg, info)
    local role = e.roleOf(e.level(cfg, snap, derived))
    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "server", size = 14, color = role }),
            ui.label({ text = info.hostname, fontWeight = "semibold", maxLines = 1 }),
            info.ip and ui.label({ text = info.ip, color = "on_surface_variant", fontSize = 11 })
                or ui.label({ text = "", fontSize = 11 }),
            ui.spacer({ flexGrow = 1 }),
            info.network and ui.label({ text = info.network, color = "on_surface_variant", fontSize = 11 })
                or ui.label({ text = "", fontSize = 11 }),
        }),
    }

    local meta = {}
    if info.version ~= "" then
        table.insert(meta, { tr("panel_version", "Version"), info.version })
    end
    if info.nat ~= nil then
        table.insert(meta, { tr("panel_nat", "NAT"), info.nat })
    end
    if info.publicIp ~= nil then
        table.insert(meta, { tr("panel_public", "Public"), info.publicIp })
    end
    if #meta > 0 then
        table.insert(lines, pairsRow(meta))
    end

    local ids = {}
    local short = e.shortId(info.instId)
    if short then
        table.insert(ids, { tr("panel_inst", "Instance"), short })
    end
    if info.peerId ~= "" then
        table.insert(ids, { tr("panel_peer_id", "Peer ID"), info.peerId })
    end
    if info.publicPortRange then
        table.insert(ids, { tr("panel_port_range", "Public ports"), info.publicPortRange })
    end
    if #ids > 0 then
        table.insert(lines, pairsRow(ids))
    end

    if #info.listeners > 0 then
        table.insert(lines, ui.label({
            text = string.format("%s %s", tr("panel_listen", "Listen"), table.concat(info.listeners, "  ")),
            color = "on_surface_variant",
            fontSize = 10,
            maxLines = 2,
        }))
    end

    if #info.proxyCidrs > 0 then
        table.insert(lines, ui.label({
            text = string.format("%s %s", tr("panel_proxy", "Proxy CIDRs"), table.concat(info.proxyCidrs, ", ")),
            color = "on_surface_variant",
            fontSize = 10,
            maxLines = 2,
        }))
    end

    return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_container/0.45" }, lines)
end

-- ── Overview ─────────────────────────────────────────────────────────────

local function overview(cfg, d)
    local tiles = {
        tile(tr("panel_peers", "Peers"), tostring(d.total), "server", "primary"),
        tile(tr("panel_direct", "Direct"), tostring(d.direct), "plug", d.direct > 0 and "primary" or "on_surface_variant"),
        tile(tr("panel_relay", "Relay"), tostring(d.relay), "route", d.relay > 0 and "tertiary" or "on_surface_variant"),
        tile(tr("panel_best", "Best latency"), e.ms(d.best), "bolt", d.best ~= nil and e.roleOf(e.level(cfg, snap, d)) or "on_surface_variant"),
    }
    local lines = { ui.row({ gap = 6, align = "stretch" }, tiles) }

    local second = {
        tile(tr("panel_avg", "Avg latency"), e.ms(d.avg), "activity", "on_surface"),
        tile(tr("panel_worst", "Worst latency"), e.ms(d.worst), "activity", "on_surface_variant"),
        tile(tr("panel_loss", "Lossy peers"), tostring(d.lossy), "alert-triangle", d.lossy > 0 and "tertiary" or "on_surface_variant"),
        tile(tr("panel_traffic", "Traffic"), string.format("↓%s ↑%s", e.bytes(d.rx), e.bytes(d.tx)), "cloud", "on_surface"),
    }
    table.insert(lines, ui.row({ gap = 6, align = "stretch" }, second))
    return ui.column({ gap = 6 }, lines)
end

-- ── Peer cards ─────────────────────────────────────────────────────────

local function peerCard(cfg, row)
    local role = e.roleOf(row.level)
    local tooltip = string.format("%s\n%s %s\nID %s", row.hostname, tr("panel_cost", "cost"), row.costText, row.id)

    local head = {
        ui.glyph({ name = costGlyph(row.cost), size = 13, color = role }),
        ui.label({ text = row.hostname, fontWeight = "semibold", maxLines = 1 }),
    }
    if row.ip then
        table.insert(head, ui.label({ text = row.ip, color = "on_surface_variant", fontSize = 10 }))
    end
    table.insert(head, ui.spacer({ flexGrow = 1 }))
    table.insert(head, ui.label({ text = row.costText, color = "on_surface_variant", fontSize = 10 }))
    table.insert(head, ui.label({ text = e.ms(row.latency), fontWeight = "bold", color = role, fontSize = 12 }))

    local meta = {
        ui.label({
            text = string.format("%s %s", tr("panel_loss_rate", "loss"), e.percentText(row.loss)),
            color = lossRole(cfg, row.loss),
            fontSize = 10,
        }),
        ui.label({ text = row.proto, color = "on_surface_variant", fontSize = 10 }),
    }
    if row.nat then
        table.insert(meta, ui.label({ text = row.nat, color = "on_surface_variant", fontSize = 10 }))
    end
    if row.version ~= "" and tooltip ~= nil then
        table.insert(meta, ui.label({ text = row.version, color = "on_surface_variant", fontSize = 10 }))
    end
    table.insert(meta, ui.spacer({ flexGrow = 1 }))
    table.insert(meta, ui.label({
        text = string.format("↓%s ↑%s", e.bytes(row.rx or 0), e.bytes(row.tx or 0)),
        color = "on_surface_variant",
        fontSize = 10,
    }))

    local lines = {
        ui.row({ gap = 8, align = "center" }, head),
        ui.row({ gap = 10, align = "center" }, meta),
    }

    if row.loss ~= nil and row.loss > 0 then
        table.insert(lines, ui.progress({
            progress = math.min(1, row.loss / 100),
            height = 3,
            radius = 2,
            fill = lossRole(cfg, row.loss),
            track = "surface_container",
        }))
    end

    return ui.column({
        gap = 5,
        padding = 9,
        radius = 9,
        fill = "surface_container/0.35",
        tooltip = tooltip,
    }, lines)
end

local function peerSection(cfg, rows)
    local lines = {}
    local limit = cfg.maxPeers
    local shown = #rows

    if not expanded and #rows > limit then
        shown = limit
    end

    if #rows == 0 then
        table.insert(lines, ui.label({
            text = tr("panel_no_peer", "No other peer yet."),
            color = "on_surface_variant",
            fontSize = 11,
        }))
    else
        for index = 1, shown do
            table.insert(lines, peerCard(cfg, rows[index]))
        end
    end

    -- The button must be the last child of this container, otherwise sibling nodes stop rendering entirely
    if #rows > limit then
        table.insert(lines, ui.button({
            text = expanded and tr("panel_collapse", "Collapse") or string.format(tr("panel_expand", "Show %d more"), #rows - limit),
            glyph = expanded and "chevron-up" or "chevron-down",
            glyphSize = 13,
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                expanded = not expanded
                draw()
            end,
        }))
    end

    return ui.column({ gap = 6 }, lines)
end

--- Header row of the server peers section: collapsed by default (serversOpen = false), availability text on the right.
local function serverHead(count, d)
    return toggleHead("cloud", tr("panel_servers", "Servers"), count, serversOpen, function()
        serversOpen = not serversOpen
        draw()
    end, tr("panel_servers_toggle", "Click to show or hide server nodes"), ui.label({
        -- Server availability: one unavailable server is enough to flag it with the alert color (bar icon turns red when all are down)
        text = e.serversText(d),
        color = ((d and (d.serversDown or 0) > 0) and "error") or "on_surface_variant",
        fontSize = 10,
    }))
end

-- ── Routes / connectors / proxies / forwards ──────────────────────

local function routeSection(cfg, routes)
    local lines = {}
    local shown = math.min(#routes, 12)
    for index = 1, shown do
        local r = routes[index]
        local latency = e.num(r.path_latency)
        local role = "on_surface_variant"
        if latency ~= nil and latency >= cfg.critLatency then
            role = "error"
        elseif latency ~= nil and latency >= cfg.warnLatency then
            role = "tertiary"
        end
        local hostname = tostring(r.hostname or "?")
        local hop = tostring(r.next_hop_hostname or "-")
        table.insert(lines, ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = hostname, fontSize = 11, fontWeight = "semibold", maxLines = 1 }),
            ui.label({
                text = (type(r.ipv4) == "string" and r.ipv4 ~= "") and r.ipv4 or "-",
                color = "on_surface_variant",
                fontSize = 10,
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = string.format(tr("panel_hop", "via %s"), hop),
                color = "on_surface_variant",
                fontSize = 10,
                maxLines = 1,
            }),
            ui.label({
                text = string.format(tr("panel_hops", "%d hops"), tonumber(r.path_len) or 0),
                color = "on_surface_variant",
                fontSize = 10,
            }),
            ui.label({ text = e.ms(latency), fontSize = 11, fontWeight = "bold", color = role }),
        }))
    end
    if #routes > shown then
        table.insert(lines, ui.label({
            text = string.format(tr("panel_more", "%d more…"), #routes - shown),
            color = "on_surface_variant",
            fontSize = 10,
        }))
    end
    return ui.column({ gap = 5 }, lines)
end

local function connectorSection(connectors)
    local lines = {}
    for _, entry in ipairs(connectors) do
        local ok = entry.status == 0
        table.insert(lines, ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = ok and "plug" or "alert-triangle", size = 12, color = ok and "primary" or "error" }),
            ui.label({ text = entry.url, fontSize = 11, maxLines = 1 }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = ok and tr("panel_connected", "connected") or string.format(tr("panel_status_code", "status %d"), entry.status),
                color = ok and "on_surface_variant" or "error",
                fontSize = 10,
            }),
        }))
    end
    return ui.column({ gap = 5 }, lines)
end

--- Proxies and port forwards: fields vary across versions, skip what is missing so nothing blows up
local function genericSection(entries, keys)
    local lines = {}
    for _, entry in ipairs(entries) do
        local parts = {}
        if type(entry) == "table" then
            for _, key in ipairs(keys) do
                local value = entry[key]
                if type(value) == "string" and value ~= "" then
                    table.insert(parts, value)
                elseif type(value) == "number" then
                    table.insert(parts, tostring(value))
                end
            end
            if #parts == 0 then
                local encoded = noctalia.json.encode(entry, false)
                if type(encoded) == "string" and encoded ~= "" then
                    table.insert(parts, encoded)
                end
            end
        else
            table.insert(parts, tostring(entry))
        end
        if #parts > 0 then
            table.insert(lines, ui.label({
                text = table.concat(parts, " · "),
                fontSize = 11,
                maxLines = 1,
            }))
        end
    end
    return ui.column({ gap = 5 }, lines)
end

-- ── Diagnostics when not running ────────────────────────────────────

local function offlineCard(cfg)
    local found = e.cliAvailable(cfg)
    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
            ui.label({ text = tr("panel_offline", "EasyTier core is not running, or the RPC portal is unreachable"), fontWeight = "semibold" }),
        }),
        ui.label({
            text = string.format(
                tr("panel_cli_line", "easytier-cli: %s"),
                found and e.cliPath(cfg) or tr("panel_cli_missing", "not found (set an absolute path in the plugin settings)")
            ),
            color = found and "on_surface_variant" or "error",
            fontSize = 11,
            maxLines = 2,
        }),
        ui.label({
            text = string.format(
                tr("panel_rpc_line", "RPC portal: %s"),
                cfg.portal ~= "" and cfg.portal or "127.0.0.1:15888"
            ),
            color = "on_surface_variant",
            fontSize = 11,
        }),
        ui.label({
            text = tr("panel_offline_hint", "Make sure easytier-core is running and its --rpc-portal matches this plugin's setting."),
            color = "on_surface_variant",
            fontSize = 10,
            opacity = 0.8,
        }),
    }
    if snap ~= nil and snap.failed.node ~= nil then
        table.insert(lines, ui.label({
            text = string.format(tr("panel_fail_reason", "Last failure: %s"), tostring(snap.failed.node)),
            color = "on_surface_variant",
            fontSize = 10,
        }))
    end
    -- Button goes last
    table.insert(lines, ui.button({
        text = tr("panel_retry", "Retry"),
        glyph = "refresh",
        glyphSize = 13,
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
            request()
        end,
    }))
    return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_container/0.45" }, lines)
end

-- ── Body ─────────────────────────────────────────────────────────────────

local function body(cfg)
    local nodes = {}

    if snap ~= nil and snap.node == nil then
        table.insert(nodes, offlineCard(cfg))
        return nodes
    end
    if snap == nil then
        table.insert(nodes, ui.label({
            text = tr("panel_loading", "Reading easytier-cli…"),
            color = "on_surface_variant",
        }))
        return nodes
    end

    local info = e.nodeInfo(snap)
    local d = derived or e.derive(snap, cfg)

    if info ~= nil then
        table.insert(nodes, selfCard(cfg, info))
    end
    table.insert(nodes, overview(cfg, d))

    table.insert(nodes, ui.spacer({ height = 4 }))
    -- Devices and server peers are split in two sections: public shared servers get their own section, collapsed by default
    local normalRows, serverRows = e.splitRows(e.rows(snap, cfg), cfg)

    table.insert(nodes, sectionHead("server", tr("panel_peers", "Peers"), #normalRows))
    table.insert(nodes, peerSection(cfg, normalRows))

    if #serverRows > 0 then
        table.insert(nodes, serverHead(#serverRows, d))
        if serversOpen then
            table.insert(nodes, peerSection(cfg, serverRows))
        end
    end

    if snap.routes ~= nil and #snap.routes > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, toggleHead("route", tr("panel_routes", "Routes"), #snap.routes, routesOpen, function()
            routesOpen = not routesOpen
            draw()
        end, tr("panel_routes_toggle", "Click to show or hide the route table")))
        if routesOpen then
            table.insert(nodes, routeSection(cfg, snap.routes))
        end
    end

    if snap.connectors ~= nil and #snap.connectors > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, toggleHead("plug", tr("panel_connectors", "Connectors"), #snap.connectors, connectorsOpen, function()
            connectorsOpen = not connectorsOpen
            draw()
        end, tr("panel_connectors_toggle", "Click to show or hide the connector list")))
        if connectorsOpen then
            table.insert(nodes, connectorSection(e.connectorRows(snap)))
        end
    end

    if snap.proxies ~= nil and #snap.proxies > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, sectionHead("cloud", tr("panel_proxy_title", "Subnet proxy"), #snap.proxies))
        table.insert(nodes, genericSection(snap.proxies, { "cidr", "proxy_cidrs", "bind_addr", "dst_addr" }))
    end

    if snap.forwards ~= nil and #snap.forwards > 0 then
        table.insert(nodes, ui.spacer({ height = 4 }))
        table.insert(nodes, sectionHead("plug", tr("panel_forward", "Port forwarding"), #snap.forwards))
        table.insert(nodes, genericSection(snap.forwards, { "proto", "bind_addr", "dst_addr", "bind_addr_display" }))
    end

    if cfg.extras and snap.routes == nil and snap.failed.route ~= nil then
        table.insert(nodes, ui.label({
            text = string.format(tr("panel_route_failed", "Route table failed: %s"), tostring(snap.failed.route)),
            color = "tertiary",
            fontSize = 10,
        }))
    end

    return nodes
end

-- ── Fetching ─────────────────────────────────────────────────────────────

local function subs(cfg)
    if cfg.extras then
        return e.FULL_SUBS
    end
    return e.FAST_SUBS
end

request = function()
    if inflight then
        return
    end
    local cfg = e.cfg()
    inflight = true
    e.fetch(cfg, subs(cfg), function(result)
        inflight = false
        lastFetchAt = os.time()
        snap = result
        derived = e.derive(result, cfg)
        draw()
    end)
end

-- ── Rendering ────────────────────────────────────────────────────────────

draw = function()
    local cfg = e.cfg()
    local level = e.level(cfg, snap, derived)
    local role = e.roleOf(level)

    local head = {
        ui.glyph({ name = "network", size = 15, color = role }),
        ui.label({ text = "EasyTier", fontWeight = "bold", fontSize = 15 }),
        ui.label({ text = e.statusText(cfg, snap), color = role, fontSize = 11, maxLines = 1 }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({
            text = string.format(tr("panel_updated", "Updated %s"), os.date("%H:%M:%S")),
            color = "on_surface_variant",
            fontSize = 11,
        }),
        ui.button({
            glyph = inflight and "loader" or "refresh",
            glyphSize = 14,
            variant = "ghost",
            controlSize = "sm",
            tooltip = tr("panel_refresh", "Read again"),
            onClick = function()
                request()
            end,
        }),
    }

    local footer = {
        ui.label({
            text = string.format(
                tr("panel_source", "Source: %s (read-only, EasyTier config is never modified)"),
                e.cliPath(cfg)
            ),
            color = "on_surface_variant",
            fontSize = 10,
            opacity = 0.7,
            maxLines = 1,
        }),
    }
    -- Header row + body + footer all go into the scroll view, and the scroll view is rendered as the root node.
    -- ylxc-qweather uses exactly this structure (root = ui.scroll + padding/gap);
    -- if instead a flexGrow scroll sits inside a column, the host flex layout squeezes
    -- the scroll view into a sliver and only the self card stays visible (hit this in testing).
    local content = body(cfg)
    table.insert(content, ui.column({ gap = 2 }, footer))
    table.insert(content, 1, ui.row({ gap = 8, align = "center" }, head))

    panel.render(ui.scroll({ flexGrow = 1, gap = 10, padding = 14 }, content))
end

-- ── Lifecycle ──────────────────────────────────────────────────────────

function onOpen(_context)
    open = true
    noctalia.setUpdateInterval(1000)
    request()
    draw()
end

function onClose()
    open = false
end

function update()
    if not open then
        return
    end
    local cfg = e.cfg()
    if os.time() - lastFetchAt >= cfg.refresh then
        request()
    end
end

function onIpc(event, _payload)
    if event == "refresh" then
        request()
    end
end

draw()
