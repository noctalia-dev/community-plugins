--!nonstrict
-- Todoist bar widget: overdue + due-today count, upcoming tasks in the tooltip.
--
--   Left click:  open the Todoist app (Flatpak, then native), else the web app
--   Right click: refresh now
--   IPC:         noctalia msg plugin turja-roy/todoist:widget all refresh

local API = "https://api.todoist.com/api/v1/tasks"
local DAY = 86400

local tasks = nil -- last successful fetch, kept to render through network errors
local fetching = false
local lastError = nil -- shown in the tooltip until the next successful fetch

local function tr(key, args)
    return noctalia.tr(key, args)
end

-- Days since 1970-01-01 for a Gregorian date (Howard Hinnant's days_from_civil).
local function daysFromCivil(y, m, d)
    if m <= 2 then
        y -= 1
    end
    local era = (if y >= 0 then y else y - 399) // 400
    local yoe = y - era * 400
    local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

-- "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM[:SS[.fff]][Z]" read as a UTC wall clock.
local function wallToEpoch(s)
    local y, mo, d, rest = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)(.*)$")
    if not y then
        return nil
    end
    local h, mi, sec = rest:match("^T(%d%d):(%d%d):?(%d*)")
    return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * DAY
        + (tonumber(h) or 0) * 3600
        + (tonumber(mi) or 0) * 60
        + (tonumber(sec) or 0)
end

-- Todoist sends a date ("2026-10-10"), a floating local datetime ("2026-10-10T22:00:00"),
-- or a UTC datetime ending in "Z". Returns (epoch, allDay) or nil.
-- ponytail: today's UTC offset is used for every date, so floating times across a DST
-- change are off by an hour; switch to per-date offsets if that matters.
local function parseDue(due, offset)
    local s = type(due) == "table" and (due.datetime or due.date)
    if type(s) ~= "string" then
        return nil
    end
    local wall = wallToEpoch(s)
    if not wall then
        return nil
    end
    if s:sub(-1) == "Z" then
        return wall, false
    end
    return wall - offset, #s == 10
end

local function readToken()
    local token = noctalia.getenv("TODOIST_TOKEN")
    if token == nil or token == "" then
        token = noctalia.readFile(noctalia.getConfig("token_file") or "")
    end
    token = token and noctalia.string.trim(token) or ""
    return if token ~= "" then token else nil
end

-- Follows next_cursor until every active task is collected.
local function fetchAll(token, cursor, acc, done)
    local url = API .. "?limit=200"
    if cursor then
        url ..= "&cursor=" .. noctalia.string.urlEncode(cursor)
    end
    noctalia.http({ url = url, headers = { "Authorization: Bearer " .. token } }, function(res)
        if res.status ~= 200 then
            done(nil, tr("error.http", { status = res.status or 0 }))
            return
        end
        local body = noctalia.json.decode(res.body or "")
        if type(body) ~= "table" or type(body.results) ~= "table" then
            done(nil, tr("error.parse"))
            return
        end
        table.move(body.results, 1, #body.results, #acc + 1, acc)
        if type(body.next_cursor) == "string" and body.next_cursor ~= "" then
            fetchAll(token, body.next_cursor, acc, done)
        else
            done(acc)
        end
    end)
end

local function render()
    local err = lastError
    barWidget.setGlyph(noctalia.getConfig("glyph") or "checkbox")
    if tasks == nil then
        barWidget.setText("?")
        barWidget.setColor("outline")
        barWidget.setGlyphColor("outline")
        barWidget.setTooltip(err or "")
        return
    end

    local now = os.time()
    local localDay = function(e)
        return noctalia.formatTime("%Y-%m-%d", e)
    end
    local offset = wallToEpoch(noctalia.formatTime("%Y-%m-%dT%H:%M:%S", now)) - now
    local today, tomorrow = localDay(now), localDay(now + DAY)

    local items = {}
    for _, t in ipairs(tasks) do
        local e, allDay = parseDue(t.due, offset)
        if e then
            local day = localDay(e)
            local overdue = if allDay then day < today else e < now
            table.insert(items, { e = e, allDay = allDay, day = day, overdue = overdue, content = t.content or "" })
        end
    end
    table.sort(items, function(a, b)
        return a.e < b.e
    end)

    local function label(it)
        local time = if it.allDay then "" else noctalia.formatTime(noctalia.timeFormat(), it.e)
        if it.day == today then
            return if it.allDay then tr("due.today") else time
        elseif it.day == tomorrow then
            return tr("due.tomorrow") .. (if it.allDay then "" else " " .. time)
        end
        return noctalia.formatTime("%a %d %b", it.e) .. (if it.allDay then "" else " " .. time)
    end

    local late, upcoming, dueToday = {}, {}, 0
    for _, it in ipairs(items) do
        if it.overdue then
            table.insert(late, it)
        else
            table.insert(upcoming, it)
            if it.day == today then
                dueToday += 1
            end
        end
    end

    local rows = {}
    if err then
        table.insert(rows, { tr("tooltip.stale", { error = err }), "" })
    end
    if #late > 0 then
        table.insert(rows, { tr("tooltip.overdue", { count = #late }), "" })
        for _, it in ipairs(late) do
            table.insert(rows, { label(it), it.content })
        end
    end
    local maxUpcoming = noctalia.getConfig("max_upcoming") or 10
    if #upcoming > 0 and maxUpcoming > 0 then
        table.insert(rows, { tr("tooltip.upcoming"), "" })
        for i = 1, math.min(#upcoming, maxUpcoming) do
            table.insert(rows, { label(upcoming[i]), upcoming[i].content })
        end
    elseif #late == 0 then
        table.insert(rows, { tr("tooltip.none"), "" })
    end

    local color = if #late > 0
        then noctalia.getConfig("overdue_color")
        elseif dueToday > 0 then noctalia.getConfig("today_color")
        else noctalia.getConfig("clear_color")
    barWidget.setText(tostring(#late + dueToday))
    barWidget.setColor(color)
    barWidget.setGlyphColor(color)
    barWidget.setTooltip(rows)
end

local function refresh()
    if fetching then
        return
    end
    local token = readToken()
    if token == nil then
        tasks = nil
        lastError = tr("error.no_token")
        render()
        return
    end
    fetching = true
    fetchAll(token, nil, {}, function(result, err)
        fetching = false
        if result then
            tasks = result
        end
        lastError = err
        render()
    end)
end

local lastFetch = -math.huge

function update()
    noctalia.setUpdateInterval(60000)
    -- Ticks every minute so "overdue" flips on time; the network is hit per refresh_minutes.
    if os.time() - lastFetch >= (noctalia.getConfig("refresh_minutes") or 5) * 60 then
        lastFetch = os.time()
        refresh()
    else
        render()
    end
end

-- The Flatpak app, then a native install, then the browser.
local function openTodoist()
    if noctalia.flatpakAppInstalled("com.todoist.Todoist") then
        noctalia.runAsync("flatpak run com.todoist.Todoist")
        return
    end
    for _, cmd in ipairs({ "todoist", "todoist-electron" }) do
        if noctalia.commandExists(cmd) then
            noctalia.runAsync(cmd)
            return
        end
    end
    noctalia.runAsync("xdg-open https://app.todoist.com/app/today")
end

function onClick()
    openTodoist()
end

function onRightClick()
    lastFetch = os.time()
    refresh()
end

function onIpc(event)
    if event == "refresh" then
        onRightClick()
    end
end
