-- SPDX-License-Identifier: GPL-3.0-or-later
-- Noctalia v5.4.1 owns the plugin-widget background and defaults it to true.
-- Seed only a missing choice; explicit true/false values are always preserved.
noctalia.setUpdateInterval(2000)
local pending = false
local retryAfter = 0

local function tomlKey(value)
    -- Widget IDs may be quoted TOML keys, including spaces, dots, and quotes.
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"')
        :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
end

function update()
    if pending or os.time() < retryAfter then
        return
    end
    local desktop = noctalia.getSetting("desktop_widgets") or {}
    for id, widget in pairs(desktop.widget or {}) do
        local settings = widget.settings or {}
        if widget.type == "nirusaki/clearclock:desktop"
            and (settings.background == nil or settings.renderInstance ~= id) then
            -- Merge one leaf so other widget settings, order, and placement
            -- survive. Argument arrays avoid interpreting IDs as shell code.
            local values = "renderInstance = " .. tomlKey(id)
            if settings.background == nil then values = values .. ", background = false" end
            local value = "{ " .. tomlKey(id) .. " = { settings = { " .. values .. " } } }"
            pending = true
            local started = noctalia.runAsync({
                "noctalia", "msg", "config-set", "desktop_widgets.widget", value,
            }, function(result)
                pending = false
                if result.exitCode ~= 0 or not result.stdout:match("^ok%s*$") then
                    retryAfter = os.time() + 30
                    noctalia.log("Could not set ClearClock's transparent default: "
                        .. (result.stderr or "") .. (result.stdout or ""))
                end
            end)
            if not started then
                pending = false
                retryAfter = os.time() + 30
                noctalia.log("Could not launch ClearClock's background defaults update")
            end
            return
        end
    end
end
