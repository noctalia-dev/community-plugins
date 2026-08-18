--!nonstrict
-- Mihomo Control — control panel.
--
-- A settings-style panel driven by the service's "mihomo.*" state. Every
-- action goes through the "mihomo.command" channel so the service stays the
-- single owner of HTTP access.
--
-- Sections:
--   1. Header: title, connection status, close button.
--   2. Connection: mode select (rule/global/direct) and refresh button.
--   3. Traffic: live up/down rates, totals, memory, active connections, and
--      a "close all connections" action.
--   4. Proxy groups: one card per group — current selection, member select,
--      and a latency-test button.

local MODES = { "rule", "global", "direct" }
local GROUP_DRAG_TYPE = "mihomo-proxy-group"
local GROUP_DROP_HIT_SLOP = 128

local snapshot = {
  connection = {},
  config = {},
  traffic = {},
  connections = {},
  groups = {},
}

-- Rolling traffic-rate history for the graph: one sample per published value
-- change, capped so the window stays fixed.
local TRAFFIC_HISTORY = 90
local down_history = {}
local up_history = {}

local function record_traffic(traffic)
  local down = tonumber(traffic.down) or 0
  local up = tonumber(traffic.up) or 0
  local last_index = #down_history
  if last_index == 0 or down_history[last_index] ~= down or up_history[last_index] ~= up then
    table.insert(down_history, down)
    table.insert(up_history, up)
    if #down_history > TRAFFIC_HISTORY then
      table.remove(down_history, 1)
      table.remove(up_history, 1)
    end
  end
end

local function normalized_series(values, peak)
  local out = {}
  for i, value in ipairs(values) do
    out[i] = peak > 0 and value / peak or 0
  end
  return out
end

local function refresh_snapshot()
  snapshot.connection = noctalia.state.get("mihomo.connection") or snapshot.connection
  snapshot.config = noctalia.state.get("mihomo.config") or snapshot.config
  snapshot.traffic = noctalia.state.get("mihomo.traffic") or snapshot.traffic
  snapshot.connections = noctalia.state.get("mihomo.connections") or snapshot.connections
  snapshot.groups = noctalia.state.get("mihomo.groups") or snapshot.groups
  record_traffic(snapshot.traffic)
end

local function send_command(cmd)
  cmd.seq = math.floor(os.clock() * 1000000)
  noctalia.state.set("mihomo.command", cmd)
end

-- Expansion state for proxy-group cards: collapsed by default so long member
-- lists do not flood the panel. Persists across re-renders while the panel
-- script stays loaded; a fresh panel starts collapsed again.
local expanded_groups = {}
local render -- forward declaration; assigned below

local function toggle_group(group_name)
  expanded_groups[group_name] = not expanded_groups[group_name]
  render()
end

-- ── Formatting helpers (small duplicates per the plugin sandbox) ────────────

local function format_rate(bytes_per_second)
  local value = tonumber(bytes_per_second) or 0
  if value >= 1024 * 1024 * 1024 then
    return string.format("%.2f GB/s", value / (1024 * 1024 * 1024))
  end
  if value >= 1024 * 1024 then
    return string.format("%.1f MB/s", value / (1024 * 1024))
  end
  if value >= 1024 then
    return string.format("%.1f KB/s", value / 1024)
  end
  return string.format("%d B/s", value)
end

local function format_total(bytes)
  local value = tonumber(bytes) or 0
  if value >= 1024 ^ 4 then
    return string.format("%.2f TB", value / (1024 ^ 4))
  end
  if value >= 1024 ^ 3 then
    return string.format("%.2f GB", value / (1024 ^ 3))
  end
  if value >= 1024 ^ 2 then
    return string.format("%.1f MB", value / (1024 ^ 2))
  end
  if value >= 1024 then
    return string.format("%.1f KB", value / 1024)
  end
  return string.format("%d B", value)
end

local function latency_text(delay)
  if delay == nil then
    return "—"
  end
  if delay > 0 then
    return `{delay} ms`
  end
  return noctalia.tr("panel.timeout")
end

