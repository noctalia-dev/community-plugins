--!nonstrict
-- CCF Deadlines panel: every upcoming submission round that passes the
-- plugin's filters, with search, a starred-only view, and live countdowns.
--
-- One row per round: it counts down to the abstract while that is ahead, then
-- to the paper. Click a row for its detail view (timeline, venue, acceptance
-- rates, ranks); the star pins a conference so it always shows first, is
-- preferred by the bar widget, and gets reminders.

local Common = require("./lib/common.luau")

local snapshot = nil
local filterText = ""
local view = "all" -- "all" | "starred"
local dirty = true
-- Building every row each second goes over the script CPU budget, so only the
-- first `limit` rows are built; "Show more" raises it.
local PAGE = 25
local limit = PAGE
local selectedId = nil -- round shown in the detail view, nil for the list

local render

local function matches(item, query)
  if query == "" then
    return true
  end
  local haystack = string.lower(`{item.title} {item.description} {item.sub} {item.comment or ""} {item.place or ""}`)
  for word in query:gmatch("%S+") do
    if not haystack:find(word, 1, true) then
      return false
    end
  end
  return true
end

local function visibleItems(now)
  local list = {}
  if snapshot == nil or type(snapshot.items) ~= "table" then
    return list
  end
  -- Starred conferences first, then the rest; each part stays in deadline
  -- order (snapshot.items is already sorted by due time).
  local query = string.lower(noctalia.string.trim(filterText))
  local rest = {}
  for _, item in ipairs(snapshot.items) do
    if item.due > now and (view ~= "starred" or item.starred) and matches(item, query) then
      table.insert(if item.starred then list else rest, item)
    end
  end
  for _, item in ipairs(rest) do
    table.insert(list, item)
  end
  return list
end

local function rankBadge(text, color, tooltip)
  return ui.row({
    tooltip = tooltip,
    paddingH = 5,
    height = 16,
    radius = 4,
    fill = `{color}/0.18`,
    align = "center",
    justify = "center",
  }, {
    ui.label({ text = text, fontSize = 9, fontWeight = "bold", color = color, maxLines = 1 }),
  })
end

