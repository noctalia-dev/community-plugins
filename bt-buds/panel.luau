-- bt-buds panel in osp54/oppo-pods style, driven by local data.

local SVC = "jswift/bt-buds:service"
local KEY = "btbuds.status"


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

local st = {}

local function dispatch_ipc(event, payload)
    local cmd = "noctalia msg plugin '" .. SVC .. "' all " .. event
    if payload then
        cmd = cmd .. " " .. payload
    end
    noctalia.runAsync(cmd)
end

local function levelFraction(level)
    local n = tonumber(level)
    if n == nil or n < 0 then
        return 0
    end
    return math.max(0, math.min(100, n)) / 100
end

local function iconSuffix()
    return noctalia.isDarkMode() and ".svg" or "-light.svg"
end

local function batteryColumn(iconName, label, level)
    local hasLevel = (tonumber(level) or -1) >= 0
    local text = hasLevel and (tostring(level) .. "%") or (label == tr("panel.case") and tr("panel.closed") or "--%")
    local low = hasLevel and (tonumber(level) or 100) <= 20
    return ui.column({ align = "center", justify = "center", gap = 3, flexGrow = 1 }, {
        ui.row({ align = "center", gap = 4 }, {
            ui.image({
                path = "icons/" .. iconName .. iconSuffix(),
                width = 16,
                height = 16,
                fit = "contain",
                opacity = hasLevel and 0.85 or 0.4,
            }),
            ui.label({ text = label, fontSize = 11, fontWeight = "medium", opacity = 0.7, maxLines = 1 }),
        }),
        ui.label({
            text = text,
            fontSize = 14,
            fontWeight = "bold",
            color = low and "error" or nil,
            textAlign = "center",
            maxLines = 1,
        }),
        ui.progress({
            progress = levelFraction(level),
            height = 4,
            radius = 2,
            fill = low and "error" or "primary",
            width = 64,
        }),
    })
end

local function modeName()
    if st.mode == "anc" then
        return "ANC"
    elseif st.mode == "transparency" then
        return "Transparency"
    end
    return "Off"
end

