--!nonstrict
-- WiFi Enterprise launcher provider ("/eap"): opens the panel, or jumps
-- straight to connecting an already-configured 802.1X profile. Read-only
-- like the panel/bar - it only reads eapwifi.profiles and, to connect,
-- writes the same eapwifi.cmd command channel service.luau already handles.

local OPEN_ID = "__open"

local function buildResults(query)
  local profiles = noctalia.state.get("eapwifi.profiles") or {}
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

  for _, row in ipairs(profiles) do
    if not row.active then
      local score = 0
      if query ~= "" then
        score = noctalia.fuzzyScore(query, row.name)
      end
      if score ~= nil then
        table.insert(results, {
          id = row.uuid,
          title = noctalia.tr("launcher.connect_title", { name = row.name }),
          subtitle = row.eap .. "/" .. row.phase2,
          glyph = "plug",
          score = score,
        })
      end
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
    noctalia.togglePanel("andrewdems/wifi-enterprise:panel")
    return
  end
  noctalia.state.set("eapwifi.cmd", { op = "connect", uuid = id })
end
