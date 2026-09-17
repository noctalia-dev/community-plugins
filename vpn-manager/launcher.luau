--!nonstrict
-- VPN Manager launcher provider ("/vpn"): opens the panel, or jumps straight
-- to connecting/disconnecting a VPN. Read-only like the panel/bar - it only
-- reads vpn.connections and, to act, writes the same vpn.cmd command channel
-- service.luau already handles.

local OPEN_ID = "__open"

local function findRow(connections, uuid)
  for _, row in ipairs(connections) do
    if row.uuid == uuid then
      return row
    end
  end
  return nil
end

local function buildResults(query)
  local connections = noctalia.state.get("vpn.connections") or {}
  local results = {}

  local openScore = 0
  if query ~= "" then
    openScore = noctalia.fuzzyScore(query, noctalia.tr("launcher.open_title"))
  end
  if openScore ~= nil then
    table.insert(results, {
      id = OPEN_ID,
      title = noctalia.tr("launcher.open_title"),
      subtitle = noctalia.tr("launcher.open_subtitle"),
      glyph = "shield-lock",
      score = openScore,
    })
  end

  for _, row in ipairs(connections) do
    local score = 0
    if query ~= "" then
      score = noctalia.fuzzyScore(query, row.name)
    end
    if score ~= nil then
      table.insert(results, {
        id = row.uuid,
        title = row.active and noctalia.tr("launcher.disconnect_title", { name = row.name })
          or noctalia.tr("launcher.connect_title", { name = row.name }),
        subtitle = row.protocol,
        glyph = row.active and "plug-off" or "plug",
        score = score,
      })
    end
  end

  table.sort(results, function(a, b)
    return (a.score or 0) > (b.score or 0)
  end)
  return results
end

function onQuery(query)
  query = noctalia.string.trim(query)
  launcher.setResults(query, buildResults(query))
end

function onActivate(id)
  if id == "" then
    return
  end
  if id == OPEN_ID then
    noctalia.togglePanel("andrewdems/vpn-manager:panel")
    return
  end
  local connections = noctalia.state.get("vpn.connections") or {}
  local row = findRow(connections, id)
  if row == nil then
    return
  end
  noctalia.state.set("vpn.cmd", { op = row.active and "disconnect" or "connect", uuid = id })
end
