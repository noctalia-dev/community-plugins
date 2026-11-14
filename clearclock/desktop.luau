-- SPDX-FileCopyrightText: 2022 qewer33
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ClearClock's typography and composition, rendered with Noctalia's native UI.

local outfit = noctalia.loadFont("fonts/Outfit-Regular.ttf") or "sans-serif"
noctalia.loadFont("fonts/Outfit-Bold.ttf")
local smooch = noctalia.loadFont("fonts/Smooch-Regular.ttf") or "cursive"
local wallpaperRenderer = require("./wallpaper.luau")

local function family(configured, fallback)
    if configured == "" or configured == "ccdefault" then
        return fallback
    end
    return configured
end

local function label(key, text, size, color, font, bold, height)
    local node = ui.label({
        key = key,
        text = text,
        fontSize = size,
        color = color,
        fontFamily = font,
        fontWeight = bold and "bold" or "normal",
        baseline = "inkCentered",
        textAlign = "center",
    })
    -- v5.4.1 accepts label.height but does not apply it during label layout.
    -- A fixed-height flex wrapper gives both overlay layers identical bounds.
    if height then
        return ui.column({ key = key .. "-box", height = height,
            align = "center", justify = "center" }, { node })
    end
    return node
end

function update()
    local showSeconds = noctalia.getConfig("clockShowSeconds")
    desktopWidget.setWantsSecondTicks(showSeconds)

    -- Read the wall clock once: all three labels describe the same instant,
    -- including when an update straddles midnight or a daylight-saving change.
    local now = os.time()
    local timezone = noctalia.getConfig("timezone")
    local function format(pattern)
        return noctalia.formatTime(pattern, now, timezone)
    end

    local use24h = noctalia.getConfig("clockUse24hFormat")
    local separator = noctalia.getConfig("clockSeparator")
    -- Concatenate separators after formatting so literal '%' and braces work.
    local clock = format(use24h and "%H" or "%I") .. separator .. format("%M")
    if showSeconds then
        clock = clock .. separator .. format("%S")
    end
    if not use24h then
        clock = clock .. " " .. format("%p")
    end

    local showDay = noctalia.getConfig("showDayDisplay")
    -- Retain semantic roles in the UI tree: Noctalia resolves them against the
    -- current palette, including live changes while the clock is between ticks.
    local clockColor = noctalia.getConfig("clockFontColor")
    local dayColor = noctalia.getConfig("dayFontColor")
    local dateColor = noctalia.getConfig("dateFontColor")
    if noctalia.getConfig("adaptiveColors") then
        clockColor = "primary"
        dayColor = "on_primary"
        dateColor = "on_surface"
    end
    local clockSize = noctalia.getConfig("clockFontSize")
    local daySize = noctalia.getConfig("dayFontSize")
    local height = math.ceil(math.max(clockSize, showDay and daySize or 0) * 1.3)
    local layers = {
        label("clock", clock, clockSize, clockColor,
            family(noctalia.getConfig("clockFontFamily"), outfit),
            noctalia.getConfig("clockBoldText"), height),
    }
    if showDay then
        table.insert(layers, label("day", format("%A"), daySize,
            dayColor,
            family(noctalia.getConfig("dayFontFamily"), smooch),
            noctalia.getConfig("dayBoldText"), height))
    end

    -- Equal-height labels with a negative gap occupy the same box. The weekday
    -- is painted last, preserving the original overlay without rasterization.
    local children = {
        ui.column({ key = "overlay", align = "center", gap = -height }, layers),
    }
    if noctalia.getConfig("showDateDisplay") then
        local text = string.upper(format(noctalia.getConfig("dateCustomDateFormat")))
        local size = noctalia.getConfig("dateFontSize")
        local color = dateColor
        local font = family(noctalia.getConfig("dateFontFamily"), outfit)
        local bold = noctalia.getConfig("dateBoldText")
        local spacing = noctalia.getConfig("dateLetterSpacing")
        if spacing == 0 then
            table.insert(children, label("date", text, size, color, font, bold))
        else
            local letters = {}
            -- Iterate UTF-8 codepoints rather than bytes for localized dates.
            for character in string.gmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do
                table.insert(letters, label("letter-" .. (#letters + 1),
                    character, size, color, font, bold, math.ceil(size * 1.3)))
            end
            table.insert(children, ui.row({ key = "date", gap = spacing, align = "center" }, letters))
        end
    end
    local tree = ui.column({
        key = "clearclock",
        align = "center",
        gap = noctalia.getConfig("dateGap"),
        padding = 8,
    }, children)
    if (noctalia.getConfig("adaptiveGradients") and noctalia.getConfig("adaptiveColors"))
        or noctalia.getConfig("frostedGlass") or noctalia.getConfig("frostedFont") then
        wallpaperRenderer.render({clock = clock, day = showDay and format("%A") or "",
            date = noctalia.getConfig("showDateDisplay") and
                string.upper(format(noctalia.getConfig("dateCustomDateFormat"))) or "",
            settings = {
                clockFontSize = clockSize, dayFontSize = daySize,
                dateFontSize = noctalia.getConfig("dateFontSize"),
                dateGap = noctalia.getConfig("dateGap"),
                dateLetterSpacing = noctalia.getConfig("dateLetterSpacing"),
                clockFontFamily = noctalia.getConfig("clockFontFamily"),
                dayFontFamily = noctalia.getConfig("dayFontFamily"),
                dateFontFamily = noctalia.getConfig("dateFontFamily"),
                clockBoldText = noctalia.getConfig("clockBoldText"),
                dayBoldText = noctalia.getConfig("dayBoldText"),
                dateBoldText = noctalia.getConfig("dateBoldText"),
            }, colors = {
                clock = noctalia.getColor(clockColor) or clockColor,
                day = noctalia.getColor(dayColor) or dayColor,
                date = noctalia.getColor(dateColor) or dateColor,
            }}, tree)
    else
        wallpaperRenderer.reset()
        desktopWidget.render(tree)
    end
end
