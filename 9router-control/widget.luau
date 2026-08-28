-- 9Router Control bar widget — a pure subscriber of 9router.connection state.
-- Shows connection status as an accent-colored glyph with a breathing glow,
-- plus the number of combos when connected. Click opens the panel.

local STATE_KEY = "9router.connection"
local COMBOS_KEY = "9router.combos"

local GLYPH = {
    online = "route",
    offline = "route-off",
    auth_required = "lock",
}
local COLOR = {
    online = "primary",
    offline = "error",
    auth_required = "error",
}

local BREATH_PERIOD = 6.0
local BREATH_FLOOR = 0.45
local BREATH_CEIL = 1.0
local TICK_MS = 100

local snap = { status = "offline" }
local combo_count = 0
local phase = BREATH_PERIOD / 2

-- Translation with an optional per-plugin language override (mirrors panel.luau).
local i18n_cache = { lang = nil, table = nil }

local function load_lang_table(lang)
    if i18n_cache.lang == lang and i18n_cache.table then
        return i18n_cache.table
    end
    local merged = {}
    local function merge_file(path)
        local ok, content = pcall(noctalia.readFile, path)
        if not ok or type(content) ~= "string" or content == "" then return end
        local ok2, data = pcall(noctalia.json.decode, content)
        if not ok2 or type(data) ~= "table" then return end
        local function deep(dst, src)
            for k, v in pairs(src) do
                if type(v) == "table" and type(dst[k]) == "table" then
                    deep(dst[k], v)
                else
                    dst[k] = v
                end
            end
        end
        deep(merged, data)
    end
    merge_file("translations/en.json")
    if lang ~= "en" then
        merge_file("translations/" .. lang .. ".json")
    end
    i18n_cache.lang = lang
    i18n_cache.table = merged
    return merged
end

local function tr(key, args)
    local lang = noctalia.getConfig and noctalia.getConfig("language")
    if type(lang) ~= "string" or lang == "" or lang == "auto" then
        return noctalia.tr(key, args)
    end
    local node = load_lang_table(lang)
    for part in string.gmatch(key, "[^%.]+") do
        if type(node) ~= "table" then node = nil break end
        node = node[part]
    end
    if type(node) ~= "string" then
        return noctalia.tr(key, args)
    end
    if type(args) == "table" then
        node = string.gsub(node, "{(%w+)}", function(name)
            local v = args[name]
            if v == nil then return "{" .. name .. "}" end
            return tostring(v)
        end)
    end
    return node
end

-- Scale an RRGGBB hex toward black by factor b, returning "#RRGGBB"
local function dim(hex, b)
    if type(hex) ~= "string" or #hex ~= 6 then return "#808080" end
    local function ch(i)
        local x = math.floor((tonumber(hex:sub(i, i + 1), 16) or 0) * b + 0.5)
        if x < 0 then x = 0 elseif x > 255 then x = 255 end
        return x
    end
    return string.format("#%02X%02X%02X", ch(1), ch(3), ch(5))
end

local ACCENT_RGB = {
    primary = "B4FF00",
    secondary = "EAFF00",
    error = "FF4D1F",
}

local function level_for(period)
    local t = phase % period
    local s = 0.5 - 0.5 * math.cos((t / period) * 2 * math.pi)
    return BREATH_FLOOR + (BREATH_CEIL - BREATH_FLOOR) * s
end

local function paint()
    local g = GLYPH[snap.status] or GLYPH.offline
    local c = COLOR[snap.status] or COLOR.offline
    barWidget.setGlyph(g)
    barWidget.setGlyphColor(dim(ACCENT_RGB[c] or ACCENT_RGB.secondary, level_for(BREATH_PERIOD)))
end

local function render()
    paint()
    local tip = tr("state.tip." .. tostring(snap.status)) or tr("state.tip.offline")
    if snap.error and snap.error ~= "" then
        tip = tip .. "\n" .. snap.error
    end
    if snap.status == "online" then
        tip = tip .. "\n" .. tr("state.combos", { count = combo_count })
    end
    barWidget.setTooltip(tip)
end

local function apply(s)
    if type(s) ~= "table" then return end
    local status = type(s.status) == "string" and s.status or "offline"
    local changed = (status ~= snap.status)
    snap = { status = status, error = s.error }
    if changed then
        phase = BREATH_PERIOD / 2
    end
    render()
end

local function apply_combos(list)
    if type(list) == "table" then
        combo_count = #list
    end
    render()
end

function onClick()
    noctalia.togglePanel("weinguyen/9router-control:panel")
end

function onRightClick()
    noctalia.runAsync("noctalia msg plugin 'weinguyen/9router-control:service' all refresh")
end

function update()
    noctalia.setUpdateInterval(TICK_MS)
    phase = phase + TICK_MS / 1000
    if phase > 1e6 then phase = 0 end
    paint()
end

noctalia.state.watch(STATE_KEY, apply)
noctalia.state.watch(COMBOS_KEY, apply_combos)
noctalia.setUpdateInterval(TICK_MS)

apply(noctalia.state.get(STATE_KEY))
apply_combos(noctalia.state.get(COMBOS_KEY))
render()
