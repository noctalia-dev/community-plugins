--!nonstrict
-- Grabit settings panel: configures grabit via `grabit set` / `grabit get`.

local settings = {}

local CAPTURE_FORMATS = { "png", "jpeg", "webp" }
local FILENAME_PRESETS = { "date", "random", "uuid", "timestamp" }
local RECORDING_FORMATS = { "mp4", "webm", "gif" }

-- grabit keys read back when the panel opens. `grabit set <key>` prints the
-- current value plus its default without writing anything.
local CONFIG_KEYS = {
    "also_save",
    "format",
    "filename",
    "filename_preset",
    "recording.fps",
    "recording.format",
    "recording.crf",
    "translate.target",
    "default_action",
    "service",
    "capture.cursor",
}

local function indexOf(arr, value)
    for i, v in ipairs(arr) do
        if v == value then return i - 1 end
    end
    return 0
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function nonEmpty(value, fallback)
    if type(value) == "string" and value ~= "" then return value end
    return fallback
end

local function isIntegerInRange(value, min, max)
    local n = tonumber(value)
    return n ~= nil and n >= min and n <= max and math.floor(n) == n
end

-- Write a grabit config value via CLI (argv form avoids shell parsing of values)
local function grabitSet(key, value)
    noctalia.runAsync({ "grabit", "set", key, value }, function(res)
        if res.exitCode ~= 0 then
            noctalia.notifyError("Grabit", "Failed to set config: " .. (res.stderr or "unknown error"))
        end
    end)
end

local function grabitUnset(key)
    noctalia.runAsync({ "grabit", "unset", key }, function(res)
        if res.exitCode ~= 0 then
            noctalia.notifyError("Grabit", "Failed to unset config: " .. (res.stderr or "unknown error"))
        end
    end)
end

-- `grabit set <key>` output looks like:
--   format = png|jpeg|webp
--   default: png
--   current: (unset)
local function parseConfigInfo(out)
    local current = trim((out or ""):match("current:%s*([^\n]*)") or "")
    if current == "" or current == "(unset)" then
        current = trim((out or ""):match("default:%s*([^\n]*)") or "")
    end
    return current
end

-- Only one `grabit set` runs at a time. Noctalia rejects runAsync spawns past a
-- small in-flight limit (8), and a rejected spawn looks like an empty value, so
-- firing every key at once silently dropped the trailing ones (default_action,
-- service, capture.cursor all read back blank). Serial keeps the panel correct
-- regardless of how many keys it reads.
local function readGrabitConfig(keys, onDone)
    local values = {}
    local index = 0

    local function next()
        index = index + 1
        local key = keys[index]
        if key == nil then
            onDone(values)
            return
        end

        local ok = noctalia.runAsync({ "grabit", "set", key }, function(res)
            values[key] = parseConfigInfo(res and res.stdout)
            next()
        end)
        if not ok then
            values[key] = ""
            next()
        end
    end

    if #keys == 0 then
        onDone(values)
        return
    end
    next()
end

-- ── State loading ────────────────────────────────────────────────

-- Bumped on every onOpen so a slow config read cannot overwrite the panel
-- after it has been reopened.
local loadGeneration = 0

function onOpen()
    -- grabit-side values; replaced by the real values once the reads land.
    settings.defaultAction = "copy"
    settings.uploadService = ""
    settings.showCursor = true
    settings.alsoSave = false
    settings.format = "png"
    settings.filenamePreset = "date"
    settings.filename = ""
    settings.recordingFps = "30"
    settings.recordingFormat = "mp4"
    settings.recordingCrf = "23"
    settings.translateTarget = "en"

    loadGeneration = loadGeneration + 1
    local generation = loadGeneration

    renderSettings()

    readGrabitConfig(CONFIG_KEYS, function(values)
        if generation ~= loadGeneration then return end
        settings.defaultAction = nonEmpty(values["default_action"], "copy")
        settings.uploadService = values["service"] or ""
        settings.showCursor = values["capture.cursor"] ~= "false"
        settings.alsoSave = values["also_save"] == "true"
        settings.format = nonEmpty(values["format"], "png")
        if settings.format == "jpg" then settings.format = "jpeg" end
        settings.filenamePreset = nonEmpty(values["filename_preset"], "date")
        settings.filename = values["filename"] or ""
        settings.recordingFps = nonEmpty(values["recording.fps"], "30")
        settings.recordingFormat = nonEmpty(values["recording.format"], "mp4")
        settings.recordingCrf = nonEmpty(values["recording.crf"], "23")
        settings.translateTarget = nonEmpty(values["translate.target"], "en")
        renderSettings()
    end)
