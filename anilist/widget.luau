--!nonstrict
-- AniList (UNOFFICIAL) bar widget: opens the library panel and shows a configurable list count.

local PANEL_ID = "cleboost/anilist:library"

local open = false
local snapshot = noctalia.state.get("anilist_snapshot") or {}

local function tr(key, subst)
  return noctalia.tr("widget." .. key, subst)
end

local function matchesStatus(entry, statuses)
  for _, status in ipairs(statuses) do
    if entry.status == status then
      return true
    end
  end
  return false
end

local function countEntries(rows, statuses)
  local n = 0
  for _, entry in ipairs(rows or {}) do
    if not statuses or matchesStatus(entry, statuses) then
      n += 1
    end
  end
  return n
end

local COUNT_MODES = {
  current = {
    tooltip = "tooltip_current",
    count = function(anime, _)
      return countEntries(anime, { "CURRENT", "REPEATING" })
    end,
  },
  completed = {
    tooltip = "tooltip_completed",
    count = function(anime, _)
      return countEntries(anime, { "COMPLETED" })
    end,
  },
  total = {
    tooltip = "tooltip_total",
    count = function(anime, _)
      return #anime
    end,
  },
  in_progress = {
    tooltip = "tooltip_in_progress",
    count = function(anime, manga)
      local statuses = { "CURRENT", "REPEATING" }
      return countEntries(anime, statuses) + countEntries(manga, statuses)
    end,
  },
  planning = {
    tooltip = "tooltip_planning",
    count = function(anime, _)
      return countEntries(anime, { "PLANNING" })
    end,
  },
}

local function activeCountMode()
  local mode = noctalia.getConfig("count_mode")
  if type(mode) ~= "string" or mode == "" then
    mode = "current"
  end
  return COUNT_MODES[mode] or COUNT_MODES.current
end

local function render()
  local glyph = noctalia.getConfig("glyph") or "device-tv"
  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(if open then "primary" else "on_surface")

  if snapshot.loading then
    barWidget.setText("")
    barWidget.setTooltip(tr("tooltip_loading"))
    return
  end

  if snapshot.error and snapshot.error ~= "" and not snapshot.viewer then
    barWidget.setText("")
    barWidget.setTooltip(tr("tooltip_error", { error = snapshot.error }))
    return
  end

  local mode = activeCountMode()
  local count = mode.count(snapshot.anime or {}, snapshot.manga or {})
  if count > 0 then
    barWidget.setText(tostring(count))
    barWidget.setTooltip(tr(mode.tooltip, { count = count }))
  else
    barWidget.setText("")
    barWidget.setTooltip(tr("tooltip_empty"))
  end
end

noctalia.state.watch("anilist_open", function(value)
  open = value == true
  render()
end)

noctalia.state.watch("anilist_snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function update()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  noctalia.runAsync("xdg-open 'https://anilist.co/home' >/dev/null 2>&1")
end

render()
