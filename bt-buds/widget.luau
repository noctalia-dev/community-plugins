-- bt-buds widget: glyph + "model codec mode" text on the bar.


local i18n_cache = { lang = nil, table = nil }
local function lang_table(lang)
    if i18n_cache.lang == lang and i18n_cache.table then return i18n_cache.table end
    local merged = {}
    local function merge(path)
        local ok, content = pcall(noctalia.readFile, path)
        if not ok or type(content) ~= "string" or content == "" then return end
        local ok2, data = pcall(noctalia.json.decode, content)
        if not ok2 or type(data) ~= "table" then return end
        local function deep(dst, src)
            for k, v in pairs(src) do
                if type(v) == "table" and type(dst[k]) == "table" then deep(dst[k], v)
                else dst[k] = v end
            end
        end
        deep(merged, data)
    end
    merge("translations/en.json")
    if lang ~= "en" then merge("translations/" .. lang .. ".json") end
    i18n_cache.lang = lang
    i18n_cache.table = merged
    return merged
end
local ui_lang = "auto"
local function tr(key)
    local lang = ui_lang
    if type(lang) ~= "string" or lang == "" or lang == "auto" then
        return noctalia.tr(key)
    end
    local node = lang_table(lang)
    for part in string.gmatch(key, "[^%.]+") do
        if type(node) ~= "table" then node = nil break end
        node = node[part]
    end
    if type(node) ~= "string" then
        return noctalia.tr(key)
    end
    return node
end

local snap = { connected = false, codec = "", mac = "", mode = "off", bat = "" }
local show_page = 0

local function barText()
    if not snap.connected then
        return tr("widget.off")
    end
    if show_page == 1 then
        if (tonumber(snap.bat_l) or -1) >= 0 then
            local cs = (tonumber(snap.bat_c) or -1) >= 0
                and (tr("widget.case_short") .. " " .. tostring(snap.bat_c) .. "%")
                or tr("widget.closed_short")
            return tr("widget.left_short") .. " " .. tostring(snap.bat_l) .. "% · "
                .. tr("widget.right_short") .. " " .. tostring(snap.bat_r) .. "% · " .. cs
        end
        return tr("widget.name")
    elseif show_page == 2 then
        if snap.mode == "anc" then
            return tr("panel.mode.anc")
        elseif snap.mode == "transparency" then
            return tr("panel.mode.transparency")
        end
        return tr("panel.mode.off")
    end
    return tr("widget.name")
end

local function modeGlyph()
    if snap.mode == "anc" then
        return "shield-check"
    elseif snap.mode == "transparency" then
        return "ear"
    end
    return "volume-off"
end

local function render()
    local kids = {}
    if snap.connected then
        kids[#kids + 1] = ui.glyph({ name = "bluetooth", color = "primary", size = 16 })
        kids[#kids + 1] = ui.label({ text = barText(), fontSize = 12 })
    else
        kids[#kids + 1] = ui.glyph({ name = "bluetooth-off", color = "error", size = 16 })
        kids[#kids + 1] = ui.label({ text = tr("widget.off"), fontSize = 12 })
    end
    barWidget.render(ui.row({ gap = 5, align = "center" }, kids))

    local tip
    if snap.connected then
        tip = tr("widget.tip_connected")
        if snap.codec ~= "" then
            tip = tip .. " | " .. snap.codec
        end
        tip = tip .. " | " .. snap.mode
    else
        tip = tr("widget.tip_disconnected")
    end
    if snap.bat ~= "" then
        tip = tip .. "\n" .. snap.bat
    end
    tip = tip .. "\n" .. tr("widget.tip_help")
    barWidget.setTooltip(tip)
end

function onClick()
    noctalia.togglePanel("jswift/bt-buds:panel")
end

function onRightClick()
    show_page = (show_page + 1) % 3
    render()
end

function onMiddleClick()
    noctalia.runAsync("noctalia msg plugin 'jswift/bt-buds:service' all cycle_mode")
end

function update()
    noctalia.setUpdateInterval(30000)
    noctalia.runAsync("noctalia msg plugin 'jswift/bt-buds:service' all refresh")
end

noctalia.state.watch("btbuds.status", function(s)
    if type(s) == "table" then
        ui_lang = type(s.lang) == "string" and s.lang or "auto"
        snap = {
            connected = s.connected == true,
            codec = type(s.codec) == "string" and s.codec or "",
            mac = type(s.mac) == "string" and s.mac or "",
            mode = type(s.mode) == "string" and s.mode or "off",
            bat = type(s.bat) == "string" and s.bat or "",
            bat_l = tonumber(s.bat_l) or -1,
            bat_r = tonumber(s.bat_r) or -1,
            bat_c = tonumber(s.bat_c) or -1,
        }
        render()
    end
end)

noctalia.setUpdateInterval(30000)
render()
