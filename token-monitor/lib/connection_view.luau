-- Connection guidance uses only the service's safe diagnostics, never credentials.
local View = require("./view.luau")
local Connection = {}

local function text(value, size, color, lines, weight)
    return ui.label({ text = value, fontSize = size or 11, color = color or "on_surface_variant",
        maxLines = lines or 2, fontWeight = weight or "normal", baseline = "textFixedHeight" })
end

local function tr(key, values) return noctalia.tr("connection." .. key, values) end

local function checkRow(key, value)
    local pending = value == nil or value == "waiting" or value == "checking"
    local color = value == "ok" and "primary" or (pending and "on_surface_variant" or "error")
    local errorKeys = { network = true, unauthorized = true, http = true, invalid_response = true,
        too_large = true, request_rejected = true, invalid_url = true, credentials_unreadable = true,
        credentials_invalid = true, processing_error = true }
    local status = value == "ok" and "check_ok" or (pending and "check_pending"
        or (errorKeys[value] and "check_" .. value or "check_failed"))
    return ui.row({ key = "check-" .. key, height = 28, align = "center", gap = 8,
        tooltip = not pending and value ~= "ok" and View.error(value) or "" }, {
        ui.glyph({ name = value == "ok" and "circle-check" or (pending and "circle-dashed" or "alert-circle"), size = 16, color = color }),
        ui.column({ flexGrow = 1 }, { text(tr(key), 12, "on_surface", 1) }),
        text(tr(status), 11, color, 1),
    })
end

local function step(number, title, description)
    return ui.row({ key = "step-" .. tostring(number), height = 64, align = "start", gap = 12 }, {
        ui.row({ width = 24, height = 24, radius = 7, fill = "primary/0.08", align = "center", justify = "center" }, {
            text(tostring(number), 11, "primary", 1, "semibold"),
        }),
        ui.column({ flexGrow = 1, gap = 4 }, {
            text(tr(title), 12, "on_surface", 1, "semibold"), text(tr(description), 11, nil, 4),
        }),
    })
end

function Connection.render(dashboard, width)
    local connection = dashboard.connection or {}
    local status = connection.status or "checking"
    local color = status == "ready" and "primary" or (status == "error" and "error" or "secondary")
    local source = connection.credentialSource or "none"
    local discovery = connection.discovery or "searching"
    local hint = "hint_ready"
    local failure = connection.stats ~= "ok" and connection.stats or connection.history
    if status == "checking" then hint = "hint_checking"
    elseif failure == "unauthorized" and source == "none" then hint = "hint_missing_credentials"
    elseif failure == "unauthorized" then hint = "hint_unauthorized"
    elseif failure == "network" then hint = "hint_network"
    elseif failure == "invalid_url" then hint = "hint_invalid_url"
    elseif failure == "credentials_unreadable" then hint = "hint_unreadable"
    elseif failure == "credentials_invalid" then hint = "hint_invalid_credentials"
    elseif failure == "processing_error" then hint = "hint_processing"
    elseif status == "partial" then hint = "hint_partial"
    elseif status == "error" then hint = "hint_response" end
    if status == "ready" and #(dashboard.providers or {}) == 0 then hint = "hint_empty" end

    local sourceKey = source == "manual" and "source_manual" or (source == "automatic" and "source_automatic" or "source_none")
    local credentialDetail = connection.credentialPath or ""
    if credentialDetail == "" then
        local known = { searching = true, not_found = true, invalid = true, unreadable = true, disabled = true, remote = true }
        credentialDetail = tr("discovery_" .. (known[discovery] and discovery or "not_found"))
    end
    local details = {
        ui.row({ key = "result-title", gap = 8, align = "center" }, {
            ui.glyph({ name = status == "ready" and "circle-check" or (status == "checking" and "loader-2" or "plug-connected"), size = 18, color = color }),
            text(tr("status_" .. status), 14, "on_surface", 1, "semibold"),
        }),
        ui.column({ key = "endpoint", gap = 4 }, {
            text(tr("address"), 10, nil, 1),
            text(connection.url and connection.url ~= "" and connection.url or tr("address_missing"), 12, "on_surface", 2),
        }),
        ui.column({ key = "credentials", gap = 4, tooltip = credentialDetail }, {
            text(tr(sourceKey), 11, "on_surface", 1, "semibold"),
            text(credentialDetail, 10, nil, 2),
        }),
        ui.separator({ color = "on_surface/0.08" }),
        ui.column({ key = "endpoint-checks", gap = 0 }, {
            checkRow("stats", connection.stats), checkRow("history", connection.history),
        }),
        text(tr(hint), 11, status == "error" and "error" or "on_surface_variant", 4),
    }
    if connection.checkedAt and connection.checkedAt > 0 and status ~= "checking" then
        details[#details + 1] = text(tr("checked", { time = View.received(connection.checkedAt) }), 10, nil, 1)
    end

    return {
        ui.column({ key = "connection-heading", width = width, gap = 6, paddingV = 4 }, {
            text(tr("title"), 20, "on_surface", 1, "bold"), text(tr("subtitle"), 11, nil, 2),
        }),
        ui.column({ key = "connection-status", width = width, padding = 16, gap = 10,
            radius = 12, fill = "surface_variant/0.25", border = "on_surface/0.06", borderWidth = 1 }, details),
        ui.column({ key = "connection-guide", width = width, height = 176, padding = 16, gap = 16,
            radius = 12, border = "on_surface/0.08", borderWidth = 1 }, {
            step(1, "step_host", "step_host_detail"),
            step(2, "step_connect", "step_connect_detail"),
        }),
    }
end

function Connection.actions(dashboard, width)
    local connection = dashboard.connection or {}
    local checking = connection.status == "checking"
    local canView = (dashboard.lastSuccess or 0) > 0 or (dashboard.history and (dashboard.history.lastSuccess or 0) > 0)
    return ui.column({ key = "connection-actions", width = width, gap = 8 }, {
        ui.row({ key = "test-settings", width = width, gap = 8 }, {
            ui.button({ key = "test", width = (width - 8) / 2, height = 34, text = tr(checking and "testing" or "test"),
                glyph = "plug-connected", enabled = not checking, onClick = "onTestConnection" }),
            ui.button({ key = "settings", width = (width - 8) / 2, height = 34, text = tr("settings"),
                variant = "ghost", glyph = "settings", onClick = "onSettings" }),
        }),
        ui.button({ key = "dashboard", width = width, height = 28, text = tr("back"),
            variant = "ghost", enabled = canView, onClick = "onConnectionBack" }),
    })
end

return Connection
