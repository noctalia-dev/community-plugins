--!nonstrict
-- The Formula 1 panel: six tabs over the data the poller publishes.
--
--   Schedule  circuit outline, countdown, start lights, session times
--   Grid      starting order once qualifying is over
--   Live      running order and track flag during a session
--   Last      the most recent race result
--   Drivers   driver championship
--   Teams     constructor championship
--
-- Ported from Panel.qml, TrackMap.qml and StartLights.qml in
-- Snackwrap/omarchy-f1 (MIT). The circuit is drawn as an SVG that this file
-- writes into the plugin's data directory in the current theme colour and shows
-- with ui.image. Circuit outlines come from tracks.txt (bacinger/f1-circuits,
-- MIT, see tools/build-tracks.py).
--
-- Filesystem: writes track_<circuitId>_<colour>.svg files into
-- noctalia.pluginDataDir(); reads tracks.txt from the plugin directory.
-- Processes: xdg-open, only for Wikipedia links clicked in a table row.

local shared = require("./shared.luau")

local TEXT = "on_surface"
local MUTED = "on_surface_variant"
local ACCENT = "primary"
-- A depiction of a physical signal, not a palette choice, so it ignores the theme.
local LIGHT_ON = "#E10600"
local LIGHT_GO = "#1FBF5B"   -- green once the race is under way
local LIGHT_OFF = "#3A3F44"

local LIGHT_COLUMNS = 5
local LIGHT_STEP_MS = 620       -- one more column every 620 ms
local LIGHT_HOLD_MS = 1100      -- hold on the full gantry before the release
local INTRO_FADE_MS = 280

-- ── Data mirrored from the poller ────────────────────────────────────────────

local data = {
    race = noctalia.state.get("race"),
    drivers = noctalia.state.get("drivers"),
    constructors = noctalia.state.get("constructors"),
    grid = noctalia.state.get("grid"),
    results = noctalia.state.get("results"),
    live = noctalia.state.get("live"),
    status = noctalia.state.get("status"),
}

local isOpen = false
local view = "schedule"
local animMs = nil              -- ms since the intro started, nil when idle
local trackCache = {}           -- "<circuitId>:<colour>" -> svg path

local function forceTabs()
    return noctalia.getConfig("debug_force_tabs") == true
end

local function currentRace()
    local r = data.race
    if type(r) == "table" and type(r.sessions) == "table" then return r end
    return nil
end

local function rowsOf(set)
    if type(set) == "table" and type(set.rows) == "table" then return set.rows end
    return {}
end

local function loaded(set)
    return type(set) == "table" and set.loaded == true
end

-- ── Derived values ───────────────────────────────────────────────────────────

local function liveActive(now)
    local r = currentRace()
    return r ~= nil and shared.liveActive(data.live, r.sessions, now, forceTabs())
end

local function gridApplicable(now)
    local r = currentRace()
    return r ~= nil and shared.gridApplicable(r.sessions, now)
end

local function raceTs()
    local r = currentRace()
    return r ~= nil and shared.sessionTs(r.sessions, "race") or nil
end

local function raceUnderway(now)
    local ts = raceTs()
    return ts ~= nil and now >= ts
end

local function animationsOn()
    return noctalia.getConfig("animations") == true
end

