--!nonstrict
-- Pomodoro Heatmap - panel: timer, insights (heatmap, trends, rhythms) and quick settings.

local tab = "timer" -- "timer" | "insights" | "settings"
local isOpen = false

local PHASE = {
    work = { name = "Focus", glyph = "brain", color = "primary", start = "Start focus" },
    short = { name = "Short break", glyph = "coffee", color = "tertiary", start = "Start break" },
    long = { name = "Long break", glyph = "armchair", color = "tertiary", start = "Start break" },
}
local PRESETS = {
    work = { 15, 25, 45, 60, 90 },
    short = { 3, 5, 10 },
    long = { 10, 15, 20, 30 },
}

-- Heat levels: none, 1..4 (4 = daily goal reached, or the busiest day if no goal)
local HEAT = { [0] = "on_surface/0.07", "primary/0.28", "primary/0.48", "primary/0.72", "primary" }
local CELL, GAP = 11, 2
local DAY_LABELS = { "Mon", "", "Wed", "", "Fri", "", "" }
local WEEKDAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }

local SOUND_IDS = { "soft-chime", "gentle-bell", "wood", "system-bell", "system-message", "system-complete", "custom", "none" }
local SOUND_LABELS = { "Soft chime", "Gentle bell", "Wood", "System bell", "System message", "System complete",
    "Custom file", "None" }

local nonce = 0
local function send(cmd, arg)
    nonce += 1
    noctalia.state.set("pomo.cmd", { cmd = cmd, arg = arg, n = nonce .. ":" .. noctalia.nowMs() })
end

-- Optimistic local values: the panel shows a change immediately and keeps
-- showing it until the engine echoes the same value back, so rapid clicks
-- accumulate instead of snapping back to a stale value.
local localPrefs = {}     -- pref key -> value
local localLength = nil   -- { phase = ..., minutes = ... } for the idle timer
local editingClock = false
local clockDraft = nil
local drafts = {}         -- pref key -> text being typed

local FIELD = {
    ["work-minutes"] = "work", ["short-break-minutes"] = "short", ["long-break-minutes"] = "long",
    ["rounds"] = "rounds", ["daily-goal-minutes"] = "goal", ["sound-volume"] = "volume",
    ["breaks-enabled"] = "breaks", ["auto-start-breaks"] = "autoBreaks", ["auto-start-work"] = "autoWork",
    ["notify"] = "notify", ["focus-end-sound"] = "focusSound", ["break-end-sound"] = "breakSound",
}

local function prefValue(c, key)
    if localPrefs[key] ~= nil then return localPrefs[key] end
    return c[FIELD[key]]
end

local function setPref(key, value)
    localPrefs[key] = value
    send("pref", { key = key, value = value })
    render()
end

-- Next/previous multiple of step, so 23 goes to 25 / 20 rather than 28 / 18.
local function stepUp(v, step) return (math.floor(v / step) + 1) * step end
local function stepDown(v, step) return (math.ceil(v / step) - 1) * step end

-- ------------------------------------------------------------------ helpers

local function clock(sec)
    sec = math.max(0, sec or 0)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local function duration(min)
    min = math.floor(min or 0)
    if min < 60 then return string.format("%dm", min) end
    local h, m = math.floor(min / 60), min % 60
    if m == 0 then return string.format("%dh", h) end
    return string.format("%dh %02dm", h, m)
end

local function plural(n, word)
    return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function muted(text, size)
    return ui.label({ text = text, fontSize = size or 11, color = "on_surface_variant" })
end

local function card(props, children)
    props.fill = props.fill or "surface_container"
    props.radius = props.radius or 14
    props.padding = props.padding or 14
    props.gap = props.gap or 10
    return ui.column(props, children)
end

local function sectionTitle(glyph, title, sub)
    local row = {
        ui.glyph({ name = glyph, size = 15, color = "primary" }),
        ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    }
    if sub then table.insert(row, muted(sub)) end
    return ui.row({ gap = 8, align = "center" }, row)
end

-- ------------------------------------------------------------------ header

