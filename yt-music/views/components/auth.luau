local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local BROWSERS = require("../../utils/browsers.luau")

-- Always-on dependency card above the browser grid: every check with its
-- status in both success and failure cases. Returns nil only before the
-- first check has run.
local DEP_ORDER = { "ytdlp", "mpv", "jq", "nc", "curl" }

local DEP_LABEL = {
    ytdlp = "yt-dlp",
    mpv = "mpv",
    jq = "jq",
    nc = "netcat",
    curl = "curl",
}

local function short_ver(name, detail)
    detail = tostring(detail or "")
    if name == "mpv" or name == "curl" then
        local a, b = detail:match("^(%S+)%s+(%S+)")
        if a then
            return a .. " " .. b
        end
        return ""
    end
    return detail
end

local DEP_IMPACT = {
    ytdlp = "not found — search, playback and downloads won't work",
    mpv = "not found — no audio playback",
    jq = "not found — search, library and playlists won't work",
    nc = "not found — duration, controls and auto-advance won't work",
    curl = "not found — thumbnails won't load",
}

local function build_health_card()
    local h = state.data.health
    if type(h) ~= "table" or next(h) == nil then
        return nil
    end
    local rows = {}
    for _, name in ipairs(DEP_ORDER) do
        local dep = h[name]
        if dep then
            local label = DEP_LABEL[name] or name
            local status = dep.status or "missing"
            local glyph, text, color
            if status == "missing" then
                glyph, color = "x", "error"
                text = label .. ": " .. (DEP_IMPACT[name] or "not found")
            elseif status == "warn" then
                glyph, color = "alert-triangle", "error"
                text = label .. ": " .. tostring(dep.detail or "")
            else
                local ver = short_ver(name, dep.detail)
                glyph, color = "check", "primary"
                text = label .. (ver ~= "" and (": " .. ver) or "")
            end
            table.insert(rows, ui.row({ key = "health-row-" .. name, gap = 8, align = "center" }, {
                ui.glyph({ name = glyph, size = 18, color = color }),
                ui.label({ text = text, fontSize = theme.fontTitle, color = color })
            }))
        end
    end
    if #rows == 0 then
        return nil
    end
    local checking = state.data.checking_health == true
    table.insert(rows, 1, ui.row({ key = "health-header", align = "center", justify = "space_between" }, {
        ui.label({
            text = "HEALTHCHECK",
            fontSize = theme.fontHeading,
            fontWeight = "bold",
            color = "on_surface_variant"
        }),
        ui.button({
            key = "btn-health-refresh",
            glyph = checking and "loader" or "refresh",
            variant = "ghost",
            controlSize = "sm",
            tooltip = checking and "Checking dependencies..." or "Re-check dependencies",
            onClick = checking and nil or function() request("refresh_health") end
        })
    }))
    return ui.column({
        key = "health-card",
        gap = 6,
        padding = 14,
        borderWidth = 0,
        fill = "surface_variant/0.5",
        width = 880
    }, rows)
end

local function build_browser_cells()
    local cells = {}
    for _, b in ipairs(BROWSERS) do
        local is_avail = state.data.available[b.id]
        local is_current = (state.data.extracting and state.data.browser == b.id)
        local key = "browser-btn-" .. b.id
        local is_hovered = (state.view.hover_key.card == key)

        if is_current then
            table.insert(cells, ui.row({
                key = key,
                align = "center",
                justify = "center",
                gap = 12,
                paddingV = 16,
                paddingH = 20,
                borderWidth = 1,
                border = "primary",
                fill = "primary/0.1",
                flexGrow = 1,
                onClick = function() request("extract", { browser = b.id }) end
            }, {
                ui.glyph({ name = "loader", size = 24, color = "primary" })
            }))
        elseif is_avail then
            table.insert(cells, ui.row({
                key = key,
                align = "center",
                justify = "center",
                gap = 12,
                paddingV = 16,
                paddingH = 20,
                borderWidth = 1,
                border = is_hovered and "primary" or "outline",
                fill = is_hovered and "surface_variant/0.8" or "surface_variant/0.4",
                flexGrow = 1,
                onClick = function()
                    if state.data.browser == b.id and state.data.status_text:find("Opened") then
                        request("extract", { browser = b.id })
                    else
                        request("open_login", { browser = b.id })
                    end
                end,
                onHover = function(h)
                    if h == "true" then
                        if state.view.hover_key.card ~= key then state.view.hover_key.card = key; rerender.call() end
                    else
                        if state.view.hover_key.card == key then state.view.hover_key.card = nil; rerender.call() end
                    end
                end
            }, {
                ui.glyph({ name = b.icon, size = 24, color = is_hovered and "primary" or "on_surface" }),
                ui.label({ text = b.label, fontSize = theme.fontTitle, fontWeight = "bold", color = is_hovered and "primary" or "on_surface" })
            }))
        else
            table.insert(cells, ui.row({
                key = "browser-off-" .. b.id,
                align = "center",
                justify = "center",
                gap = 12,
                paddingV = 16,
                paddingH = 20,
                borderWidth = 1,
                border = "outline/0.3",
                fill = "surface_variant/0.1",
                flexGrow = 1
            }, {
                ui.glyph({ name = b.icon, size = 24, color = "on_surface_variant/0.4" }),
                ui.label({ text = b.label, fontSize = theme.fontTitle, fontWeight = "bold", color = "on_surface_variant/0.4" })
            }))
        end
    end
    return cells