local function latency_color(delay)
  if delay == nil then
    return "on_surface_variant"
  end
  if delay > 0 then
    if delay <= 300 then
      return "primary"
    end
    if delay <= 800 then
      return "warning"
    end
    return "error"
  end
  return "error"
end

-- The status chip keeps the classic green/amber/red identity instead of theme
-- roles, but uses darker shades in light mode so it stays readable on light
-- surfaces.
local function status_color()
  if noctalia.isDarkMode() then
    return { online = "#4ade80", connecting = "#facc15", offline = "#f87171" }
  end
  return { online = "#15803d", connecting = "#a16207", offline = "#b91c1c" }
end

-- A single "overall" latency per group: the currently selected member's delay
-- (Selector/URLTest/Fallback), or the best tested member latency otherwise
-- (LoadBalance has no selection). Returns 0 when every tested member failed.
local function group_latency(group)
  if group.now and group.now ~= "" then
    for _, member in ipairs(group.members) do
      if member.name == group.now and member.delay ~= nil then
        return member.delay
      end
    end
  end

  local best = nil
  local any_tested = false
  for _, member in ipairs(group.members) do
    local delay = member.delay
    if delay ~= nil then
      any_tested = true
      if delay > 0 and (best == nil or delay < best) then
        best = delay
      end
    end
  end
  if best ~= nil then
    return best
  end
  if any_tested then
    return 0
  end
  return nil
end

-- ── UI helpers ──────────────────────────────────────────────────────────────

local function connection_text()
  local conn = snapshot.connection
  local endpoint = `{conn.host or ""}:{conn.port or ""}`
  if conn.status == "online" then
    local version = tostring(conn.version or "")
    return version ~= ""
      and noctalia.tr("panel.online_with_version", { version = version, endpoint = endpoint })
      or noctalia.tr("panel.online_plain", { endpoint = endpoint })
  end
  if conn.status == "connecting" then
    return endpoint
  end
  local err = tostring(conn.error or "")
  return err ~= ""
    and noctalia.tr("panel.offline_with_error", { error = err })
    or noctalia.tr("panel.offline_plain", { endpoint = endpoint })
end

local function status_chip()
  local conn = snapshot.connection
  local online = conn.status == "online"
  local connecting = conn.status == "connecting"
  local colors = status_color()
  local text = online
    and noctalia.tr("panel.status_online")
    or (connecting and noctalia.tr("panel.status_connecting") or noctalia.tr("panel.status_offline"))
  local color = online and colors.online or (connecting and colors.connecting or colors.offline)
  return ui.row({ gap = 6, align = "center", fill = "surface/0.6", radius = 999, paddingH = 10, paddingV = 4 }, {
    ui.box({ width = 8, height = 8, radius = 4, fill = color }),
    ui.label({ text = text, fontSize = 12, color = "on_surface_variant" }),
  })
end

local function controls_row()
  local mode = snapshot.config.mode or "rule"
  local index = 0
  for i, candidate in MODES do
    if candidate == mode then
      index = i - 1
      break
    end
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.select({
      options = {
        noctalia.tr("panel.mode_rule"),
        noctalia.tr("panel.mode_global"),
        noctalia.tr("panel.mode_direct"),
      },
      selectedIndex = index,
      onChange = function(index_text)
        local chosen = MODES[(tonumber(index_text) or 0) + 1]
        if chosen then
          send_command({ op = "mode", mode = chosen })
        end
      end,
    }),
    ui.button({
      text = noctalia.tr("panel.restart"),
      variant = "outline",
      onClick = function()
        send_command({ op = "restart" })
      end,
    }),
  })
end

