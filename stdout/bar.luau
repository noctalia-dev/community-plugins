--!nonstrict

local g_glyph = "terminal-2"
local g_glyph_color = nil
local g_text = nil
local g_text_fontWeight = nil
local g_text_color = nil
local g_tips = nil
local g_visible = true
local g_last_run_time = nil
local g_updating = false

-- barWidget.isVertical() always returns false in render function
-- So store it in a variable
local is_vertical = barWidget.isVertical()

local function render()
    if not g_visible then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    local container = is_vertical and ui.column or ui.row
    local children = {}
    if g_glyph ~= nil and noctalia.getConfig("show_glyph") then
        children[#children + 1] = ui.glyph({ name = g_glyph, color = g_glyph_color })
    end
    if g_text ~= nil and g_text ~= "" then
        children[#children + 1] = ui.label({ text = g_text, fontWeight = g_text_fontWeight, color = g_text_color })
    end

    if g_tips ~= nil then
        barWidget.setTooltip(g_tips)
    end

    barWidget.render(container({ gap = 4, align = "center" }, children))
end

local function validate_text(text)
    if text == nil then
        return ""
    end
    return string.match(tostring(text), "^[^\r\n]*")
end

local function validate_weight(text)
    local weight = validate_text(text)
    if weight == nil then
        return nil
    end
    local valid_waights = {
        "thin", "light", "normal", "medium", "semibold", "bold", "heavy"
    }
    for _, valid_weight in ipairs(valid_waights) do
        if weight == valid_weight then
            return weight
        end
    end
    return nil
end

local function validate_color(text)
    local color = validate_text(text)
    if color == nil or color == "" then
        return nil
    end
    return color
end

local function run_script()
    if g_updating then
        return
    end
    local cmd = noctalia.getConfig("cmd")
    if cmd == nil or cmd == "" then
        return
    end
    g_updating = true
    noctalia.runAsync(cmd, function(result)
        g_last_run_time = os.time()
        g_tips = {
            { noctalia.tr("tips.last_run_time") .. ":", os.date("%H:%M:%S", g_last_run_time) },
        }
        if result.timedOut then
            g_tips[#g_tips + 1] = { noctalia.tr("tips.error_message") .. ":", noctalia.tr("tips.timed_out") }
            noctalia.log("[tordex/stdout] Command timed out")
        else
            local use_raw_text = true
            if noctalia.getConfig("json") then
                local data = noctalia.json.decode(result.stdout)
                if data and type(data) == "table" then
                    use_raw_text = false
                    g_text = validate_text(data.text)
                    g_glyph = validate_text(data.glyph)
                    g_text_fontWeight = validate_weight(data.fontWeight)
                    g_text_color = validate_color(data.textColor)
                    g_glyph_color = validate_color(data.glyphColor)
                    g_visible = if data.visible ~= nil and type(data.visible) == "boolean" then data.visible else true
                    g_tips = {}
                    if data.tips ~= nil and type(data.tips) == "table" then
                        for _, tip in ipairs(data.tips) do
                            if type(tip) == "table" and #tip == 2 then
                                g_tips[#g_tips + 1] = { validate_text(tip[1]), validate_text(tip[2]) }
                            end
                        end
                        g_tips[#g_tips + 1] = { noctalia.tr("tips.last_run_time") .. ":", os.date("%H:%M:%S", g_last_run_time) }
                    end
                end
            end
            if use_raw_text then
                g_text_fontWeight = nil
                g_text_color = nil
                g_glyph_color = nil
                if result.exitCode == 0 then
                    g_glyph = noctalia.getConfig("ok_glyph")
                    g_text = string.match(result.stdout, "^[^\r\n]*")
                    g_visible = true
                else
                    g_glyph = noctalia.getConfig("err_glyph")
                    g_text = nil
                    g_tips[#g_tips + 1] = { noctalia.tr("tips.exit_code") .. ":", tostring(result.exitCode) }
                    g_tips[#g_tips + 1] = { noctalia.tr("tips.error_message") .. ":", result.stderr }
                    if noctalia.getConfig("hide_on_error") then
                        g_visible = false
                    else
                        g_visible = true
                    end
                end
            end
        end
        render()
        g_updating = false
    end, 10000)
end

function update()
    local now = os.time()
    local elapsed = g_last_run_time and now - g_last_run_time or nil
    local update_period = noctalia.getConfig("interval") * tonumber(noctalia.getConfig("interval_units"))
    if g_last_run_time == nil or elapsed >= update_period then
        run_script()
    end
end

function onRightClick()
    run_script()
end

function onIpc(event, payload)
    if event == "update" then
        run_script()
    end
end

render()
noctalia.setUpdateInterval(500)
run_script()
