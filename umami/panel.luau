--!nonstrict
local umami = require("./umami.luau")
local tr = noctalia.tr

local PERIODS = {
  { key = "24h", seconds = 86400, unit = 3600 },
  { key = "7d", seconds = 7 * 86400, unit = 86400 },
  { key = "30d", seconds = 30 * 86400, unit = 86400 },
  { key = "90d", seconds = 90 * 86400, unit = 86400 },
}
local SECTIONS = {
  { key = "pages", tabs = { "path", "fullPath", "entry", "exit" }, empty = "/" },
  { key = "sources", tabs = { "referrer", "channel" }, empty = "panel.direct" },
  { key = "environment", tabs = { "browser", "os", "device" }, empty = "panel.unknown" },
  { key = "location", tabs = { "country", "region", "city" }, empty = "panel.unknown" },
}
local UP = "primary"
local MUTED = "on_surface_variant"
local CHART_HEIGHT = 120
local PAD = 14

local period = PERIODS[1]
local websites = {}
local data = {}
local selected = nil
local activeTab = {}
local hovered = nil
local errorText = nil
local requestedAt = 0
local updatedAt = nil
local generation = 0
local render

-- Umami buckets by UTC with timezone=UTC, so bucket keys convert without the local offset (days-from-civil).
local function utcEpoch(year, month, day, hour)
  year -= if month <= 2 then 1 else 0
  local era = year // 400
  local yoe = year - era * 400
  local doy = (153 * (month + (if month > 2 then -3 else 9)) + 2) // 5 + day - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return ((era * 146097 + doe - 719468) * 24 + hour) * 3600
end

local function bucketSeries(points, range)
  local values = table.create(range.count, 0)
  for _, point in points or {} do
    local y, m, d, h = tostring(point.x):match("^(%d+)-(%d+)-(%d+)[T ]?(%d*)")
    if y then
      local index = (utcEpoch(tonumber(y), tonumber(m), tonumber(d), tonumber(h) or 0) - range.first) // range.unit + 1
      if values[index] then
        values[index] += umami.count(point.y)
      end
    end
  end
  return values
end

local function maxOf(values)
  local max = 1
  for _, v in values do
    max = math.max(max, v)
  end
  return max
end

