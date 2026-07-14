--!nonstrict
-- portctl — bar widget.
-- Count syncs with panel filters (portctl_visible_count).
-- Falls back to service total when panel not open.

local visibleCount = nil  -- set by panel on each render

local function applyCount(n)
  barWidget.setVisible(n > 0)
  barWidget.setGlyph(noctalia.getConfig("glyph") or "plug")
  barWidget.setText(tostring(n))
end

-- Panel publishes filtered count on every render
noctalia.state.watch("portctl_visible_count", function(n)
  visibleCount = n
  applyCount(n or 0)
end)

-- Service publishes stats; use count_tcp (matches panel default: TCP only)
noctalia.state.watch("portctl_stats", function(stats)
  if visibleCount ~= nil then return end  -- panel count takes priority
  local n = (stats and stats.count_tcp) or (stats and stats.count) or 0
  applyCount(n)
end)

-- Cold start: apply whatever is already in state
local v = noctalia.state.get("portctl_visible_count")
if v ~= nil then
  visibleCount = v
  applyCount(v)
else
  local stats = noctalia.state.get("portctl_stats")
  local n = (stats and stats.count_tcp) or (stats and stats.count) or 0
  applyCount(n)
end

function onClick()
  noctalia.togglePanel("rxtsel/portctl:panel")
end