local function traffic_card()
  local traffic = snapshot.traffic
  local connections = snapshot.connections
  local peak = 1
  for _, value in ipairs(down_history) do
    if value > peak then
      peak = value
    end
  end
  for _, value in ipairs(up_history) do
    if value > peak then
      peak = value
    end
  end
  return ui.column({ gap = 10, fill = "surface/0.5", radius = 12, padding = 12 }, {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.label({ text = noctalia.tr("panel.traffic"), fontWeight = "medium", color = "on_surface_variant" }),
      ui.label({
        text = `{connections.count or 0} {noctalia.tr("panel.connections")}`,
        color = "on_surface_variant",
        fontSize = 12,
      }),
    }),
    ui.graph({
      values = normalized_series(down_history, peak),
      values2 = normalized_series(up_history, peak),
      color = "primary",
      color2 = "secondary",
      lineWidth = 2,
      fillOpacity = 0.15,
      height = 72,
    }),
    ui.row({ gap = 16, align = "center" }, {
      ui.label({ text = `▼ {format_rate(traffic.down)}`, fontSize = 16, fontWeight = "bold", color = "primary" }),
      ui.label({ text = `▲ {format_rate(traffic.up)}`, fontSize = 16, fontWeight = "bold", color = "secondary" }),
    }),
    ui.row({ gap = 16, align = "center" }, {
      ui.label({
        text = `↓ {format_total(traffic.downTotal)} · ↑ {format_total(traffic.upTotal)} · {format_total(connections.memory)} {noctalia.tr("panel.memory")}`,
        color = "on_surface_variant",
        fontSize = 12,
      }),
    }),
  })
end

-- Thin insertion target before every group card, plus one after the final
-- card. Its drag-only halo covers the neighboring card body; overlapping
-- targets resolve to the closest insertion point. expandOnDrag then opens a
-- full-card gap, previewing the resulting layout before the pointer is released.
local function group_insertion_zone(index)
  return ui.dropZone({
    key = "group-gap-" .. index,
    accepts = { GROUP_DRAG_TYPE },
    value = tostring(index),
    onDrop = "onGroupDropped",
    height = 3,
    radius = 6,
    expandOnDrag = true,
    hitSlop = GROUP_DROP_HIT_SLOP,
  })
end

