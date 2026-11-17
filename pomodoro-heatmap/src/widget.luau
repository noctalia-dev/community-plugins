--!nonstrict
-- Pomodoro Heatmap - bar capsule.
--   idle     glyph (+ today's finished sessions)
--   running  stage glyph, countdown, thin progress line
--   paused   same, dimmed
-- Click: panel · Right click: start/pause · Middle click: skip · Scroll: ±1 min

local PANEL_ID = "adam-gassem/pomodoro-heatmap:panel"
local isVertical = barWidget.isVertical()

local PHASE = {
    work = { glyph = "brain", color = "primary", name = "Focus" },
    short = { glyph = "coffee", color = "tertiary", name = "Short break" },
    long = { glyph = "armchair", color = "tertiary", name = "Long break" },
}

local nonce = 0
local function send(cmd, arg)
    nonce += 1
    noctalia.state.set("pomo.cmd", { cmd = cmd, arg = arg, n = nonce .. ":" .. noctalia.nowMs() })
end

local function clock(sec)
    sec = math.max(0, sec or 0)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local function render(t)
    if type(t) ~= "table" then
        barWidget.render(ui.glyph({ name = "brain", color = "on_surface" }))
        return
    end
    local p = PHASE[t.phase] or PHASE.work
    local active = t.status ~= "idle"
    local color = t.status == "running" and p.color or (active and "on_surface_variant" or "on_surface")
    local glyph = t.status == "paused" and "player-pause" or (active and p.glyph or "brain")
    local children = { ui.glyph({ name = glyph, color = color, size = 16 }) }

    if active then
        local timeText = clock(t.remaining)
        if isVertical then
            timeText = string.format("%02d\n%02d", math.floor(t.remaining / 60), t.remaining % 60)
        end
        local label = ui.label({
            text = timeText,
            color = color,
            fontWeight = "medium",
            fontFamily = "monospace",
            textAlign = "center",
        })
        if noctalia.getConfig("show-progress") ~= false and not isVertical and (t.total or 0) > 0 then
            local done = 1 - t.remaining / t.total
            table.insert(children, ui.column({ gap = 2, justify = "center" }, {
                label,
                ui.progress({ progress = done, width = 44, height = 2, radius = 1,
                    fill = color, track = "on_surface/0.12" }),
            }))
        else
            table.insert(children, label)
        end
    elseif noctalia.getConfig("show-idle-count") ~= false and (t.todayCount or 0) > 0 then
        table.insert(children, ui.label({ text = tostring(t.todayCount), color = "on_surface_variant",
            fontWeight = "medium" }))
    end

    local container = isVertical and ui.column or ui.row
    barWidget.render(container({ gap = 6, align = "center", justify = "center" }, children))

    -- Tooltip
    local lines = {}
    if active then
        table.insert(lines, string.format("%s · %s%s", p.name, clock(t.remaining),
            t.status == "paused" and " (paused)" or ""))
        if t.phase == "work" then
            table.insert(lines, string.format("Round %d of %d", t.round, t.rounds))
        end
    else
        table.insert(lines, string.format("Pomodoro · ready (%s)", clock(t.total)))
    end
    local today = string.format("Today: %d min · %d sessions", t.todayMin or 0, t.todayCount or 0)
    if (t.goal or 0) > 0 then
        today = today .. string.format(" · %d%% of goal", math.floor(100 * (t.todayMin or 0) / t.goal))
    end
    table.insert(lines, today)
    if (t.streak or 0) > 0 then
        table.insert(lines, string.format("Streak: %d day%s", t.streak, t.streak == 1 and "" or "s"))
    end
    table.insert(lines, "Click: panel · Right: start/pause · Middle: skip · Scroll: adjust time")
    barWidget.setTooltip(table.concat(lines, "\n"))
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    send("toggle")
end

function onMiddleClick()
    send("skip")
end

function onScroll(axis, steps, startsGesture)
    if axis ~= "vertical" or not startsGesture then return end
    local t = noctalia.state.get("pomo.timer")
    if not t then return end
    if t.status == "idle" then -- set the length before starting, in 5 min steps
        local minutes = math.floor(t.total / 60)
        local step = minutes > 5 and 5 or 1
        send("length", math.max(1, minutes + (steps > 0 and -step or step)))
    else
        send(steps > 0 and "minus" or "plus")
    end
end

noctalia.state.watch("pomo.timer", render)
render(noctalia.state.get("pomo.timer"))