local function render()
    local connected = st.connected == true
    local body = {}

    if connected then
        table.insert(body, ui.row({ align = "center", justify = "center", padding = 0 }, {
            ui.image({ path = "icons/buds.png", width = 260, height = 200, fit = "contain" }),
        }))

        table.insert(body, ui.row({ align = "center", justify = "center", gap = 8, padding = 2 }, {
            batteryColumn("earbud-left", tr("panel.left"), st.bat_l),
            batteryColumn("case", tr("panel.case"), st.bat_c),
            batteryColumn("earbud-right", tr("panel.right"), st.bat_r),
        }))

        table.insert(body, ui.separator({ thickness = 1 }))

        local currentMode = st.mode or "off"
        table.insert(body, ui.column({ gap = 3 }, {
            ui.label({ text = tr("panel.noise_control"), fontSize = 11, fontWeight = "bold", opacity = 0.7 }),
            ui.column({ gap = 2 }, {
                ui.button({
                    key = "mode-anc",
                    text = tr("panel.mode.anc"),
                    glyph = "shield-check",
                    variant = (currentMode == "anc") and "secondary" or "ghost",
                    selected = (currentMode == "anc"),
                    contentAlign = "start",
                    onClick = function() dispatch_ipc("set_mode", "anc") end,
                }),
                ui.button({
                    key = "mode-transparency",
                    text = tr("panel.mode.transparency"),
                    glyph = "ear",
                    variant = (currentMode == "transparency") and "secondary" or "ghost",
                    selected = (currentMode == "transparency"),
                    contentAlign = "start",
                    onClick = function() dispatch_ipc("set_mode", "transparency") end,
                }),
                ui.button({
                    key = "mode-off",
                    text = tr("panel.mode.off"),
                    glyph = "volume-off",
                    variant = (currentMode == "off") and "secondary" or "ghost",
                    selected = (currentMode == "off"),
                    contentAlign = "start",
                    onClick = function() dispatch_ipc("set_mode", "off") end,
                }),
            }),
        }))

        table.insert(body, ui.separator({ thickness = 1 }))

        local codecOpts = { "sbc", "sbc_xq", "aac" }
        local codecIndex = 0
        for i, c in ipairs(codecOpts) do
            if st.codec == c then
                codecIndex = i - 1
                break
            end
        end
        local eqOpts = { "normal", "more_bass", "boost_vocals", "more_highs" }
        local eqLabels = {}
        for i, k in ipairs(eqOpts) do eqLabels[i] = tr("panel.eq." .. k) end
        local eqIndex = 0
        for i, k in ipairs(eqOpts) do
            if st.eq_preset == k then
                eqIndex = i - 1
                break
            end
        end
        table.insert(body, ui.row({ gap = 8 }, {
            ui.column({ gap = 3, flexGrow = 1 }, {
                ui.row({ align = "center", gap = 4 }, {
                    ui.image({
                        path = "icons/codec-" .. (st.codec ~= "" and st.codec or "sbc") .. iconSuffix(),
                        width = 16,
                        height = 16,
                        fit = "contain",
                    }),
                    ui.label({ text = tr("panel.codec"), fontSize = 11, fontWeight = "bold", opacity = 0.7 }),
                }),
                ui.select({
                    key = "codec_select",
                    options = codecOpts,
                    selectedIndex = codecIndex,
                    onChange = function(idx)
                        local n = math.floor(tonumber(idx) or 0) + 1
                        if codecOpts[n] then
                            dispatch_ipc("set_codec", codecOpts[n])
                        end
                    end,
                }),
            }),
            ui.column({ gap = 3, flexGrow = 1 }, {
                ui.row({ align = "center", gap = 4 }, {
                    ui.image({
                        path = "icons/eq-" .. (st.eq_preset or "normal") .. iconSuffix(),
                        width = 16,
                        height = 16,
                        fit = "contain",
                    }),
                    ui.label({ text = tr("panel.equalizer"), fontSize = 11, fontWeight = "bold", opacity = 0.7 }),
                }),
                ui.select({
                    key = "eq_select_" .. (st.eq_preset or "none"),
                    options = eqLabels,
                    selectedIndex = eqIndex,
                    onChange = function(idx)
                        local n = math.floor(tonumber(idx) or 0) + 1
                        if eqOpts[n] then
                            dispatch_ipc("set_eq", eqOpts[n])
                        end
                    end,
                }),
            }),
        }))
    else
        table.insert(body, ui.column({ align = "center", gap = 8, padding = 16 }, {
            ui.glyph({ name = "bluetooth-off", color = "error", size = 40 }),
            ui.label({ text = tr("panel.disconnected"), fontSize = 15, fontWeight = "bold", textAlign = "center" }),
        }))
    end

    local statusText = connected and (st.mac ~= "" and st.mac or "connected") or tr("panel.disconnected")

    local modeGlyph = "volume-off"
    local modeLabel = tr("panel.mode.off")
    if st.mode == "anc" then
        modeGlyph = "shield-check"
        modeLabel = tr("panel.mode.anc")
    elseif st.mode == "transparency" then
        modeGlyph = "ear"
        modeLabel = tr("panel.mode.transparency")
    end

    panel.render(ui.column({ flexGrow = 1, gap = 4, padding = 0 }, {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.glyph({ name = "bluetooth", color = "primary", size = 26 }),
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = "Redmi Buds 6 Lite", fontSize = 14, fontWeight = "bold", maxLines = 1 }),
                ui.label({ text = statusText, fontSize = 11, color = connected and "secondary" or nil, maxLines = 1 }),
                ui.row({ align = "center", gap = 4 }, {
                    ui.glyph({ name = modeGlyph, size = 14 }),
                    ui.label({ text = modeLabel, fontSize = 11, maxLines = 1 }),
                }),
            }),
            ui.button({
                text = connected and tr("panel.disconnect") or tr("panel.connect"),
                variant = "ghost",
                onClick = function() dispatch_ipc("toggle") end,
            }),
            ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
        }),
        ui.column({ flexGrow = 1, gap = 6 }, body),
        ui.row({ justify = "end" }, {
            ui.button({
                glyph = "world",
                variant = "ghost",
                tooltip = (st.lang == "ru" and "RU") or (st.lang == "en" and "EN" or "Auto"),
                onClick = function() dispatch_ipc("cycle_lang") end,
            }),
        }),
    }))
end

noctalia.state.watch(KEY, function(value)
    if type(value) == "table" then
        st = value
        ui_lang = type(value.lang) == "string" and value.lang or "auto"
        render()
    end
end)

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    st = noctalia.state.get(KEY) or {}
    dispatch_ipc("hold")
    render()
end

function onClose()
end

function onCloseClicked()
    panel.close()
end

function update()
end