local function tabButton(id, text, glyph)
    return ui.button({
        text = text,
        glyph = glyph,
        variant = tab == id and "secondary" or "ghost",
        height = 30,
        onClick = function()
            if tab ~= id then
                commitAllDrafts()
                editingClock, clockDraft = false, nil
                tab = id
                if id == "insights" then send("refresh-stats") end
                render()
            end
        end,
    })
end

local function header(t)
    local p = PHASE[t and t.phase or "work"] or PHASE.work
    return ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = p.glyph, size = 18, color = p.color }),
        ui.label({ text = "Pomodoro", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
        tabButton("timer", "Timer", "hourglass"),
        tabButton("insights", "Insights", "chart-bar"),
        tabButton("settings", nil, "settings"),
    })
end

-- ------------------------------------------------------------------ timer tab

local function roundDots(t)
    local dots = {}
    for i = 1, t.rounds do
        local fill = "on_surface/0.14"
        if i < t.round or (i == t.round and t.phase ~= "work") then
            fill = "primary"
        elseif i == t.round then
            fill = t.status == "running" and "primary/0.55" or "primary/0.35"
        end
        table.insert(dots, ui.box({ width = i == t.round and 18 or 8, height = 8, radius = 4, fill = fill }))
    end
    return ui.row({ gap = 6, align = "center", justify = "center" }, dots)
end

local function idleMinutes(t)
    if localLength and localLength.phase == t.phase then return localLength.minutes end
    return math.floor(t.total / 60)
end

local function setLength(t, minutes)
    minutes = math.clamp(math.floor(minutes), 1, 600)
    localLength = { phase = t.phase, minutes = minutes }
    send("length", minutes)
    render()
end

local function commitClockDraft(t)
    local n = tonumber(clockDraft or "")
    editingClock, clockDraft = false, nil
    if n and n >= 1 then setLength(t, n) else render() end
end

-- Idle: the length can be changed before starting (±, presets, typing, save as default).
local function lengthPicker(t)
    local minutes = idleMinutes(t)
    local chips = {}
    for _, m in ipairs(PRESETS[t.phase] or PRESETS.work) do
        table.insert(chips, ui.button({
            text = tostring(m), variant = m == minutes and "secondary" or "ghost",
            height = 26, flexGrow = 1, onClick = function() setLength(t, m) end,
        }))
    end
    local rows = { ui.row({ gap = 4 }, chips) }
    if minutes * 60 ~= t.defaultTotal then
        local key = t.phase == "work" and "work-minutes" or (t.phase == "short" and "short-break-minutes" or "long-break-minutes")
        table.insert(rows, ui.row({ gap = 6, align = "center", justify = "center" }, {
            muted(string.format("Default is %s", duration(t.defaultTotal / 60)), 11),
            ui.button({ text = "Make default", glyph = "pin", variant = "ghost", height = 24,
                onClick = function() setPref(key, minutes) end }),
        }))
    end
    return ui.column({ gap = 6 }, rows), minutes
end

local function clockEditor(t, minutes)
    return ui.row({ gap = 8, align = "center", justify = "center", height = 70 }, {
        ui.input({
            key = "clock-input", value = clockDraft or tostring(minutes), width = 96, controlSize = "lg",
            focus = true, placeholder = "min",
            onChange = function(text) clockDraft = tostring(text or "") end,
            onSubmit = function() commitClockDraft(t) end,
        }),
        muted("min", 14),
        ui.button({ glyph = "check", variant = "primary", width = 36, height = 36,
            onClick = function() commitClockDraft(t) end }),
        ui.button({ glyph = "x", variant = "ghost", width = 36, height = 36,
            onClick = function() editingClock, clockDraft = false, nil; render() end }),
    })
end