local function normalize(values)
  if values == nil or #values < 2 then
    return { 0, 0 }
  end
  local max = maxOf(values)
  local out = table.create(#values)
  for i, v in values do
    out[i] = v / max
  end
  return out
end

local function thousands(n)
  return (tostring(math.round(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function compact(n)
  if n >= 1e6 then
    return string.format("%.1fm", n / 1e6)
  elseif n >= 1e4 then
    return string.format("%.1fk", n / 1e3)
  end
  return thousands(n)
end

local function duration(seconds)
  local s = math.round(seconds)
  if s < 60 then
    return `{s}s`
  elseif s < 3600 then
    return `{s // 60}m {s % 60}s`
  end
  return `{s // 3600}h {s // 60 % 60}m`
end

local function change(value, prev)
  if prev == nil then
    return "", MUTED
  elseif prev == 0 then
    return if value > 0 then tr("panel.new") else "", MUTED
  end
  local pct = math.round((value - prev) / prev * 100)
  if pct == 0 then
    return "0%", MUTED
  end
  return `{if pct > 0 then "↑" else "↓"}{math.abs(pct)}%`, if pct > 0 then UP else "error"
end

-- Umami 2 reports { value, prev } per stat; Umami 3 puts the previous period under comparison.
local function metric(stats, key)
  local value = stats[key]
  local prev = if type(value) == "table" then value.prev else stats.comparison and stats.comparison[key]
  return umami.count(value), if prev ~= nil then umami.count(prev) else nil
end

local function ratio(a, b)
  if a == nil or b == nil then
    return nil
  end
  return if b > 0 then a / b else 0
end

local function muted(text, size)
  return ui.label({ text = text, fontSize = size or 12, color = MUTED, maxLines = 1 })
end

local function spacer()
  return ui.spacer({ flexGrow = 1 })
end

local function shownSections()
  local shown = {}
  for _, s in SECTIONS do
    if noctalia.getConfig(`show_{s.key}`) ~= false then
      activeTab[s.key] = activeTab[s.key] or s.tabs[1]
      table.insert(shown, s)
    end
  end
  return shown
end

local function refresh()
  generation += 1
  local current = generation
  requestedAt = os.time()
  errorText = nil
  if not umami.isConfigured() then
    errorText = tr("error.not_configured")
    render()
    return
  end
  local fail = function(key, subst)
    if current == generation then
      errorText = tr(key, subst)
      render()
    end
  end
  local endAt = math.floor(noctalia.nowMs())
  local startAt = endAt - period.seconds * 1000
  local range = {
    unit = period.unit,
    first = startAt // 1000 // period.unit * period.unit,
    count = endAt // 1000 // period.unit - startAt // 1000 // period.unit + 1,
  }
  local window = `startAt={startAt}&endAt={endAt}`

  umami.auth(function(auth)
    local function get(path, onBody, onFail)
      umami.get(auth, path, function(body)
        if current == generation then
          updatedAt = os.time()
          onBody(body)
          render()
        end
      end, onFail or fail)
    end
    local function entryFor(id)
      data[id] = data[id] or {}
      return data[id]
    end

    get("/websites?pageSize=100&includeTeams=true", function(body)
      websites = body.data or body
      for _, site in websites do
        local entry = entryFor(site.id)
        local base = umami.websitePath(site.id)
        get(`{base}/stats?{window}`, function(stats)
          entry.stats = stats
        end)
        get(`{base}/active`, function(active)
          entry.active = umami.count(active.visitors or active.x)
        end)
        get(`{base}/pageviews?{window}&unit={if range.unit == 3600 then "hour" else "day"}&timezone=UTC`, function(series)
          entry.range = range
          entry.visitors = bucketSeries(series.sessions, range)
          entry.views = bucketSeries(series.pageviews, range)
        end)
      end
    end)

    if selected then
      local entry = entryFor(selected.id)
      entry.metrics = entry.metrics or {}
      local base = `{umami.websitePath(selected.id)}/metrics?{window}&limit=10&type=`
      for _, s in shownSections() do
        local tab = activeTab[s.key]
        local function store(rows)
          entry.metrics[tab] = rows
        end
        if tab == "path" then
          -- Umami 3 renamed the url metric to path.
          get(base .. "path", store, function(key, subst)
            if subst and subst.status == 400 then
              get(base .. "url", store)
            else
              fail(key, subst)
            end
          end)
        else
          get(base .. tab, store)
        end
      end
    end
  end, fail)
end

local function header()
  local tabs = {}
  for _, p in PERIODS do
    table.insert(tabs, ui.button({
      key = p.key,
      text = tr(`panel.period.{p.key}`),
      controlSize = "sm",
      variant = if p == period then "default" else "ghost",
      selected = p == period,
      onClick = function()
        if p ~= period then
          period = p
          data = {}
          refresh()
        end
      end,
    }))
  end
  return ui.row({ align = "center", gap = 4 }, {
    ui.row({ gap = 2, padding = 3, radius = 10, fill = "surface_container" }, tabs),
    spacer(),
    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = tr("panel.refresh"), onClick = refresh }),
    ui.button({
      glyph = "adjustments-horizontal",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.settings"),
      onClick = function()
        noctalia.openSettings()
      end,
    }),
  })
end

local function footer()
  local updated = ""
  if updatedAt then
    local ago = os.time() - updatedAt
    updated = tr("panel.updated", { time = if ago < 60 then `{ago}s` else `{ago // 60}m` })
  end
  return ui.row({ align = "center" }, {
    muted(tr(`panel.compared.{period.key}`), 11),
    spacer(),
    muted(updated, 11),
  })
end

local function siteRow(site)
  local entry = data[site.id] or {}
  local visitors, prev = 0, nil
  if entry.stats then
    visitors, prev = metric(entry.stats, "visitors")
  end
  local delta, deltaColor = change(visitors, prev)
  local name = { ui.label({ text = site.name or site.domain or "", fontWeight = "bold", maxLines = 1 }) }
  if (entry.active or 0) > 0 then
    table.insert(name, ui.label({ text = `● {entry.active}`, fontSize = 11, color = UP }))
  end
  return ui.row({
    key = site.id,
    align = "center",
    gap = 10,
    paddingH = 8,
    paddingV = 6,
    radius = 8,
    fill = if hovered == site.id then "on_surface/0.08" else "on_surface/0",
    onHover = function(state)
      if state == "true" then
        hovered = site.id
      elseif hovered == site.id then
        hovered = nil
      end
      render()
    end,
    onClick = function()
      selected = site
      render()
      refresh()
    end,
  }, {
    ui.column({ flexGrow = 1 }, {
      ui.row({ gap = 6, align = "center" }, name),
      muted(site.domain or "", 11),
    }),
    ui.graph({ values = normalize(entry.visitors), width = 72, height = 22, color = "primary", lineWidth = 1.5, fillOpacity = 0 }),
    ui.column({ width = 64, align = "end" }, {
      ui.label({ text = if entry.stats then thousands(visitors) else "–", fontWeight = "bold" }),
      ui.label({ text = delta, fontSize = 11, color = deltaColor }),
    }),
  })
end

local function listView()
  local visitors, prevVisitors, hasPrev, views, online, series = 0, 0, false, 0, 0, nil
  local rows = {}
  for _, site in websites do
    local entry = data[site.id] or {}
    if entry.stats then
      local v, p = metric(entry.stats, "visitors")
      visitors += v
      prevVisitors += p or 0
      hasPrev = hasPrev or p ~= nil
      views += metric(entry.stats, "pageviews")
    end
    online += entry.active or 0
    if entry.visitors then
      series = series or table.create(#entry.visitors, 0)
      for i, v in entry.visitors do
        if series[i] then
          series[i] += v
        end
      end
    end
    table.insert(rows, siteRow(site))
  end
  local delta, deltaColor = change(visitors, if hasPrev then prevVisitors else nil)

  return {
    ui.column({ gap = 2 }, {
      ui.row({ align = "center" }, {
        muted(tr("panel.visitors"), 13),
        spacer(),
        ui.label({ text = tr("panel.online", { count = online }), fontSize = 12, color = UP }),
      }),
      ui.row({ align = "end", gap = 8 }, {
        ui.label({ text = thousands(visitors), fontSize = 30, fontWeight = "bold" }),
        ui.label({ text = delta, fontSize = 12, color = deltaColor }),
        spacer(),
        ui.label({ text = tr("panel.views", { count = compact(views) }), fontSize = 13 }),
      }),
    }),
    ui.graph({ values = normalize(series), height = 56, color = "primary", lineWidth = 1.5, fillOpacity = 0.12 }),
    ui.separator({}),
    ui.row({ paddingH = 8 }, { muted(tr("panel.websites")), spacer(), muted(tr("panel.visitors")) }),
  }, ui.column({ gap = 2, paddingH = PAD }, rows)
end

local function stat(label, value, delta, color)
  return ui.column({ width = 108 }, {
    muted(label, 11),
    ui.label({ text = value, fontSize = 20, fontWeight = "bold" }),
    ui.label({ text = delta, fontSize = 11, color = color }),
  })
end

local function bucketLabel(range, index)
  local epoch = range.first + (index - 1) * range.unit
  return if range.unit == 3600 then os.date("%H:%M", epoch) else os.date("!%b %d", epoch)
end

local function barChart(entry)
  local visitors, views, range = entry.visitors or {}, entry.views or {}, entry.range
  local max = math.max(maxOf(visitors), maxOf(views))
  local bars = {}
  for i, v in views do
    local visitorCount = visitors[i] or 0
    table.insert(bars, ui.column({
      key = tostring(i),
      flexGrow = 1,
      justify = "end",
      tooltip = tr("panel.bar", { time = bucketLabel(range, i), visitors = thousands(visitorCount), views = thousands(v) }),
    }, {
      ui.column({ height = v / max * CHART_HEIGHT, fill = "primary/0.3", radius = 2, justify = "end" }, {
        ui.box({ height = visitorCount / max * CHART_HEIGHT, fill = "primary", radius = 2 }),
      }),
    }))
  end

  local axis = {}
  if range and #views > 0 then
    axis = {
      muted(bucketLabel(range, 1), 10),
      spacer(),
      muted(bucketLabel(range, (#views + 1) // 2), 10),
      spacer(),
      muted(bucketLabel(range, #views), 10),
    }
  end
  return ui.column({ gap = 6 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.box({ width = 8, height = 8, radius = 2, fill = "primary" }),
      muted(tr("panel.visitors"), 11),
      ui.box({ width = 8, height = 8, radius = 2, fill = "primary/0.3" }),
      muted(tr("panel.views_label"), 11),
      spacer(),
      muted(tr("panel.max", { count = thousands(max) }), 11),
    }),
    ui.row({ height = CHART_HEIGHT, gap = if #views > 40 then 1 else 2 }, bars),
    ui.row({}, axis),
  })
end

local function metricList(title, column, rows, fallbackName)
  local children = { ui.row({ paddingH = 8 }, { muted(title), spacer(), muted(column) }) }
  for i, row in rows or {} do
    local name = tostring(row.x or "")
    table.insert(children, ui.row({
      key = `{title}-{i}`,
      paddingH = 8,
      paddingV = 5,
      radius = 6,
      gap = 8,
      fill = if i == 1 then "primary/0.12" else "on_surface/0",
    }, {
      ui.label({ text = if name == "" then fallbackName else name, fontSize = 12, maxLines = 1, flexGrow = 1 }),
      ui.label({ text = thousands(umami.count(row.y)), fontSize = 12 }),
    }))
  end
  if rows ~= nil and #rows == 0 then
    table.insert(children, ui.row({ paddingH = 8, paddingV = 5 }, { muted(tr("panel.no_data")) }))
  end
  return ui.column({ gap = 2 }, children)
end

local function metricSection(s, metrics)
  local tab = activeTab[s.key]
  local buttons = {}
  for _, t in s.tabs do
    table.insert(buttons, ui.button({
      key = t,
      text = tr(`panel.tab.{t:lower()}`),
      controlSize = "sm",
      variant = if t == tab then "default" else "ghost",
      selected = t == tab,
      onClick = function()
        if t ~= tab then
          activeTab[s.key] = t
          render()
          refresh()
        end
      end,
    }))
  end
  return ui.column({ gap = 8 }, {
    ui.label({ text = tr(`panel.{s.key}`), fontWeight = "bold" }),
    ui.row({}, { ui.row({ gap = 2, padding = 3, radius = 10, fill = "surface_container" }, buttons) }),
    metricList(tr(`panel.tab.{tab:lower()}`), tr("panel.visitors"), metrics[tab], if s.empty == "/" then "/" else tr(s.empty)),
  })
end

local function detailView()
  local entry = data[selected.id] or {}
  local s = entry.stats or {}
  local visitors, prevVisitors = metric(s, "visitors")
  local visits, prevVisits = metric(s, "visits")
  local views, prevViews = metric(s, "pageviews")
  local bounces, prevBounces = metric(s, "bounces")
  local totaltime, prevTotaltime = metric(s, "totaltime")
  local perVisit, prevPerVisit = ratio(views, visits), ratio(prevViews, prevVisits)
  local bounceRate, prevBounceRate = ratio(bounces, visits), ratio(prevBounces, prevVisits)
  local visitTime, prevVisitTime = ratio(totaltime, visits), ratio(prevTotaltime, prevVisits)
  local function cell(label, value, current, prev)
    local delta, color = change(current, prev)
    return stat(label, if entry.stats then value else "–", delta, color)
  end

  local body = {
    muted(selected.domain or selected.name or "", 13),
    ui.row({ gap = 8 }, {
      cell(tr("panel.visitors"), thousands(visitors), visitors, prevVisitors),
      cell(tr("panel.visits"), thousands(visits), visits, prevVisits),
      cell(tr("panel.views_label"), thousands(views), views, prevViews),
    }),
    ui.row({ gap = 8 }, {
      cell(tr("panel.views_per_visit"), string.format("%.1f", perVisit), perVisit, prevPerVisit),
      cell(tr("panel.bounce_rate"), `{math.round(math.min(bounceRate, 1) * 100)}%`, bounceRate, prevBounceRate),
      cell(tr("panel.visit_duration"), duration(visitTime), visitTime, prevVisitTime),
    }),
    barChart(entry),
  }
  for _, section in shownSections() do
    table.insert(body, metricSection(section, entry.metrics or {}))
  end

  return {
    ui.row({ align = "center" }, {
      ui.button({
        glyph = "chevron-left",
        text = tr("panel.websites"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          selected = nil
          render()
        end,
      }),
      spacer(),
      ui.button({
        glyph = "external-link",
        text = tr("panel.open"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.runAsync({ "xdg-open", umami.dashboardUrl(umami.websitePath(selected.id)) })
        end,
      }),
    }),
  }, ui.column({ gap = 14, paddingH = PAD }, body)
end

render = function()
  local fixed, content
  if selected then
    fixed, content = detailView()
  else
    fixed, content = listView()
  end
  local top = { header() }
  if errorText then
    table.insert(top, ui.label({ text = errorText, fontSize = 12, color = "error", maxLines = 3 }))
  end
  for _, node in fixed do
    table.insert(top, node)
  end
  -- The scroll has no side padding so its scrollbar sits at the panel edge; its content pads itself.
  panel.render(ui.column({ flexGrow = 1, gap = 12, paddingV = PAD }, {
    ui.column({ gap = 12, paddingH = PAD }, top),
    ui.scroll({ flexGrow = 1 }, { content }),
    ui.column({ paddingH = PAD }, { footer() }),
  }))
end

function onOpen()
  panel.setWantsSecondTicks(true)
  render()
  refresh()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

function update()
  if os.time() - requestedAt >= math.max(15, tonumber(noctalia.getConfig("refresh_seconds")) or 60) then
    refresh()
  else
    render()
  end
end
