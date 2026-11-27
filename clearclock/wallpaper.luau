-- SPDX-License-Identifier: GPL-3.0-or-later
local M = {}
local busy, wanted, rendered, imageNode = false, nil, nil, nil
local pendingPath, latestFallback = nil, nil
local slot = 0
local retryAfter = 0

local function launch()
    if busy or not wanted or not pendingPath or os.time() < retryAfter then
        return
    end
    local request = wanted
    local path = pendingPath
    busy = true
    local started = noctalia.runAsync({"python3", noctalia.pluginDir() .. "/render.py",
        "--request", request, "--output", path}, function(result)
        busy = false
        if not wanted then
            return
        end
        if result.exitCode == 0 then
            local ok, size = pcall(noctalia.json.decode, result.stdout)
            if ok and size.width and size.height then
                rendered = request
                imageNode = ui.image({key = "wallpaper-clock", path = path,
                    width = size.width, height = size.height, fit = "contain"})
                desktopWidget.render(imageNode)
                if wanted ~= request then
                    slot = 1 - slot
                    pendingPath = path:gsub("%-[01]%.png$", "-" .. slot .. ".png")
                    launch()
                end
                return
            end
        end
        retryAfter = os.time() + 30
        noctalia.log("Wallpaper renderer failed; using native clock: " .. (result.stderr or ""))
        if latestFallback then desktopWidget.render(latestFallback) end
    end)
    if not started then busy = false; retryAfter = os.time() + 30 end
end

function M.render(content, fallback)
    local id = noctalia.getConfig("renderInstance")
    local desktop = noctalia.getSetting("desktop_widgets") or {}
    local widget = (desktop.widget or {})[id]
    if not widget then
        desktopWidget.render(fallback)
        return
    end
    local outputs = noctalia.outputs()
    local output = (not widget.output or widget.output == "") and outputs[1] or nil
    for _, candidate in ipairs(outputs) do
        if candidate.name == widget.output then output = candidate end
    end
    if not output then
        local matches = {}
        for _, candidate in ipairs(outputs) do
            if candidate.description and widget.output and
                candidate.description:find(widget.output, 1, true) then
                table.insert(matches, candidate)
            end
        end
        if #matches == 1 then output = matches[1] end
    end
    if not output then desktopWidget.render(fallback); return end
    local wallpaper = noctalia.wallpaperPath(output.name)
    if not wallpaper or wallpaper == "" then desktopWidget.render(fallback); return end
    local info = noctalia.fileInfo(wallpaper) or {}
    content.wallpaper = wallpaper
    content.mtime = info.mtime
    content.output = output
    content.outputs = outputs
    content.widget = widget
    content.fill = (noctalia.getSetting("wallpaper") or {}).fill_mode or "crop"
    content.fontDir = noctalia.pluginDir() .. "/fonts"
    content.gradient = noctalia.getConfig("adaptiveGradients") and noctalia.getConfig("adaptiveColors")
    content.glass = noctalia.getConfig("frostedGlass")
    content.glassStrength = noctalia.getConfig("glassStrength")
    content.fontGlass = noctalia.getConfig("frostedFont")
    content.fontGlassStrength = noctalia.getConfig("fontGlassStrength")
    content.primary = noctalia.getColor("primary") or "#a8c7fa"
    wanted = noctalia.json.encode(content)
    latestFallback = fallback
    if wanted == rendered and imageNode then desktopWidget.render(imageNode); return end
    if busy or os.time() < retryAfter then
        desktopWidget.render(imageNode or fallback)
        return
    end
    local data = noctalia.pluginDataDir()
    if not data then desktopWidget.render(fallback); return end
    -- Hex IDs keep filenames unique across instances without trusting IDs as paths.
    local safe = id:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
    slot = 1 - slot
    pendingPath = data .. "/wallpaper-" .. safe .. "-" .. slot .. ".png"
    launch()
    if not imageNode then desktopWidget.render(fallback) end
end

function M.reset()
    wanted, rendered, imageNode = nil, nil, nil
    pendingPath, latestFallback = nil, nil
end

return M