local function timerHero(t)
    local p = PHASE[t.phase] or PHASE.work
    local active = t.status ~= "idle"
    local progress = (t.total or 0) > 0 and (1 - t.remaining / t.total) or 0
    local stateText = t.status == "paused" and "Paused" or (t.status == "running" and "In progress" or "Ready")
    local accent = t.status == "paused" and "on_surface_variant" or p.color

    local clockLabel = ui.label({
        text = clock(t.remaining),
        fontSize = 58,
        fontWeight = "bold",
        fontFamily = "monospace",
        color = active and accent or "on_surface",
        textAlign = "center",
    })

    local children = {
        ui.row({ align = "center", gap = 8 }, {
            ui.box({ width = 8, height = 8, radius = 4, fill = accent }),
            ui.label({ text = p.name, fontSize = 13, fontWeight = "bold", color = accent, flexGrow = 1 }),
            muted(t.phase == "work" and string.format("Round %d / %d", t.round, t.rounds) or stateText, 12),
        }),
    }

    if active then
        table.insert(children, ui.column({ align = "center", gap = 2 }, {
            clockLabel,
            muted(t.phase == "work" and stateText or "Step away from the screen", 12),
        }))
        table.insert(children, ui.progress({ progress = progress, height = 6, radius = 3, fill = accent,
            track = "on_surface/0.1" }))
    else
        local picker, minutes = lengthPicker(t)
        if editingClock then
            table.insert(children, clockEditor(t, minutes))
        else
            table.insert(children, ui.row({ align = "center", gap = 8 }, {
                ui.button({ glyph = "minus", variant = "ghost", width = 40, height = 40, enabled = minutes > 1,
                    onClick = function()
                        local m = idleMinutes(t)
                        setLength(t, m > 5 and stepDown(m, 5) or m - 1)
                    end }),
                ui.column({ flexGrow = 1, align = "center", justify = "center", height = 70,
                    tooltip = "Click to type a length",
                    onClick = function() editingClock, clockDraft = true, nil; render() end }, {
                    ui.label({
                        text = clock(minutes * 60),
                        fontSize = minutes >= 60 and 48 or 58,
                        fontWeight = "bold",
                        fontFamily = "monospace",
                        color = "on_surface",
                        textAlign = "center",
                    }),
                }),
                ui.button({ glyph = "plus", variant = "ghost", width = 40, height = 40, enabled = minutes < 600,
                    onClick = function()
                        local m = idleMinutes(t)
                        setLength(t, m >= 5 and stepUp(m, 5) or m + 1)
                    end }),
            }))
        end
        table.insert(children, picker)
    end
    table.insert(children, roundDots(t))
    return card({ padding = 18, gap = 12, align = "stretch" }, children)
end

local function action(text, glyph, cmd, enabled)
    return ui.button({ text = text, glyph = glyph, variant = "ghost", height = 32, flexGrow = 1,
        enabled = enabled ~= false, onClick = function() send(cmd) end })
end

local function controls(t)
    local p = PHASE[t.phase] or PHASE.work
    local running = t.status == "running"
    local active = t.status ~= "idle"
    local isWork = t.phase == "work"

    if not active then
        local row1 = { ui.button({ text = p.start, glyph = "player-play", variant = "primary", height = 44,
            flexGrow = 1, onClick = function()
                if editingClock then
                    local n = tonumber(clockDraft or "")
                    if n and n >= 1 then localLength = { phase = t.phase, minutes = math.clamp(math.floor(n), 1, 600) } end
                    editingClock, clockDraft = false, nil
                end
                send("start", localLength and localLength.phase == t.phase and localLength.minutes or nil)
            end }) }
        if not isWork then
            table.insert(row1, ui.button({ text = "Skip break", glyph = "player-track-next", variant = "outline",
                height = 44, flexGrow = 1, onClick = function() send("skip") end }))
        end
        local rows = { ui.row({ gap = 8 }, row1) }
        if t.round > 1 or not isWork then
            table.insert(rows, ui.row({ gap = 4 }, {
                action("Skip to next", "player-skip-forward", "skip", isWork),
                action("Reset cycle", "player-stop", "stop"),
            }))
        end
        return ui.column({ gap = 6 }, rows)
    end

    local row1 = ui.row({ gap = 8, align = "center" }, {
        ui.button({ glyph = "minus", variant = "outline", width = 44, height = 44,
            onClick = function() send("minus") end }),
        ui.button({ text = running and "Pause" or "Resume", glyph = running and "player-pause" or "player-play",
            variant = "primary", height = 44, flexGrow = 1, onClick = function() send("toggle") end }),
        ui.button({ glyph = "plus", variant = "outline", width = 44, height = 44,
            onClick = function() send("plus") end }),
    })
    local row2
    if isWork then
        row2 = {
            action("Finish", "circle-check", "finish"),
            action("Skip", "player-skip-forward", "skip"),
            action("Restart", "refresh", "reset"),
            action("Stop", "player-stop", "stop"),
        }
    else
        row2 = {
            action("Skip break", "player-track-next", "skip"),
            action("Focus now", "brain", "focus"),
            action("Stop", "player-stop", "stop"),
        }
    end
    return ui.column({ gap = 6 }, { row1, ui.row({ gap = 2 }, row2) })
