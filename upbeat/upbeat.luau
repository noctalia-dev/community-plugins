--!nonstrict
local BIEL_OFFSET_SECONDS: number = 3600 -- UTC +1
local SECONDS_PER_CENTIBEAT: number = 0.864
local lastValue: number = -1

-- definitions for converting local time to .beat time
-- seconds per day 86400
-- seconds per beat 86.4
-- seconds per centibeat 0.864

function update()
    barWidget.setGlyph("at")
    local secondsSinceMidnight: number = (os.time() + BIEL_OFFSET_SECONDS) % 86400 -- 86400 = seconds in one day
    local totalCentibeats: number = math.floor(secondsSinceMidnight / SECONDS_PER_CENTIBEAT)
    -- define display of subbeat toggle
    local useCentibeats: boolean = noctalia.getConfig("show_centibeats")
    -- define display of @beats toggle
    local showSuffix: boolean = noctalia.getConfig("beat_display")
    local timeFormatToggle: boolean = noctalia.getConfig("time_format_toggle")
    local checkValue: number = useCentibeats and totalCentibeats or math.floor(totalCentibeats / 100)
    -- layout updates when values tick
    if checkValue ~= lastValue then
        lastValue = checkValue
        -- display .beat suffix toggle
        local suffix: string = showSuffix and " .beats" or ""
        if useCentibeats then
            barWidget.setText(string.format("%03d.%02d", math.floor(totalCentibeats / 100), totalCentibeats % 100) .. suffix)
        else
            barWidget.setText(string.format("%03d", checkValue) .. suffix)
        end
    end
    -- define display of 24h time toggle
    local tooltipFormat: string = timeFormatToggle and "%T" or "%I:%M %p"
    -- on hover displays the user's "real" time
    barWidget.setTooltip(noctalia.formatTime(tooltipFormat))
    -- resource savings when subbeats not shown
    if useCentibeats then
        noctalia.setUpdateInterval(200) -- high tick when tracking subbeats
    else
        -- return remaining seconds until whole beat
        local secondsToNextBeat: number = 86.4 - (secondsSinceMidnight % 86.4)
        -- defines targeting of next whole beat change (+100ms padding)
        noctalia.setUpdateInterval(math.floor((secondsToNextBeat * 1000) + 100))
    end
end