end

-- ── UI ───────────────────────────────────────────────────────────

function renderSettings()
    -- The panel is content-sized up to max_height; a fixed-height scroll keeps
    -- the lower sections reachable once the content no longer fits.
    panel.render(ui.scroll({
        padding = 16,
        gap = 12,
        width = 420,
        height = 600,
    }, {
        ui.label({
            text = "Grabit Settings",
            fontWeight = "bold",
            fontSize = 16,
        }),
        ui.label({
            text = "Configure grabit behavior. Changes are applied immediately.",
            fontSize = 12,
            color = "on_surface_variant",
        }),
        ui.separator({}),

        -- Default action: grabit's own key, so the widget, shortcut, and the
        -- command builder all resolve the same value instead of maintaining a
        -- second copy in the plugin settings.
        ui.label({ text = "Default action", fontWeight = "bold" }),
        ui.select({
            options = { "Copy to clipboard", "Save to file", "Upload", "Pin to desktop" },
            selectedIndex = indexOf({ "copy", "save", "upload", "pin" }, settings.defaultAction),
            onChange = function(idx)
                local values = { "copy", "save", "upload", "pin" }
                local newVal = values[idx + 1]
                settings.defaultAction = newVal
                grabitSet("default_action", newVal)
            end,
        }),

        ui.label({ text = "Upload service" }),
        ui.input({
            value = settings.uploadService or "",
            placeholder = "zipline, nest, or .sxcu uploader name",
            onChange = function(value)
                local trimmed = trim(value)
                settings.uploadService = trimmed
                -- grabit validates the value, and rejects an empty one, so
                -- clearing the field must unset the key instead of writing "".
                if trimmed == "" then
                    grabitUnset("service")
                else
                    grabitSet("service", trimmed)
                end
            end,
        }),

        -- Cursor visibility: applies to both screenshots and recordings.
        -- grabit tracks these as two separate config keys; both are written here.
        ui.row({ gap = 8, align = "center" }, {
            ui.toggle({
                checked = settings.showCursor,
                onChange = function(value)
                    settings.showCursor = value == "true"
                    local v = tostring(settings.showCursor)
                    grabitSet("capture.cursor", v)
                    grabitSet("recording.cursor", v)
                end,
            }),
            ui.label({ text = "Include mouse cursor in captures and recordings" }),
        }),

        ui.separator({}),

        -- Capture output
        ui.label({ text = "Capture output", fontWeight = "bold" }),

        ui.row({ gap = 8, align = "center" }, {
            ui.toggle({
                checked = settings.alsoSave,
                onChange = function(value)
                    settings.alsoSave = value == "true"
                    grabitSet("also_save", tostring(settings.alsoSave))
                end,
            }),
            ui.label({ text = "Also save a copy to disk" }),
        }),

        ui.label({ text = "Image format" }),
        ui.select({
            options = { "PNG", "JPEG", "WebP" },
            selectedIndex = indexOf(CAPTURE_FORMATS, settings.format),
            onChange = function(idx)
                local value = CAPTURE_FORMATS[idx + 1]
                settings.format = value
                grabitSet("format", value)
            end,
        }),

        ui.label({ text = "Filename preset" }),
        ui.select({
            options = { "Date and time", "Random", "UUID", "Unix timestamp" },
            selectedIndex = indexOf(FILENAME_PRESETS, settings.filenamePreset),
            onChange = function(idx)
                local value = FILENAME_PRESETS[idx + 1]
                settings.filenamePreset = value
                grabitSet("filename_preset", value)
            end,
        }),

        ui.label({ text = "Filename template (overrides the preset)" }),
        ui.input({
            value = settings.filename or "",
            placeholder = "%Y-%m-%d-%H-%M-%S",
            onChange = function(value)
                settings.filename = value
                if value == "" then
                    grabitUnset("filename")
                else
                    grabitSet("filename", value)
                end
            end,
        }),

        ui.separator({}),

        -- Recording quality
        ui.label({ text = "Recording quality", fontWeight = "bold" }),

        ui.label({ text = "Frame rate (1-120)" }),
        ui.input({
            value = settings.recordingFps,
            placeholder = "30",
            onChange = function(value)
                if not isIntegerInRange(value, 1, 120) then return end
                settings.recordingFps = value
                grabitSet("recording.fps", value)
            end,
        }),

        ui.label({ text = "Container" }),
        ui.select({
            options = { "MP4", "WebM", "GIF" },
            selectedIndex = indexOf(RECORDING_FORMATS, settings.recordingFormat),
            onChange = function(idx)
                local value = RECORDING_FORMATS[idx + 1]
                settings.recordingFormat = value
                grabitSet("recording.format", value)
            end,
        }),

        ui.label({ text = "CRF (0-51, lower is higher quality)" }),
        ui.input({
            value = settings.recordingCrf,
            placeholder = "23",
            onChange = function(value)
                if not isIntegerInRange(value, 0, 51) then return end
                settings.recordingCrf = value
                grabitSet("recording.crf", value)
            end,
        }),

        ui.separator({}),

        -- OCR translation
        ui.label({ text = "OCR translation", fontWeight = "bold" }),
        ui.label({
            text = "Target language for the menu's OCR + translate entry",
            fontSize = 12,
            color = "on_surface_variant",
        }),
        ui.input({
            value = settings.translateTarget,
            placeholder = "en",
            onChange = function(value)
                settings.translateTarget = value
                if value:match("^%a%a%a?$") then
                    grabitSet("translate.target", value)
                end
            end,
        }),

        ui.separator({}),

        -- Open grabit config directly
        ui.button({
            text = "Open grabit config directory",
            glyph = "folder-open",
            variant = "outline",
            onClick = function()
                noctalia.runAsync("xdg-open ~/.config/grabit")
            end,
        }),

        ui.button({
            text = "Reset grabit config",
            glyph = "refresh",
            variant = "destructive",
            onClick = function()
                -- grabit set --reset only resets individual keys; there is no
                -- "reset everything" subcommand. Reset the keys this plugin
                -- manages explicitly instead.
                -- Use argv form to avoid shell parsing.
                local keysToReset = {
                    "default_action",
                    "capture.cursor",
                    "recording.cursor",
                    "service",
                    "also_save",
                    "format",
                    "filename",
                    "filename_preset",
                    "recording.fps",
                    "recording.format",
                    "recording.crf",
                    "translate.target",
                }
                -- `grabit set <key> --reset` only works for keys.* keybinds.
                -- `grabit unset <key>` removes the key and restores the default.
                -- Run them one at a time: runAsync rejects spawns past a small
                -- in-flight limit, so firing all of them at once would drop the
                -- trailing keys and leave them unreset.
                local index = 0
                local function unsetNext()
                    index = index + 1
                    local key = keysToReset[index]
                    if key == nil then
                        noctalia.notify("Grabit", "Config keys reset to defaults")
                        -- Wait for every unset before reading the values back;
                        -- otherwise the reload races them and shows old values.
                        onOpen()
                        return
                    end
                    local ok = noctalia.runAsync({ "grabit", "unset", key }, function(res)
                        if res.exitCode ~= 0 then
                            noctalia.notifyError(
                                "Grabit", "Failed to reset " .. key .. ": " .. (res.stderr or "")
                            )
                        end
                        unsetNext()
                    end)
                    if not ok then unsetNext() end
                end
                unsetNext()
            end,
        }),
    }))
end