end

local function miniWeek(s)
    local bars = {}
    local peak = 1
    for i = 8, 14 do peak = math.max(peak, s.recent[i].min) end
    if (s.goal or 0) > 0 then peak = math.max(peak, s.goal) end
    for i = 8, 14 do
        local d = s.recent[i]
        local h = d.min > 0 and math.max(3, math.floor(40 * d.min / peak)) or 3
        table.insert(bars, ui.column({ flexGrow = 1, gap = 4, align = "center",
            tooltip = string.format("%s\n%s · %s", d.label, duration(d.min), plural(d.count, "session")) }, {
            ui.column({ height = 40, justify = "end", align = "stretch", width = 18 }, {
                ui.box({ height = h, radius = 3,
                    fill = i == 14 and "primary" or (d.min > 0 and "primary/0.45" or "on_surface/0.1") }),
            }),
            ui.label({ text = d.short, fontSize = 10, color = i == 14 and "primary" or "on_surface_variant" }),
        }))
    end
    return ui.row({ gap = 4 }, bars)
end

local function todayCard(s)
    local goal = s.goal or 0
    local children = {
        sectionTitle("target", "Today", goal > 0 and string.format("Goal %s", duration(goal)) or nil),
    }
    local big = ui.row({ align = "end", gap = 8 }, {
        ui.label({ text = duration(s.today.min), fontSize = 26, fontWeight = "bold", color = "on_surface" }),
        ui.column({ paddingV = 5 }, {
            muted(goal > 0 and string.format("%d%% of goal", math.floor(100 * s.today.min / goal)) or "focused", 12),
        }),
    })
    table.insert(children, big)
    if goal > 0 then
        table.insert(children, ui.progress({ progress = math.min(1, s.today.min / goal), height = 4, radius = 2,
            fill = s.today.min >= goal and "tertiary" or "primary", track = "on_surface/0.1" }))
    end
    table.insert(children, ui.row({ gap = 16 }, {
        ui.row({ gap = 4, align = "center" }, { ui.glyph({ name = "brain", size = 13, color = "on_surface_variant" }),
            muted(plural(s.today.count, "session"), 12) }),
        ui.row({ gap = 4, align = "center" }, { ui.glyph({ name = "flame", size = 13,
            color = s.streak > 0 and "tertiary" or "on_surface_variant" }), muted(plural(s.streak, "day") .. " streak", 12) }),
        ui.row({ gap = 4, align = "center" }, { ui.glyph({ name = "calendar-stats", size = 13, color = "on_surface_variant" }),
            muted(duration(s.week.min) .. " this week", 12) }),
    }))
    table.insert(children, miniWeek(s))
    return card({}, children)
end

local function timerTab(t, s)
    local children = { timerHero(t), controls(t) }
    if s then table.insert(children, todayCard(s)) end
    return ui.scroll({ key = "timer-scroll", flexGrow = 1, gap = 12 }, children)
end

-- ------------------------------------------------------------------ settings tab

local STEPPERS = {
    ["work-minutes"] = { min = 1, max = 180, step = 5 },
    ["short-break-minutes"] = { min = 1, max = 60, step = 1 },
    ["long-break-minutes"] = { min = 1, max = 120, step = 5 },
    ["rounds"] = { min = 1, max = 12, step = 1 },
    ["daily-goal-minutes"] = { min = 0, max = 960, step = 15 },
}

