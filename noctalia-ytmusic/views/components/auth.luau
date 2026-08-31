local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local BROWSERS = require("../../utils/browsers.luau")

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
                onClick = function() request("extract", { browser = b.id }) end,
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

    return ui.column({
        key = "signin-prompt",
        align = "center",
        justify = "center",
        gap = 10,
        padding = 40,
        flexGrow = 1
    }, {
        ui.glyph({ name = "music", size = 44, color = "primary" }),
        ui.label({ text = "Noctalia YT Music", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = "Pick the browser you're signed into YouTube Music with", fontSize = theme.fontTitle, color = "on_surface_variant" }),
        ui.label({
            text = state.data.status_text,
            fontSize = theme.fontTitle,
            color = state.data.status == "error" and "error" or "on_surface_variant"
        }),
        ui.column({ gap = 8, width = "fill" }, browser_rows)
    })
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

    local cells = build_browser_cells()

    for _, row in ipairs(common.chunk_rows(cells, 3, "browser-grid", 12)) do
        table.insert(page, row)
    end

    table.insert(page, ui.row({ key = "spacer-above-sep-cookie-2", height = 4, borderWidth = 0 }))
    table.insert(page, ui.separator({ key = "sep-cookie-2", color = "outline/0.3" }))

    table.insert(page, ui.row({ key = "cookie-hint", align = "center", gap = 8, padding = 4 }, {
        ui.glyph({ name = "info-circle", size = 15, color = "on_surface_variant" }),
        ui.label({
            text = "Sign in to YouTube Music in a browser, then click its button to export YouTube cookies. If the browser has no session, the login page opens for you.",
            fontSize = theme.fontTitle,
            color = "on_surface_variant",
            flexGrow = 1
        })
    }))

    return page
end

return {
    build_signin_prompt = build_signin_prompt,
    build_cookies_page = build_cookies_page
}