local function group_card(group)
  local name_text = group.name
  if group.hidden == true then
    name_text = name_text .. ` ({noctalia.tr("panel.hidden")})`
  end
  local expanded = expanded_groups[group.name] == true
  local overall = group_latency(group)

  local name_children = {
    ui.label({ text = name_text, fontWeight = "bold" }),
  }
  if group.now and group.now ~= "" then
    table.insert(name_children, ui.label({ text = ">", color = "on_surface_variant" }))
    table.insert(name_children, ui.label({
      text = group.now,
      color = "on_surface_variant",
      fontSize = 12,
      flexGrow = 1,
    }))
  end

  local children = {
    ui.row({ gap = 6, align = "center", justify = "space_between", onClick = function()
      toggle_group(group.name)
    end }, {
      -- Lift the complete slot, including its insertion zone, so no selector
      -- line remains at the source position while the card is being dragged.
      ui.dragSource({
        key = "group-grip-" .. group.name,
        dragType = GROUP_DRAG_TYPE,
        payload = group.name,
        previewAncestor = 3,
        liftFromLayout = true,
        width = 20,
        height = 20,
        align = "center",
        justify = "center",
        tooltip = noctalia.tr("panel.drag_group"),
      }, {
        ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 4, align = "center", flexGrow = 1 }, name_children),
      ui.button({
        glyph = "activity",
        tooltip = noctalia.tr("panel.delay_test"),
        variant = "ghost",
        onClick = function()
          send_command({ op = "delay_test", group = group.name })
        end,
      }),
    }),
    ui.row({ gap = 6, align = "center", justify = "space_between", onClick = function()
      toggle_group(group.name)
    end }, {
      ui.button({
        glyph = expanded and "chevron-down" or "chevron-right",
        variant = "ghost",
        onClick = function()
          toggle_group(group.name)
        end,
      }),
      ui.label({
        text = `{group.type or ""} · {noctalia.trp("panel.members_count", #group.members)}`,
        color = "on_surface_variant",
        fontSize = 12,
        flexGrow = 1,
      }),
      ui.label({
        text = latency_text(overall),
        fontSize = 12,
        fontWeight = "medium",
        color = latency_color(overall),
      }),
    }),
  }

  if expanded and #group.members > 0 then
    local member_rows = {}
    for _, member in ipairs(group.members) do
      local is_current = member.name == group.now
      local delay_text = latency_text(member.delay)
      local delay_color = latency_color(member.delay)
      table.insert(member_rows, ui.row({ gap = 6, align = "center", onClick = function()
        send_command({ op = "select", group = group.name, proxy = member.name })
      end }, {
        ui.box({ width = 6, height = 6, radius = 3, fill = is_current and "primary" or "surface_variant" }),
        ui.label({
          text = member.name,
          flexGrow = 1,
          color = is_current and "on_surface" or "on_surface_variant",
          fontSize = 12,
        }),
        ui.label({ text = delay_text, fontSize = 12, color = delay_color }),
      }))
    end
    table.insert(children, ui.column({ gap = 3 }, member_rows))
  elseif expanded then
    table.insert(children, ui.label({
      text = noctalia.tr("panel.no_members"),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end

  return ui.column({
    key = "group-card-" .. group.name,
    gap = 8,
    border = "outline",
    borderWidth = 1,
    radius = 10,
    padding = 10,
    flexGrow = 1,
  }, children)
end

local function group_slot(group, index)
  return ui.column({
    key = "group-slot-" .. group.name,
    gap = 3,
    flexGrow = 1,
  }, {
    group_insertion_zone(index),
    group_card(group),
  })
end

render = function()
  local groups = type(snapshot.groups) == "table" and snapshot.groups or {}

  local body = {
    controls_row(),
    traffic_card(),
  }

  if #groups > 0 then
    local group_children = {
      ui.row({ align = "center", gap = 8 }, {
        ui.label({
          text = noctalia.tr("panel.proxy_groups"),
          fontWeight = "medium",
          color = "on_surface_variant",
          flexGrow = 1,
        }),
        ui.button({
          text = noctalia.tr("panel.test_all"),
          variant = "ghost",
          onClick = function()
            send_command({ op = "delay_test_all" })
          end,
        }),
      }),
    }
    for i = 1, #groups, 2 do
      local row_children = { group_slot(groups[i], i) }
      if groups[i + 1] then
        table.insert(row_children, group_slot(groups[i + 1], i + 1))
      else
        table.insert(row_children, ui.box({ flexGrow = 1 }))
      end
      table.insert(group_children, ui.row({ gap = 10, align = "start" }, row_children))
    end
    table.insert(group_children, group_insertion_zone(#groups + 1))
    table.insert(body, ui.column({ gap = 10, fill = "surface/0.5", radius = 12, padding = 12 }, group_children))
  else
    table.insert(body, ui.column({ gap = 10, fill = "surface/0.5", radius = 12, padding = 12 }, {
      ui.label({ text = noctalia.tr("panel.proxy_groups"), fontWeight = "medium", color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("panel.no_groups"), color = "on_surface_variant" }),
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.column({ gap = 6 }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.image({ path = "icon.png", width = 16, height = 16 }),
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
        status_chip(),
        ui.button({
          glyph = "refresh",
          tooltip = noctalia.tr("panel.refresh"),
          variant = "ghost",
          onClick = function()
            send_command({ op = "refresh" })
          end,
        }),
        ui.button({
          glyph = "close",
          onClick = function()
            panel.close()
          end,
        }),
      }),
      ui.label({ text = connection_text(), color = "on_surface_variant", fontSize = 12 }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, body),
  }))
end

function onGroupDropped(payload, value)
  local insertion_index = tonumber(value)
  if type(payload) ~= "string" or payload == "" or insertion_index == nil then
    return
  end
  send_command({ op = "reorder_group", group = payload, index = insertion_index })
end

for _, key in {
  "mihomo.connection",
  "mihomo.config",
  "mihomo.traffic",
  "mihomo.connections",
  "mihomo.groups",
} do
  noctalia.state.watch(key, function(_value)
    refresh_snapshot()
    render()
  end)
end

function onOpen(_context)
  refresh_snapshot()
  render()
end

refresh_snapshot()
render()