-- Apply a typed value (Enter, tab switch or panel close).
local function commitDraft(key)
    local text = drafts[key]
    drafts[key] = nil
    local spec = STEPPERS[key]
    local n = tonumber(text or "")
    if spec and n then setPref(key, math.clamp(math.floor(n), spec.min, spec.max)) end
end

function commitAllDrafts()
    for key in pairs(drafts) do commitDraft(key) end
end

local function stepper(c, label, hint, key, unit)
    local spec = STEPPERS[key]
    local value = prefValue(c, key)
    return ui.row({ gap = 6, align = "center" }, {
        ui.column({ flexGrow = 1, gap = 1 }, {
            ui.label({ text = label, fontSize = 13, color = "on_surface" }),
            hint and muted(hint, 10) or nil,
        }),
        ui.button({ glyph = "minus", variant = "ghost", width = 30, height = 30, enabled = value > spec.min,
            onClick = function()
                drafts[key] = nil
                local v = prefValue(c, key)
                setPref(key, math.max(spec.min, stepDown(v, spec.step)))
            end }),
        ui.input({
            key = "input-" .. key, value = drafts[key] or tostring(value), width = 56, controlSize = "sm",
            tooltip = string.format("Type a value (%d–%d) and press Enter", spec.min, spec.max),
            onChange = function(text) drafts[key] = tostring(text or "") end,
            onSubmit = function() commitDraft(key) end,
        }),
        ui.column({ width = 26 }, { muted(unit, 11) }),
        ui.button({ glyph = "plus", variant = "ghost", width = 30, height = 30, enabled = value < spec.max,
            onClick = function()
                drafts[key] = nil
                local v = prefValue(c, key)
                setPref(key, math.min(spec.max, stepUp(v, spec.step)))
            end }),
    })
end

local function toggleRow(c, label, hint, key, enabled)
    local checked = prefValue(c, key) == true
    return ui.row({ gap = 8, align = "center" }, {
        ui.column({ flexGrow = 1, gap = 1 }, {
            ui.label({ text = label, fontSize = 13, color = enabled == false and "on_surface_variant" or "on_surface" }),
            hint and muted(hint, 10) or nil,
        }),
        ui.toggle({ checked = checked, enabled = enabled ~= false,
            onChange = function() setPref(key, not (prefValue(c, key) == true)) end }),
    })
end

local function indexOf(list, v)
    for i, x in ipairs(list) do if x == v then return i - 1 end end
    return 0
end

local function soundRow(c, label, key)
    local current = prefValue(c, key)
    return ui.column({ gap = 6 }, {
        ui.label({ text = label, fontSize = 13, color = "on_surface" }),
        ui.row({ gap = 6, align = "center" }, {
            ui.column({ flexGrow = 1 }, {
                ui.select({ options = SOUND_LABELS, selectedIndex = indexOf(SOUND_IDS, current), controlSize = "md",
                    onChange = function(index)
                        local id = SOUND_IDS[(math.floor(tonumber(index) or 0)) + 1]
                        if id and id ~= prefValue(c, key) then
                            setPref(key, id)
                            send("preview", id)
                        end
                    end }),
            }),
            ui.button({ glyph = "player-play", variant = "outline", width = 36, height = 34,
                enabled = current ~= "none", onClick = function() send("preview", prefValue(c, key)) end }),
        }),
    })
end