end

local function build_signin_prompt()
    local browser_rows = {}
    for _, row in ipairs(common.chunk_rows(build_browser_cells(), 3, "browser-grid", 12)) do
        table.insert(browser_rows, row)
    end
    local prompt_children = {
        ui.glyph({ name = "music", size = 48, color = "primary" }),
        ui.label({ text = "YouTube Music", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
        ui.row({ height = 4, borderWidth = 0 }),
        ui.column({ align = "start", gap = 8 }, {
            ui.label({ text = "1. Close any open windows of your browser", fontSize = theme.fontHeading, fontWeight = "medium", color = "on_surface_variant" }),
            ui.label({ text = "2. Select the browser below, it'll open a new window. Sign in to your YouTube Music there.", fontSize = theme.fontHeading, fontWeight = "medium", color = "on_surface_variant" }),
            ui.label({ text = "3. Keep the browser open, then click the button again to extract cookies", fontSize = theme.fontHeading, fontWeight = "medium", color = "on_surface_variant" }),
        }),
        ui.row({ height = 6, borderWidth = 0 }),
        ui.label({
            text = state.data.status_text,
            fontSize = theme.fontTitle,
            color = state.data.status == "error" and "error" or "primary"
        }),
        ui.column({ gap = 12, width = "fill" }, browser_rows)
    }
    local health_card = build_health_card()
    if health_card then
        table.insert(prompt_children, 3, health_card)
    end

    return ui.column({
        key = "signin-prompt",
        align = "center",
        justify = "center",
        gap = 16,
        padding = 40,
        flexGrow = 1
    }, prompt_children)
end

local function build_cookies_page()
    local page = {}

    table.insert(page, ui.row({ key = "cookie-title", align = "center", gap = 8 }, {
        ui.glyph({ name = "login", size = 18, color = "primary" }),
        ui.label({ text = "COOKIES & LOGIN", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" })
    }))

    local status_color = "on_surface_variant"
    if state.data.status == "ready" then
        status_color = "primary"
    elseif state.data.status == "error" then
        status_color = "error"
    end

    local status_children = {
        ui.label({ text = "COOKIE STATUS", fontSize = theme.fontHeading, fontWeight = "bold", color = status_color }),
        ui.label({ text = state.data.status_text, fontSize = theme.fontTitle, fontWeight = "medium", color = "on_surface" })
    }
    if state.data.status == "ready" then
        table.insert(status_children, ui.label({
            text = "YouTube cookies: " .. state.data.cookie_count,
            fontSize = theme.fontTitle,
            color = "on_surface_variant"
        }))
    elseif state.data.status == "error" and state.data.last_error and state.data.last_error ~= "" then
        local err = state.data.last_error
        if #err > 220 then err = err:sub(1, 220) .. "..." end
        table.insert(status_children, ui.label({
            text = err,
            fontSize = theme.fontTitle,
            color = "on_surface_variant"
        }))
    end

    table.insert(page, ui.column({
        key = "cookie-status-card",
        gap = 8,
        padding = 14,
        borderWidth = 0,
        fill = "surface_variant/0.5"
    }, status_children))

    table.insert(page, ui.row({ key = "spacer-above-sep-cookie", height = 4, borderWidth = 0 }))
    table.insert(page, ui.separator({ key = "sep-cookie", color = "outline/0.3" }))

    table.insert(page, ui.label({ text = "LOG IN & EXTRACT", fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }))

    table.insert(page, ui.column({ key = "cookie-steps", gap = 6, padding = 4 }, {
        ui.label({ text = "1. Close any open windows of your browser", fontSize = theme.fontTitle, fontWeight = "medium", color = "on_surface_variant" }),
        ui.label({ text = "2. Select the browser below, it'll open a new window. Sign in to your YouTube Music there.", fontSize = theme.fontTitle, fontWeight = "medium", color = "on_surface_variant" }),
        ui.label({ text = "3. Keep the browser open, then click the button again to extract cookies", fontSize = theme.fontTitle, fontWeight = "medium", color = "on_surface_variant" }),
    }))

    table.insert(page, ui.row({ key = "spacer-above-browser-grid", height = 4, borderWidth = 0 }))

    local cells = build_browser_cells()
    local grid_rows = common.chunk_rows(cells, 3, "browser-grid", 12)
    local health_card = build_health_card()
    if health_card then
        table.insert(grid_rows, 1, health_card)
    end
    for _, row in ipairs(grid_rows) do
        table.insert(page, row)
    end

    return page
end

return {
    build_signin_prompt = build_signin_prompt,
    build_cookies_page = build_cookies_page
}