local function tabList(now)
    local tabs = { { id = "schedule", label = noctalia.tr("tab.schedule") } }
    if gridApplicable(now) or forceTabs() then
        tabs[#tabs + 1] = { id = "grid", label = noctalia.tr("tab.grid") }
    end
    local isLive = liveActive(now)
    tabs[#tabs + 1] = { id = "live", label = isLive and noctalia.tr("tab.live_active") or noctalia.tr("tab.live") }
    tabs[#tabs + 1] = { id = "results", label = noctalia.tr("tab.results") }
    tabs[#tabs + 1] = { id = "drivers", label = noctalia.tr("tab.drivers") }
    tabs[#tabs + 1] = { id = "constructors", label = noctalia.tr("tab.constructors") }
    return tabs
end

local function viewValid(now, id)
    for _, t in ipairs(tabList(now)) do
        if t.id == id then return true end
    end
    return false
end

-- Which tab to open on: the live timing during a session, the grid between
-- qualifying and the race, otherwise the configured default.
local function pickView(now)
    if liveActive(now) then return "live" end
    if gridApplicable(now) then return "grid" end
    local wanted = tostring(noctalia.getConfig("default_tab") or "schedule")
    if wanted == "drivers" or wanted == "constructors" then return wanted end
    return "schedule"
end

-- ── Circuit map ──────────────────────────────────────────────────────────────

local tracksText = nil

local function trackPoints(circuitId)
    if not circuitId:match("^[%l%d_]+$") then return nil end
    if tracksText == nil then
        tracksText = noctalia.readFile("tracks.txt") or ""
    end
    -- One circuit per line: "<id> x,y x,y ...". Match from a line start.
    local line = ("\n" .. tracksText):match("\n" .. circuitId .. " ([^\n]+)")
    if line == nil then return nil end
    local pts = {}
    for x, y in line:gmatch("([%d%.]+),([%d%.]+)") do
        pts[#pts + 1] = { tonumber(x), tonumber(y) }
    end
    if #pts < 2 then return nil end
    return pts
end

-- Write (once per circuit and colour) an SVG of the outline and return its path.
-- The stroke colour is part of the file name, so a theme change simply selects
-- or writes another file. No stroke-linecap/linejoin attributes: the host's SVG
-- loader rejects them.
local function trackSvgPath(circuitId, color)
    local hex = tostring(color):gsub("[^%x]", "")
    local key = circuitId .. ":" .. hex
    if trackCache[key] ~= nil then return trackCache[key] end

    local dir = noctalia.pluginDataDir()
    if dir == nil then return nil end
    local file = dir .. "/track_" .. circuitId .. "_" .. hex .. ".svg"
    if noctalia.fileExists(file) then
        trackCache[key] = file
        return file
    end

    local pts = trackPoints(circuitId)
    if pts == nil then return nil end

    local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
    for _, p in ipairs(pts) do
        if p[1] < minx then minx = p[1] end
        if p[1] > maxx then maxx = p[1] end
        if p[2] < miny then miny = p[2] end
        if p[2] > maxy then maxy = p[2] end
    end
    local w, h = math.max(maxx - minx, 0.001), math.max(maxy - miny, 0.001)
    local span = math.max(w, h)
    local pad = span * 0.08
    local stroke = span * 0.022

    local coords = table.create and table.create(#pts) or {}
    for i, p in ipairs(pts) do
        coords[i] = string.format("%.3f,%.3f", p[1], p[2])
    end

    -- Start/finish tick: a short line across the track at the first segment.
    local a, b = pts[1], pts[2]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(dx * dx + dy * dy)
    if len == 0 then len = 1 end
    local nx, ny = -dy / len, dx / len
    local half = span * 0.035

    local svg = string.format(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%.3f %.3f %.3f %.3f" width="200" height="200">'
        .. '<polyline points="%s" fill="none" stroke="%s" stroke-width="%.4f"/>'
        .. '<line x1="%.3f" y1="%.3f" x2="%.3f" y2="%.3f" stroke="%s" stroke-width="%.4f"/></svg>',
        minx - pad, miny - pad, w + 2 * pad, h + 2 * pad,
        table.concat(coords, " "), color, stroke,
        a[1] - nx * half, a[2] - ny * half, a[1] + nx * half, a[2] + ny * half, color, stroke * 1.8)

    local ok = noctalia.writeFile(file, svg)
    if not ok then return nil end
    trackCache[key] = file
    return file
end

-- ── UI pieces ────────────────────────────────────────────────────────────────

local function label(text, props)
    local p = props or {}
    p.text = text
    p.color = p.color or TEXT
    return ui.label(p)
end

local function sectionHeader(text)
    return label(text, { fontSize = 11, fontWeight = "bold", color = MUTED })
end

local function hint(text)
    return label(text, { fontSize = 12, color = MUTED, maxLines = 3 })
end

-- A label's own `width` is not honoured inside a row, so columns that must line
-- up are wrapped in a container of fixed width.
local function cell(width, justify, node)
    return ui.row({ width = width, justify = justify, align = "center" }, { node })
end

local function chip(color)
    return ui.box({ width = 3, height = 16, radius = 1, fill = color })
end

local function isFavorite(row)
    local fd = tostring(noctalia.getConfig("favorite_driver") or ""):upper():gsub("%s", "")
    local ft = tostring(noctalia.getConfig("favorite_team") or ""):lower():gsub("%s", "")
    return (fd ~= "" and row.code == fd) or (ft ~= "" and row.teamId == ft)
end

local function teamChip(row, explicitColor)
    if noctalia.getConfig("team_colors") ~= true then return nil end
    local color = explicitColor
    if color == nil or color == "" then
        color = shared.teamColor(row.teamId, "#7A7D85")
    end
    return chip(color)
end

local function posLabel(pos)
    local n = tonumber(pos)
    return cell(28, "end", label(tostring(pos), {
        fontSize = 13,
        color = (n ~= nil and n <= 3) and TEXT or MUTED,
    }))
end

-- A table row that opens its Wikipedia page when it has a link.
local function rowContainer(row, children)
    local props = { gap = 8, align = "center", paddingV = 3, paddingH = 4, radius = 4 }
    if row.url ~= nil and row.url ~= "" then
        local url = row.url
        props.onClick = function() shared.openLink(url) end
    end
    return ui.row(props, children)
end

-- [chip] pos  code  team  detail  [points]
local function resultRow(row, opts)
    local children = {}
    local c = teamChip(row)
    if c ~= nil then children[#children + 1] = c end
    children[#children + 1] = posLabel(row.pos)
    children[#children + 1] = cell(44, "start", label(row.code, {
        fontSize = 13, fontWeight = "bold",
        color = isFavorite(row) and ACCENT or TEXT,
    }))
    children[#children + 1] = ui.row({ flexGrow = 1, justify = "start", align = "center" }, {
        label(row.team, { fontSize = 13, color = MUTED, maxLines = 1 }),
    })
    children[#children + 1] = cell(opts.detailWidth, "end", label(row.detail or "", { fontSize = 13, maxLines = 1 }))
    if opts.points then
        children[#children + 1] = cell(36, "end", label(row.pts or "", { fontSize = 13, color = MUTED }))
    end
    return rowContainer(row, children)
end

-- [chip] pos  primary  secondary  gap  points
local function standingRow(row, primary, secondary)
    local children = {}
    local c = teamChip(row)
    if c ~= nil then children[#children + 1] = c end
    children[#children + 1] = posLabel(row.pos)
    local primaryLabel = label(primary, {
        fontSize = 13, fontWeight = "bold", color = isFavorite(row) and ACCENT or TEXT, maxLines = 1,
    })
    if secondary ~= "" then
        children[#children + 1] = cell(48, "start", primaryLabel)
        children[#children + 1] = ui.row({ flexGrow = 1, justify = "start", align = "center" }, {
            label(secondary, { fontSize = 13, color = MUTED, maxLines = 1 }),
        })
    else
        children[#children + 1] = ui.row({ flexGrow = 1, justify = "start", align = "center" }, { primaryLabel })
    end
    children[#children + 1] = cell(44, "end", label(row.gap > 0 and ("-" .. tostring(row.gap)) or "", {
        fontSize = 12, color = MUTED,
    }))
    children[#children + 1] = cell(48, "end", label(row.pts or "", { fontSize = 13, fontWeight = "bold" }))
    return rowContainer(row, children)
end

local function lightsGantry(now)
    -- How many columns are lit, and whether they have turned green. Red holds
    -- until the race starts; from then on the whole gantry is green.
    local lit, go = LIGHT_COLUMNS, raceUnderway(now)
    if animMs ~= nil then
        lit = math.min(LIGHT_COLUMNS, animMs // LIGHT_STEP_MS)
        local doneAt = LIGHT_COLUMNS * LIGHT_STEP_MS + LIGHT_HOLD_MS
        go = animMs >= doneAt and raceUnderway(now)
        if go then lit = LIGHT_COLUMNS end
    end

    local columns = {}
    for i = 1, LIGHT_COLUMNS do
        local on = lit >= i
        local function lamp()
            return ui.box({
                width = 12, height = 12, radius = 6,
                fill = on and (go and LIGHT_GO or LIGHT_ON) or LIGHT_OFF,
                opacity = on and 1 or 0.55,
            })
        end
        columns[#columns + 1] = ui.column({ gap = 3, align = "center" }, { lamp(), lamp() })
    end
    return ui.row({ gap = 7, align = "center" }, columns)
end

-- ── Tabs ─────────────────────────────────────────────────────────────────────

local function scheduleTab(now)
    local r = currentRace()
    if r == nil then
        return { hint(data.status and data.status.loading and noctalia.tr("state.loading") or noctalia.tr("state.no_race")) }
    end

    local target = raceTs()

    local left = { }
    left[#left + 1] = label(r.circuitName, { fontSize = 14, maxLines = 2 })
    left[#left + 1] = label((r.locality ~= "" and r.country ~= "") and (r.locality .. ", " .. r.country) or (r.locality .. r.country),
        { fontSize = 12, color = MUTED, maxLines = 1 })
    left[#left + 1] = ui.spacer({ height = 6 })
    left[#left + 1] = lightsGantry(now)
    left[#left + 1] = ui.spacer({ height = 2 })
    left[#left + 1] = label(target ~= nil and shared.fmtLong(target - now) or "", {
        fontSize = 22, fontWeight = "bold", color = ACCENT, maxLines = 1,
    })

    local top = { ui.column({ gap = 3, align = "start", flexGrow = 1 }, left) }

    local fade = 1
    if animMs ~= nil and animationsOn() then fade = math.min(1, animMs / INTRO_FADE_MS) end
    local svg = trackSvgPath(r.circuitId, noctalia.getColor(TEXT) or "#cccccc")
    if svg ~= nil then
        top[#top + 1] = ui.image({ path = svg, width = 170, height = 150, fit = "contain", opacity = 0.85 * fade })
    end

    local out = { ui.row({ gap = 8, align = "center" }, top) }

    out[#out + 1] = ui.spacer({ height = 6 })
    out[#out + 1] = sectionHeader(noctalia.tr("schedule.sessions"))
    local nextSession = shared.nextSession(r.sessions, now)
    for _, s in ipairs(r.sessions) do
        local isNext = nextSession ~= nil and s.ts == nextSession.ts
        local past = s.ts <= now
        out[#out + 1] = ui.row({ gap = 8, align = "center", paddingV = 2, paddingH = 4 }, {
            cell(150, "start", label(noctalia.tr("session." .. s.id), {
                fontSize = 13, fontWeight = isNext and "bold" or "normal",
                color = isNext and ACCENT or (past and MUTED or TEXT), maxLines = 1,
            })),
            ui.row({ flexGrow = 1, justify = "start", align = "center", gap = 8 }, {
                label(shared.fmtDateTime(s.ts, false), { fontSize = 13, color = isNext and TEXT or MUTED }),
                label((s.delay ~= nil and s.delay ~= 0)
                    and noctalia.tr("schedule.delay", { minutes = (s.delay > 0 and "+" or "") .. tostring(s.delay) })
                    or "", { fontSize = 11, color = "secondary" }),
            }),
        })
    end
    return out
end

local function gridTab()
    local rows = rowsOf(data.grid)
    local out = {}
    if #rows == 0 then
        out[#out + 1] = hint(loaded(data.grid) and noctalia.tr("state.no_grid") or noctalia.tr("state.loading"))
        return out
    end
    out[#out + 1] = sectionHeader(noctalia.tr("grid.header"))
    out[#out + 1] = hint(noctalia.tr("grid.provisional"))
    for _, row in ipairs(rows) do
        out[#out + 1] = resultRow(row, { detailWidth = 80 })
    end
    return out
end

-- "07:45" from seconds.
local function clockText(seconds)
    local s = math.max(0, math.floor(seconds))
    return string.format("%02d:%02d", s // 60, s % 60)
end

local function liveTab(now)
    local r = currentRace()
    local out = {}
    if not liveActive(now) then
        out[#out + 1] = sectionHeader(noctalia.tr("live.header"))
        local live = data.live
        local problem = type(live) == "table" and live.error or ""
        local sessionOn = r ~= nil and shared.nearSession(r.sessions, now)
        if sessionOn and problem ~= "" then
            out[#out + 1] = label(noctalia.tr("live.unavailable"), { fontSize = 13, maxLines = 2 })
        else
            out[#out + 1] = label(noctalia.tr("live.idle"), { fontSize = 13, maxLines = 2 })
            out[#out + 1] = hint(noctalia.tr("live.idle_hint"))
        end
        if problem == "auth" or problem == "login" or problem == "token" or problem == "rate" or problem == "nocurl" then
            out[#out + 1] = hint(noctalia.tr("live." .. problem))
        end
        local nextSession = r ~= nil and shared.nextSession(r.sessions, now) or nil
        if nextSession ~= nil then
            out[#out + 1] = label(noctalia.tr("live.next", {
                name = noctalia.tr("session." .. nextSession.id),
                time = shared.fmtDateTime(nextSession.ts, false),
            }), { fontSize = 12, fontWeight = "bold", color = ACCENT })
        end
        return out
    end

    local live = data.live
    local session = type(live.session) == "table" and live.session or nil
    local title = noctalia.tr("live.badge")
    if session ~= nil and session.name ~= "" then
        title = noctalia.tr("live.badge_part", { session = session.name .. (session.part > 0 and (" Q" .. session.part) or "") })
    end
    local head = { label(title, { fontSize = 12, fontWeight = "bold", color = ACCENT }) }
    local clock = type(live.clock) == "table" and live.clock or nil
    if clock ~= nil then
        local left = clock.remaining - (clock.running and (now - clock.at) or 0)
        head[#head + 1] = label(noctalia.tr("live.clock_left", { time = clockText(left) }), { fontSize = 12, color = TEXT })
    end
    local flag = shared.friendlyFlag(live.flag)
    if flag ~= "" then head[#head + 1] = label(flag, { fontSize = 12, color = MUTED }) end
    out[#out + 1] = ui.row({ gap = 10, align = "center" }, head)

    local fd = tostring(noctalia.getConfig("favorite_driver") or ""):upper():gsub("%s", "")
    for i, row in ipairs(live.rows) do
        if i > 24 then break end
        local dimmed = row.state == "out" or row.state == "prev"
        local children = {}
        if noctalia.getConfig("team_colors") == true and row.color ~= "" then
            children[#children + 1] = chip(row.color)
        end
        children[#children + 1] = posLabel(row.pos)
        children[#children + 1] = cell(46, "start", label(row.code, {
            fontSize = 13, fontWeight = "bold",
            color = (fd ~= "" and row.code == fd) and ACCENT or (row.state == "out" and MUTED or TEXT),
        }))
        local teamText = row.team
        if row.state == "out" and (row.outPart or 0) > 0 then
            teamText = noctalia.tr("live.out", { part = row.outPart })
        elseif row.inPit then
            teamText = row.team .. "  ·  PIT"
        end
        children[#children + 1] = ui.row({ flexGrow = 1, justify = "start", align = "center" }, {
            label(teamText, { fontSize = 13, color = MUTED, maxLines = 1 }),
        })
        if row.best ~= "" or row.gap ~= "" then
            children[#children + 1] = cell(84, "end", label(row.best or "", {
                fontSize = 13, color = dimmed and MUTED or TEXT, maxLines = 1,
            }))
            children[#children + 1] = cell(64, "end", label(row.gap or "", {
                fontSize = 12, color = row.state == "danger" and "error" or MUTED, maxLines = 1,
            }))
        end
        out[#out + 1] = ui.row({ gap = 8, align = "center", paddingV = 3, paddingH = 4 }, children)
    end
    return out
end

local function resultsTab()
    local rows = rowsOf(data.results)
    local out = {}
    if #rows == 0 then
        out[#out + 1] = hint(loaded(data.results) and noctalia.tr("state.no_results") or noctalia.tr("state.loading"))
        return out
    end
    local name = data.results.raceName or ""
    out[#out + 1] = sectionHeader(noctalia.tr("results.header", { race = name:upper() }))
    for i, row in ipairs(rows) do
        if i > 12 then break end
        out[#out + 1] = resultRow(row, { detailWidth = 92, points = true })
    end
    return out
end

local function driversTab()
    local rows = rowsOf(data.drivers)
    local out = {}
    if #rows == 0 then
        out[#out + 1] = hint(loaded(data.drivers) and noctalia.tr("state.no_standings") or noctalia.tr("state.loading"))
        return out
    end
    out[#out + 1] = sectionHeader(noctalia.tr("drivers.header"))
    for i, row in ipairs(rows) do
        if i > 12 then break end
        out[#out + 1] = standingRow(row, row.code, row.team)
    end
    return out
end

local function constructorsTab()
    local rows = rowsOf(data.constructors)
    local out = {}
    if #rows == 0 then
        out[#out + 1] = hint(loaded(data.constructors) and noctalia.tr("state.no_standings") or noctalia.tr("state.loading"))
        return out
    end
    out[#out + 1] = sectionHeader(noctalia.tr("constructors.header"))
    for _, row in ipairs(rows) do
        out[#out + 1] = standingRow(row, row.name, "")
    end
    return out
end

-- ── Render ───────────────────────────────────────────────────────────────────

local function setView(id)
    view = id
    if id == "schedule" and animationsOn() then
        animMs = 0
        panel.setNeedsFrameTick(true)
    end
    if isOpen then
        -- render() is defined below; the forward reference resolves at call time.
        render()
    end
end

function render()
    if not isOpen then return end
    local now = shared.nowSec()
    if not viewValid(now, view) then view = "schedule" end
    local r = currentRace()

    local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "flag", size = 16, color = ACCENT }),
            label("FORMULA 1", { fontSize = 11, fontWeight = "bold", color = MUTED }),
        }),
        label(r ~= nil and noctalia.tr("header.round", { round = r.round, season = r.season }) or "",
            { fontSize = 11, color = MUTED }),
    })

    local title
    if r ~= nil then
        title = r.name
    elseif type(data.status) == "table" and data.status.loading then
        title = noctalia.tr("state.loading")
    else
        title = noctalia.tr("state.no_race")
    end

    local tabButtons = {}
    for _, t in ipairs(tabList(now)) do
        local id = t.id
        tabButtons[#tabButtons + 1] = ui.button({
            text = t.label, controlSize = "sm", fontSize = 12,
            variant = id == view and "primary" or "ghost",
            onClick = function() setView(id) end,
        })
    end

    local content
    if view == "grid" then content = gridTab()
    elseif view == "live" then content = liveTab(now)
    elseif view == "results" then content = resultsTab()
    elseif view == "drivers" then content = driversTab()
    elseif view == "constructors" then content = constructorsTab()
    else content = scheduleTab(now) end

    local footer = nil
    if type(data.status) == "table" and data.status.error ~= nil and data.status.error ~= "" and r == nil
        and data.status.error ~= "no_race" then
        footer = hint(noctalia.tr("state.error", { reason = tostring(data.status.error) }))
    end

    local body = { header, ui.separator({}), label(title, { fontSize = 20, fontWeight = "bold", maxLines = 2 }),
        ui.row({ gap = 2, align = "center" }, tabButtons),
        ui.scroll({ flexGrow = 1, gap = 4, align = "stretch" }, content) }
    if footer ~= nil then body[#body + 1] = footer end

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, body))
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

for key in pairs(data) do
    noctalia.state.watch(key, function(value)
        data[key] = value
        render()
    end)
end

function onOpen(_context)
    isOpen = true
    local now = shared.nowSec()
    view = pickView(now)
    panel.setWantsSecondTicks(true)
    if view == "schedule" and animationsOn() then
        animMs = 0
        panel.setNeedsFrameTick(true)
    else
        animMs = nil
    end
    render()
end

function onClose()
    isOpen = false
    animMs = nil
    panel.setWantsSecondTicks(false)
    panel.setNeedsFrameTick(false)
end

-- Per-second tick: the countdown and the session emphasis move.
function update()
    render()
end

-- Frame tick while the intro plays: fade the circuit in and step the lights.
function onFrameTick(deltaMs)
    if animMs == nil then
        panel.setNeedsFrameTick(false)
        return
    end
    animMs += deltaMs
    local finished = animMs >= LIGHT_COLUMNS * LIGHT_STEP_MS + LIGHT_HOLD_MS + 400
    if finished or view ~= "schedule" then
        -- Leave animMs set when the sequence is over so the lights keep their
        -- final state (held on the full gantry, or dark once the race started).
        panel.setNeedsFrameTick(false)
        if view ~= "schedule" then animMs = nil end
    end
    render()
end

local function cycleView(step)
    local now = shared.nowSec()
    local tabs = tabList(now)
    local index = 1
    for i, t in ipairs(tabs) do
        if t.id == view then index = i end
    end
    local nextIndex = ((index - 1 + step) % #tabs) + 1
    setView(tabs[nextIndex].id)
end

function onKey(chord, pressed)
    if not pressed then return end
    local key = tostring(chord or ""):lower()
    if key == "escape" then
        panel.close()
    elseif key == "left" then
        cycleView(-1)
    elseif key == "right" then
        cycleView(1)
    elseif key == "r" then
        noctalia.state.set("command", { action = "refresh", at = noctalia.nowMs() })
    end
end

-- noctalia msg plugin gcap0n1/f1:panel all tab <schedule|grid|live|results|drivers|constructors>
function onIpc(event, payload)
    if event == "tab" and type(payload) == "string" then
        isOpen = true
        if viewValid(shared.nowSec(), payload) then setView(payload) end
    end
end