local function settingsTab(c)
    if not c then
        return ui.column({ flexGrow = 1, align = "center", justify = "center" }, { muted("Loading…", 13) })
    end
    local volume = prefValue(c, "sound-volume")
    local breaks = prefValue(c, "breaks-enabled")
    return ui.scroll({ key = "settings-scroll", flexGrow = 1, gap = 12 }, {
        card({}, {
            sectionTitle("hourglass", "Durations", "type a value + Enter"),
            stepper(c, "Focus", nil, "work-minutes", "min"),
            stepper(c, "Short break", nil, "short-break-minutes", "min"),
            stepper(c, "Long break", nil, "long-break-minutes", "min"),
            stepper(c, "Rounds", "Focus sessions before the long break", "rounds", ""),
            stepper(c, "Daily goal", "Full colour on the heatmap", "daily-goal-minutes", "min"),
        }),
        card({}, {
            sectionTitle("adjustments-horizontal", "Flow"),
            toggleRow(c, "Breaks", "Off: go straight to the next focus session", "breaks-enabled"),
            toggleRow(c, "Auto-start breaks", nil, "auto-start-breaks", breaks),
            toggleRow(c, "Auto-start focus", "After a break ends", "auto-start-work"),
            toggleRow(c, "Notifications", nil, "notify"),
        }),
        card({}, {
            sectionTitle("volume", "Sound"),
            soundRow(c, "When focus ends", "focus-end-sound"),
            soundRow(c, "When a break ends", "break-end-sound"),
            ui.row({ gap = 10, align = "center" }, {
                ui.label({ text = "Volume", fontSize = 13, color = "on_surface" }),
                ui.slider({ key = "pomo-volume", min = 0, max = 100, step = 5, value = volume, flexGrow = 1,
                    onChange = function(v)
                        local n = math.floor(tonumber(v) or volume)
                        if n ~= prefValue(c, "sound-volume") then
                            -- No re-render mid-drag; the label catches up on the engine's echo.
                            localPrefs["sound-volume"] = n
                            send("pref", { key = "sound-volume", value = n })
                        end
                    end }),
                ui.column({ width = 40, align = "end" }, { muted(string.format("%d%%", volume), 12) }),
            }),
        }),
        ui.button({ text = "All settings", glyph = "settings", variant = "ghost", height = 32,
            onClick = function() noctalia.openSettings() end }),
    })
end

-- ------------------------------------------------------------------ insights tab

local function kpi(glyph, label, value, sub, subColor)
    return card({ flexGrow = 1, gap = 4, padding = 12 }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = glyph, size = 13, color = "on_surface_variant" }),
            muted(label),
        }),
        ui.label({ text = value, fontSize = 20, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = sub or " ", fontSize = 11, color = subColor or "on_surface_variant", maxLines = 1 }),
    })
end

local function kpis(s)
    local delta = s.week.min - s.week.prevMin
    local deltaText, deltaColor
    if s.week.prevMin == 0 and s.week.min == 0 then
        deltaText = "no focus yet"
    elseif s.week.prevMin == 0 then
        deltaText, deltaColor = "new this week", "primary"
    else
        local pct = math.floor(100 * delta / s.week.prevMin + 0.5)
        deltaText = string.format("%s%d%% vs prior 7d", pct >= 0 and "+" or "", pct)
        deltaColor = pct >= 0 and "primary" or "error"
    end
    local goalSub = s.goal > 0 and string.format("%d%% of %s goal", math.floor(100 * s.today.min / s.goal), duration(s.goal))
        or plural(s.today.count, "session")
    return ui.column({ gap = 8 }, {
        ui.row({ gap = 8 }, {
            kpi("target", "Today", duration(s.today.min), goalSub, s.goal > 0 and s.today.min >= s.goal and "tertiary" or nil),
            kpi("calendar-stats", "Last 7 days", duration(s.week.min), deltaText, deltaColor),
        }),
        ui.row({ gap = 8 }, {
            kpi("flame", "Streak", plural(s.streak, "day"), string.format("best %s", plural(s.bestStreak, "day"))),
            kpi("trophy", "All time", duration(s.total.min), string.format("%s · %s", plural(s.total.count, "session"),
                plural(s.total.days, "day"))),
        }),
    })
end