local function itemRow(item, now)
  local remaining = item.due - now
  local color = Common.urgencyColor(remaining)

  local ccfKey = if item.ccf == "A" or item.ccf == "B" or item.ccf == "C" then item.ccf else "N"
  local badges = {
    rankBadge(`CCF {item.ccf}`, Common.rankColor(item.ccf), noctalia.tr(`badge.ccf.{string.lower(ccfKey)}`)),
  }
  if item.core ~= nil and item.core ~= "N" then
    table.insert(badges, rankBadge(`CORE {item.core}`, "on_surface_variant", noctalia.tr("badge.core", { rank = item.core })))
  end
  table.insert(badges, rankBadge(item.sub, "on_surface_variant", noctalia.tr("badge.area", {
    code = item.sub,
    name = Common.CATEGORIES[item.sub] or item.sub,
  })))
  if item.kind == "abstract" then
    local paper = if item.paperDue ~= nil then noctalia.formatTime("%a %m-%d %H:%M", item.paperDue) else "?"
    table.insert(badges, rankBadge(noctalia.tr("kind.abstract_short"), "secondary", noctalia.tr("badge.abstract", { paper = paper })))
  end

  local detail = {}
  if item.kind == "abstract" and item.paperDue ~= nil then
    table.insert(detail, noctalia.tr("panel.paper_on", { time = noctalia.formatTime("%m-%d", item.paperDue) }))
  end
  if type(item.comment) == "string" and item.comment ~= "" then
    table.insert(detail, item.comment)
  end
  if type(item.place) == "string" and item.place ~= "" then
    table.insert(detail, item.place)
  end
  if type(item.date) == "string" and item.date ~= "" then
    table.insert(detail, item.date)
  end

  local title = item.title
  local id = item.id
  return ui.row({
    key = `row-{id}`,
    gap = 8,
    padding = 8,
    radius = 10,
    fill = "surface_container",
    align = "center",
    tooltip = noctalia.tr("panel.row_hint"),
    onClick = function()
      selectedId = id
      render()
    end,
  }, {
    ui.button({
      key = `star-{id}`,
      glyph = item.starred and "star-filled" or "star",
      variant = "ghost",
      controlSize = "sm",
      width = 24,
      height = 24,
      glyphSize = 14,
      tooltip = noctalia.tr(item.starred and "panel.unstar" or "panel.star"),
      onClick = function()
        Common.request("toggle_star", { title = title })
      end,
    }),
    ui.column({ flexGrow = 1, gap = 3 }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = Common.itemTitle(item), fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
        ui.row({ gap = 4, align = "center" }, badges),
      }),
      ui.label({
        text = #detail > 0 and table.concat(detail, " · ") or item.description,
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.column({ gap = 2, align = "end" }, {
      ui.label({
        text = Common.countdown(remaining, remaining < 7 * 86400),
        fontSize = 12,
        fontWeight = "bold",
        color = color,
        maxLines = 1,
      }),
      ui.label({
        text = `{noctalia.tr(`milestone_short.{item.kind}`)} · {noctalia.formatTime("%a %m-%d %H:%M", item.due)}`,
        fontSize = 10,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
  })
end

local function tabButton(label, id)
  return ui.button({
    key = `tab-{id}`,
    text = label,
    variant = "ghost",
    controlSize = "sm",
    selected = view == id,
    onClick = function()
      view = id
      limit = PAGE
      render()
    end,
  })
end

local function statusLine()
  if snapshot == nil or snapshot.phase == "loading" then
    return noctalia.tr("status.loading"), "on_surface_variant"
  end
  if snapshot.error ~= nil then
    return snapshot.error, "error"
  end
  if snapshot.fetching then
    return noctalia.tr("status.refreshing"), "on_surface_variant"
  end
  if (snapshot.fetchedAt or 0) > 0 then
    return noctalia.tr("status.updated", {
      time = noctalia.formatTime("%Y-%m-%d %H:%M", snapshot.fetchedAt),
      count = snapshot.conferenceCount or 0,
    }), "on_surface_variant"
  end
  return "", "on_surface_variant"
end

-- ---------------------------------------------------------------- detail view

local function findItem(id)
  if snapshot == nil or type(snapshot.items) ~= "table" then
    return nil
  end
  for _, item in ipairs(snapshot.items) do
    if item.id == id then
      return item
    end
  end
  return nil
end

local function sectionLabel(text)
  return ui.label({ text = string.upper(text), fontSize = 10, fontWeight = "semibold", color = "on_surface_variant" })
end

local function dot(size, fill, border)
  return ui.row({ width = size, height = size, radius = size / 2, fill = fill, border = border, borderWidth = border and 2 or nil })
end

-- Milestones on a line, spaced by real time, with "now" marked.
local function timelineBar(item, now, nextDue)
  local points = { { now = true, due = now } }
  for _, m in ipairs(item.milestones or {}) do
    table.insert(points, m)
  end
  table.sort(points, function(a, b)
    return a.due < b.due
  end)
  local children = {}
  for i, point in ipairs(points) do
    if i > 1 then
      local gap = math.max(1, math.floor((point.due - points[i - 1].due) / 86400 + 0.5))
      table.insert(children, ui.box({
        height = 3,
        flexGrow = gap,
        fill = if point.due <= now then "primary" else "on_surface_variant/0.5",
      }))
    end
    if point.now then
      table.insert(children, dot(12, "tertiary/0.35", "tertiary"))
    elseif point.due <= now then
      table.insert(children, dot(9, "primary"))
    elseif point.due == nextDue then
      table.insert(children, dot(11, "primary/0.25", "primary"))
    else
      table.insert(children, dot(9, "surface", "primary/0.7"))
    end
  end
  local first, last = points[1].due, points[#points].due
  return ui.column({ gap = 4, align = "stretch" }, {
    ui.row({ align = "center", gap = 0, height = 14 }, children),
    ui.row({ align = "center" }, {
      ui.label({ text = noctalia.formatTime("%b %d, %Y", first), fontSize = 10, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = noctalia.formatTime("%b %d, %Y", last), fontSize = 10, color = "on_surface_variant" }),
    }),
  })
end

local function daysLeft(seconds)
  if seconds <= 0 then
    return noctalia.tr("detail.passed")
  end
  if seconds < 86400 then
    return Common.countdown(seconds)
  end
  local days = seconds // 86400
  return noctalia.tr(if days == 1 then "detail.day" else "detail.days", { count = days })
end

local function milestoneCard(m, now, isNext)
  local remaining = m.due - now
  local passed = remaining <= 0
  local nameRow = {
    ui.label({
      text = noctalia.tr(`milestone.{m.kind}`),
      fontSize = 12,
      fontWeight = "bold",
      color = if passed then "on_surface_variant" else "on_surface",
    }),
  }
  if isNext then
    table.insert(nameRow, ui.label({ text = noctalia.tr("detail.next"), fontSize = 9, fontWeight = "bold", color = "primary" }))
  end
  return ui.row({
    key = `ms-{m.kind}`,
    gap = 8,
    padding = 10,
    radius = 10,
    align = "center",
    fill = if isNext then "primary/0.12" else "surface_container",
    border = if isNext then "primary/0.5" else nil,
    borderWidth = if isNext then 1 else nil,
    opacity = if passed then 0.6 else 1,
  }, {
    ui.column({ flexGrow = 1, gap = 2 }, {
      ui.row({ gap = 6, align = "center" }, nameRow),
      ui.label({
        text = noctalia.formatTime("%H:%M, %b %d, %Y · %Z", m.due),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
    ui.label({
      text = daysLeft(remaining),
      fontSize = 12,
      fontWeight = "bold",
      color = if passed then "on_surface_variant" else Common.urgencyColor(remaining),
    }),
  })
end

local function detailView(item, now)
  local remaining = item.due - now

  local badges = {}
  local ccfKey = if item.ccf == "A" or item.ccf == "B" or item.ccf == "C" then item.ccf else "N"
  table.insert(badges, rankBadge(`CCF {item.ccf}`, Common.rankColor(item.ccf), noctalia.tr(`badge.ccf.{string.lower(ccfKey)}`)))
  if item.core ~= nil and item.core ~= "N" then
    table.insert(badges, rankBadge(`CORE {item.core}`, "on_surface_variant", noctalia.tr("badge.core", { rank = item.core })))
  end
  if item.thcpl ~= nil and item.thcpl ~= "N" then
    table.insert(badges, rankBadge(`THCPL {item.thcpl}`, "on_surface_variant", noctalia.tr("badge.thcpl", { rank = item.thcpl })))
  end
  table.insert(badges, rankBadge(Common.CATEGORIES[item.sub] or item.sub, "on_surface_variant", noctalia.tr("badge.area", {
    code = item.sub,
    name = Common.CATEGORIES[item.sub] or item.sub,
  })))

  local body = {
    ui.label({ text = item.description, fontSize = 12, color = "on_surface_variant", maxLines = 3 }),
  }
  if type(item.acc) == "table" and #item.acc > 0 then
    table.insert(body, ui.label({
      text = noctalia.tr("detail.acc", { rates = table.concat(item.acc, "  ·  ") }),
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 2,
    }))
  end
  table.insert(body, ui.row({ gap = 4, align = "center" }, badges))

  local facts = {}
  if type(item.date) == "string" and item.date ~= "" then
    table.insert(facts, ui.column({ gap = 2, flexGrow = 1 }, {
      sectionLabel(noctalia.tr("detail.dates")),
      ui.label({ text = item.date, fontSize = 12, color = "on_surface", maxLines = 2 }),
    }))
  end
  if type(item.place) == "string" and item.place ~= "" then
    table.insert(facts, ui.column({ gap = 2, flexGrow = 1 }, {
      sectionLabel(noctalia.tr("detail.venue")),
      ui.label({ text = item.place, fontSize = 12, color = "on_surface", maxLines = 2 }),
    }))
  end
  if #facts > 0 then
    table.insert(body, ui.row({ gap = 12, align = "start" }, facts))
  end
  if type(item.comment) == "string" and item.comment ~= "" then
    table.insert(body, ui.column({ gap = 2 }, {
      sectionLabel(noctalia.tr("detail.round")),
      ui.label({ text = item.comment, fontSize = 12, color = "on_surface", maxLines = 2 }),
    }))
  end

  table.insert(body, ui.column({ gap = 4, padding = 12, radius = 10, fill = "surface_container" }, {
    sectionLabel(noctalia.tr("detail.next_in", { kind = noctalia.tr(`milestone.{item.kind}`) })),
    ui.label({
      text = Common.countdown(remaining, true),
      fontSize = 24,
      fontWeight = "bold",
      color = Common.urgencyColor(remaining),
    }),
  }))

  local cards = {}
  local milestones = item.milestones or {}
  for _, m in ipairs(milestones) do
    table.insert(cards, milestoneCard(m, now, m.due == item.due and m.kind == item.kind))
  end
  if #milestones > 0 then
    table.insert(body, sectionLabel(noctalia.tr("detail.timeline")))
    table.insert(body, timelineBar(item, now, item.due))
    table.insert(body, ui.column({ gap = 6, align = "stretch" }, cards))
  end
  table.insert(body, ui.label({
    text = noctalia.tr("detail.source_tz", { tz = item.tz }),
    fontSize = 10,
    color = "on_surface_variant",
  }))

  local title = item.title
  return ui.column({ flexGrow = 1, gap = 10, padding = 4, align = "stretch" }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        tooltip = noctalia.tr("detail.back"),
        onClick = function()
          selectedId = nil
          render()
        end,
      }),
      ui.label({ text = Common.itemTitle(item), fontSize = 18, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
      ui.button({
        glyph = if item.starred then "star-filled" else "star",
        variant = "ghost",
        tooltip = noctalia.tr(if item.starred then "panel.unstar" else "panel.star"),
        onClick = function()
          Common.request("toggle_star", { title = title })
        end,
      }),
      ui.button({
        glyph = "external-link",
        variant = "ghost",
        tooltip = noctalia.tr("detail.open_site"),
        visible = type(item.link) == "string" and item.link ~= "",
        onClick = function()
          Common.openUrl(item.link)
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        onClick = function()
          panel.close()
        end,
      }),
    }),
    ui.scroll({ key = `detail-{item.id}`, flexGrow = 1, gap = 10, align = "stretch" }, body),
  })
end

render = function()
  dirty = false
  local now = Common.nowSec()
  if selectedId ~= nil then
    local item = findItem(selectedId)
    if item ~= nil and item.due > now then
      panel.render(detailView(item, now))
      return
    end
    selectedId = nil
  end
  local items = visibleItems(now)

  local rows = {}
  for index, item in ipairs(items) do
    if index > limit then
      break
    end
    table.insert(rows, itemRow(item, now))
  end
  if #items > limit then
    table.insert(rows, ui.button({
      key = `more-{limit}`,
      text = noctalia.tr("panel.show_more", { count = #items - limit }),
      variant = "ghost",
      onClick = function()
        limit += PAGE
        render()
      end,
    }))
  end
  if #rows == 0 then
    local message
    if snapshot == nil or snapshot.phase == "loading" then
      message = noctalia.tr("status.loading")
    elseif view == "starred" and filterText == "" then
      message = noctalia.tr("panel.no_starred")
    else
      message = noctalia.tr("status.none")
    end
    table.insert(rows, ui.column({ align = "center", justify = "center", paddingV = 32, gap = 8 }, {
      ui.glyph({ name = "calendar-event", size = 32, color = "on_surface_variant" }),
      ui.label({ text = message, color = "on_surface_variant", maxLines = 3 }),
    }))
  end

  local status, statusColor = statusLine()

  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 4, align = "stretch" }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "calendar-due", size = 26, color = "primary" }),
      ui.column({ flexGrow = 1, gap = 0 }, {
        ui.label({ text = noctalia.tr("title"), fontSize = 18, fontWeight = "bold" }),
        ui.label({ text = noctalia.tr("panel.subtitle", { count = #items }), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({
        glyph = "external-link",
        variant = "ghost",
        tooltip = noctalia.tr("panel.open_site"),
        onClick = function()
          Common.openUrl(Common.SITE_URL)
        end,
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        tooltip = noctalia.tr("panel.refresh"),
        onClick = function()
          Common.request("refresh")
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        onClick = function()
          panel.close()
        end,
      }),
    }),

    ui.row({ gap = 6, align = "center" }, {
      tabButton(noctalia.tr("panel.tab_all"), "all"),
      tabButton(noctalia.tr("panel.tab_starred"), "starred"),
      ui.input({
        key = "filter",
        value = filterText,
        placeholder = noctalia.tr("panel.filter"),
        flexGrow = 1,
        controlSize = "sm",
        onChange = function(value)
          filterText = tostring(value or "")
          limit = PAGE
          render()
        end,
      }),
    }),

    ui.scroll({ key = `scroll-{view}`, flexGrow = 1, gap = 6, align = "stretch" }, rows),

    ui.label({ text = status, fontSize = 10, color = statusColor, maxLines = 2 }),
  }))
end

noctalia.state.watch(Common.STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    dirty = true
  end
end)

panel.setWantsSecondTicks(true)

-- Context may name a conference ("mobisys") or a round id ("mobisys27:1") to
-- open straight into its detail view, e.g. from a keybind:
--   noctalia msg panel-open samxu29/ccf-deadlines:panel mobisys
function onOpen(context)
  limit = PAGE
  selectedId = nil
  snapshot = noctalia.state.get(Common.STATE_KEY) or snapshot
  local wanted = if type(context) == "string" then string.lower(noctalia.string.trim(context)) else ""
  if wanted ~= "" and snapshot ~= nil and type(snapshot.items) == "table" then
    local now = Common.nowSec()
    for _, item in ipairs(snapshot.items) do
      if item.due > now and (item.id == wanted or string.lower(item.title) == wanted) then
        selectedId = item.id
        break
      end
    end
  end
  render()
end

-- Second ticks keep the countdowns live while the panel is open.
function update()
  render()
end

snapshot = noctalia.state.get(Common.STATE_KEY)
render()
