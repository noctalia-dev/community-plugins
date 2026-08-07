-- OpenCode Companion bar widget — a pure subscriber of opencode.connection state.
-- Shows connection status as an accent-colored glyph with a breathing glow,
-- an unread badge when responses arrive while the panel is closed, and a
-- waiting-permission bell when OpenCode needs user input.

local STATE_KEY = "opencode.connection"
local UNREAD_KEY = "opencode.unread_count"

local GLYPH = {
    online = "code-circle",
    offline = "code-off",
    starting = "loader",
    busy = "brain",
    waiting_permission = "shield-exclamation",
}

local COLOR = {
    online = "primary",
    offline = "error",
    starting = "secondary",
    busy = "primary",
    waiting_permission = "error",
}

local BREATH_PERIOD = 6.0
local BREATH_FLOOR = 0.45
local BREATH_CEIL = 1.0
local TICK_MS = 100

local snap = { status = "offline" }
local unread = 0
local phase = BREATH_PERIOD / 2
local online_pulse = 0  -- counts ticks while online (for periodic refresh)

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

-- Resolved accent RGB (hardcoded fallback; theme follows via named roles where possible)
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

    local status_tip = tr("state.tip." .. tostring(snap.status)) or tr("state.tip.offline")
    local tip = status_tip
    if snap.error and snap.error ~= "" then
        tip = tip .. "\n" .. snap.error
    end
    if unread > 0 then
        tip = tip .. "\n" .. tr("state.unread", { count = unread })
    end
    barWidget.setTooltip(tip)
end

local function apply(s)
    if type(s) ~= "table" then return end
    local status = type(s.status) == "string" and s.status or "offline"
    local changed = (status ~= snap.status)
    snap = { status = status, error = s.error }
    if changed then
        phase = BREATH_PERIOD / 2  -- snap breath to peak on change
    end
    render()
end

local function apply_unread(n)
    unread = tonumber(n) or 0
    render()
end

function onClick()
    -- Clear unread on open
    if unread > 0 then
        noctalia.runAsync("noctalia msg plugin 'weinguyen/opencode-companion:service' all clear_unread")
    end
    -- Toggle whichever panel entry matches the panel_mode setting (host-owned
    -- placement means the two modes are separate manifest entries).
    local mode = noctalia.getConfig and noctalia.getConfig("panel_mode") or "fill_right"
    local panel_id = (mode == "compact") and "panel" or "panel-fill"
    noctalia.togglePanel("weinguyen/opencode-companion:" .. panel_id)
end

function onRightClick()
    -- Quick action: create new session
    noctalia.runAsync("noctalia msg plugin 'weinguyen/opencode-companion:service' all create_session")
    noctalia.notify(tr("notify.title"), tr("notify.new_session"))
end

function onMiddleClick()
    -- Open current session in terminal (opencode attach)
    noctalia.runInTerminal("opencode attach")
end

function update()
    noctalia.setUpdateInterval(TICK_MS)
    phase = phase + TICK_MS / 1000
    if phase > 1e6 then phase = 0 end
    online_pulse = online_pulse + 1
    -- Periodic state refresh every ~10s to stay in sync
    if online_pulse % 100 == 0 then
        local s = noctalia.state.get(STATE_KEY)
        if type(s) == "table" and s.status ~= snap.status then
            apply(s)
        end
    end
    paint()
end

-- Subscribe to state changes
noctalia.state.watch(STATE_KEY, apply)
noctalia.state.watch(UNREAD_KEY, apply_unread)
noctalia.setUpdateInterval(TICK_MS)

-- Seed from current state
apply(noctalia.state.get(STATE_KEY))
apply_unread(noctalia.state.get(UNREAD_KEY))
render()