local function heatmap(s)
    local hm = s.heatmap
    -- Month labels, each spanning the columns until the next label.
    local monthRow = { ui.box({ width = 24 - GAP, height = 1, fill = "on_surface/0" }) }
    local w = 1
    while w <= hm.weeks do
        local span = 1
        while w + span <= hm.weeks and hm.months[w + span] == "" do span += 1 end
        local text = hm.months[w]
        if span < 2 then text = "" end -- not enough room for a label
        table.insert(monthRow, ui.column({ width = span * CELL + (span - 1) * GAP }, {
            ui.label({ text = text, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
        }))
        w += span
    end

    local rows = { ui.row({ gap = GAP }, monthRow) }
    for wd = 1, 7 do
        local cells = { ui.column({ width = 24 - GAP, justify = "center", height = CELL }, {
            ui.label({ text = DAY_LABELS[wd], fontSize = 9, color = "on_surface_variant" }),
        }) }
        for col = 1, hm.weeks do
            local c = hm.columns[col][wd]
            if c.level < 0 then
                table.insert(cells, ui.box({ width = CELL, height = CELL, fill = "on_surface/0" }))
            else
                local tip = c.min > 0
                    and string.format("%s\n%s · %s", c.label, duration(c.min), plural(c.count, "session"))
                    or string.format("%s\nNo focus logged", c.label)
                table.insert(cells, ui.column({
                    key = c.date, width = CELL, height = CELL, radius = 3, fill = HEAT[c.level],
                    border = c.today and "on_surface" or nil, borderWidth = c.today and 1 or nil,
                    tooltip = tip,
                }, {}))
            end
        end
        table.insert(rows, ui.row({ gap = GAP }, cells))
    end

    local legend = { muted("Less", 10) }
    for l = 0, 4 do table.insert(legend, ui.box({ width = 10, height = 10, radius = 2, fill = HEAT[l] })) end
    table.insert(legend, muted("More", 10))

    return card({}, {
        sectionTitle("calendar-stats", "Focus heatmap",
            string.format("%s · %s", plural(hm.activeDays, "active day"), duration(hm.rangeMin))),
        ui.column({ gap = GAP, align = "center" }, rows),
        ui.row({ gap = 4, align = "center" }, {
            muted(hm.useGoal and "Full color = daily goal met" or "Relative to your best day", 10),
            ui.spacer({ flexGrow = 1 }),
            table.unpack(legend),
        }),
    })
end

local function barChart(values, opts)
    local peak = 1
    for _, v in ipairs(values) do peak = math.max(peak, v.value) end
    local bars = {}
    for i, v in ipairs(values) do
        local h = v.value > 0 and math.max(3, math.floor(opts.height * v.value / peak)) or 2
        table.insert(bars, ui.column({ flexGrow = 1, height = opts.height, justify = "end", align = "stretch",
            tooltip = v.tip }, {
            ui.box({ height = h, radius = opts.radius or 3,
                fill = v.highlight and "primary" or (v.value > 0 and "primary/0.5" or "on_surface/0.08") }),
        }))
    end
    local labels = {}
    for _, v in ipairs(values) do
        table.insert(labels, ui.column({ flexGrow = 1, align = "center" }, {
            ui.label({ text = v.axis or "", fontSize = 9, color = v.highlight and "primary" or "on_surface_variant" }),
        }))
    end
    return ui.column({ gap = 4 }, { ui.row({ gap = opts.gap or 4 }, bars), ui.row({ gap = opts.gap or 4 }, labels) })
end

local function recentChart(s)
    local values = {}
    local sum = 0
    for i, d in ipairs(s.recent) do
        sum += d.min
        table.insert(values, {
            value = d.min, axis = d.short, highlight = i == #s.recent,
            tip = string.format("%s\n%s · %s", d.label, duration(d.min), plural(d.count, "session")),
        })
    end
    return card({}, {
        sectionTitle("chart-bar", "Last 14 days", string.format("avg %s / day", duration(sum / 14))),
        barChart(values, { height = 72, gap = 5 }),
    })
end

local function hoursChart(s)
    local values = {}
    local nowHour = tonumber(os.date("%H")) or 0
    for h = 0, 23 do
        table.insert(values, {
            value = s.hours[h + 1],
            axis = (h % 6 == 0) and string.format("%02d", h) or "",
            highlight = h == s.peakHour,
            tip = string.format("%02d:00 – %02d:00\n%s total", h, (h + 1) % 24, duration(s.hours[h + 1])),
        })
    end
    local sub = s.peakHour and string.format("peak %02d:00", s.peakHour) or nil
    return card({}, {
        sectionTitle("clock", "Time of day", sub),
        barChart(values, { height = 52, gap = 2, radius = 2 }),
    })
end

local function weekdayChart(s)
    local peak = 1
    for i = 1, 7 do peak = math.max(peak, s.weekdays[i]) end
    local rows = {}
    for i = 1, 7 do
        local v = s.weekdays[i]
        local ratio = v / peak
        table.insert(rows, ui.row({ gap = 8, align = "center" }, {
            ui.column({ width = 30 }, { ui.label({ text = WEEKDAYS[i], fontSize = 11, color = "on_surface_variant" }) }),
            ui.row({ flexGrow = 1, height = 8, radius = 4, fill = "on_surface/0.07" }, {
                ui.box({ flexGrow = math.max(ratio, 0.0001), height = 8, radius = 4,
                    fill = v == peak and v > 0 and "primary" or "primary/0.5" }),
                ui.box({ flexGrow = math.max(1 - ratio, 0.0001), height = 8, fill = "on_surface/0" }),
            }),
            ui.column({ width = 56, align = "end" }, { ui.label({ text = duration(v), fontSize = 11, color = "on_surface" }) }),
        }))
    end
    return card({}, { sectionTitle("chart-histogram", "By weekday", "all time"), ui.column({ gap = 6 }, rows) })
end

local function facts(s)
    local items = {}
    local function fact(glyph, text)
        table.insert(items, ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = glyph, size = 13, color = "primary" }),
            ui.label({ text = text, fontSize = 12, color = "on_surface", flexGrow = 1 }),
        }))
    end
    if s.bestDay then fact("trophy", string.format("Best day: %s on %s", duration(s.bestDay.min), s.bestDay.date)) end
    if s.total.days > 0 then fact("chart-dots", string.format("Average: %s per active day", duration(s.total.min / s.total.days))) end
    if s.completion then
        fact("target", string.format("Completion rate: %d%% (%s interrupted)", math.floor(100 * s.completion + 0.5),
            plural(s.total.partial, "session")))
    end
    if #items == 0 then
        fact("brain", "Finish your first focus session to start building insights.")
    end
    return card({ gap = 8 }, items)
end

local function insightsTab(s)
    if not s then
        return ui.column({ flexGrow = 1, align = "center", justify = "center" }, { muted("Loading…", 13) })
    end
    return ui.scroll({ key = "insights-scroll", flexGrow = 1, gap = 12 }, {
        kpis(s),
        heatmap(s),
        recentChart(s),
        hoursChart(s),
        weekdayChart(s),
        facts(s),
    })
end

-- ------------------------------------------------------------------ render

function render()
    local t = noctalia.state.get("pomo.timer")
    local s = noctalia.state.get("pomo.stats")
    local body
    if not t then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "brain", size = 28, color = "primary" }),
            muted("Starting the Pomodoro engine…", 13),
        })
    elseif tab == "insights" then
        body = insightsTab(s)
    elseif tab == "settings" then
        body = settingsTab(noctalia.state.get("pomo.config"))
    else
        body = timerTab(t, s)
    end
    panel.render(ui.column({ flexGrow = 1, gap = 14 }, { header(t), body }))
end

function onOpen(context)
    isOpen = true
    if context == "insights" or context == "timer" or context == "settings" then tab = context end
    render()
end

function onClose()
    commitAllDrafts()
    editingClock, clockDraft = false, nil
    isOpen = false
end

-- Drop optimistic values once the engine has caught up with them.
local function reconcileTimer(t)
    if localLength and (not t or t.status ~= "idle" or t.phase ~= localLength.phase
        or math.floor(t.total / 60) == localLength.minutes) then
        localLength = nil
    end
end

local function reconcileConfig(c)
    if not c then return end
    for key, v in pairs(localPrefs) do
        if c[FIELD[key]] == v then localPrefs[key] = nil end
    end
end

noctalia.state.watch("pomo.timer", function(t)
    reconcileTimer(t)
    -- Only the timer tab shows the ticking clock; skip per-second redraws elsewhere.
    -- While a length is being typed, don't redraw under the cursor.
    if isOpen and tab == "timer" and not editingClock then render() end
end)

noctalia.state.watch("pomo.stats", function()
    if isOpen and tab ~= "settings" then render() end
end)

noctalia.state.watch("pomo.config", function(c)
    reconcileConfig(c)
    if isOpen and tab == "settings" then render() end
end)

render()
