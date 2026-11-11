--!nonstrict
-- Grabit mode menu: right-click panel with all capture mode options.

-- Let the panel finish its close animation before grabit starts. grabit's own
-- --delay only accepts whole seconds, so the service defers the spawn instead.
local CAPTURE_DELAY_MS = 300

local function closePanel()
    panel.close()
end

local function captureMode(mode)
    closePanel()
    noctalia.state.set("command", {
        action = "capture",
        mode = mode,
        delay_ms = CAPTURE_DELAY_MS,
    })
end

local function recordMode()
    closePanel()
    noctalia.state.set("command", {
        action = "record",
        delay_ms = CAPTURE_DELAY_MS,
    })
end

local function openSettings()
    closePanel()
    noctalia.togglePanel("snowballons/grabit:settings")
end

function onOpen()
    panel.render(ui.column({
        padding = 8,
        gap = 2,
    }, {
        ui.label({
            text = "Grabit",
            fontWeight = "bold",
            fontSize = 14,
        }),
        ui.spacer({ height = 6 }),

        ui.row({ gap = 8, align = "start" }, {
            ui.column({ flexGrow = 1, gap = 2 }, {
                -- Capture modes
                ui.button({
                    text = "Region (copy)",
                    glyph = "screenshot",
                    variant = "ghost",
                    onClick = function() captureMode("copy") end,
                }),
                ui.button({
                    text = "Region (save)",
                    glyph = "download",
                    variant = "ghost",
                    onClick = function() captureMode("save") end,
                }),
                ui.button({
                    text = "Region (upload)",
                    glyph = "upload",
                    variant = "ghost",
                    onClick = function() captureMode("upload") end,
                }),

                ui.separator({ spacing = 4 }),

                ui.button({
                    text = "Fullscreen",
                    glyph = "maximize",
                    variant = "ghost",
                    onClick = function() captureMode("fullscreen") end,
                }),
                ui.button({
                    text = "Window",
                    glyph = "window",
                    variant = "ghost",
                    onClick = function() captureMode("window") end,
                }),
                ui.button({
                    text = "Last region",
                    glyph = "history",
                    variant = "ghost",
                    onClick = function() captureMode("last") end,
                }),

                ui.separator({ spacing = 4 }),

                ui.button({
                    text = "Annotate",
                    glyph = "edit",
                    variant = "ghost",
                    onClick = function() captureMode("annotate") end,
                }),
                ui.button({
                    text = "OCR to clipboard",
                    glyph = "text-recognition",
                    variant = "ghost",
                    onClick = function() captureMode("ocr") end,
                }),
                ui.button({
                    text = "OCR + translate",
                    glyph = "language",
                    variant = "ghost",
                    onClick = function() captureMode("ocr-translate") end,
                }),
            }),

            ui.column({ flexGrow = 1, gap = 2 }, {
                -- Pin management
                ui.button({
                    text = "Pin to desktop",
                    glyph = "pin",
                    variant = "ghost",
                    onClick = function() captureMode("pin") end,
                }),
                ui.button({
                    text = "Grab pins (edit)",
                    glyph = "hand-move",
                    variant = "ghost",
                    onClick = function() captureMode("pin-grab") end,
                }),
                ui.button({
                    text = "Release pins",
                    glyph = "pin-filled",
                    variant = "ghost",
                    onClick = function() captureMode("pin-release") end,
                }),
                ui.button({
                    text = "Unpin all",
                    glyph = "x",
                    variant = "ghost",
                    onClick = function() captureMode("unpin-all") end,
                }),

                ui.separator({ spacing = 4 }),

                ui.button({
                    text = "Start recording",
                    glyph = "video",
                    variant = "ghost",
                    onClick = recordMode,
                }),

                ui.separator({ spacing = 8 }),

                ui.button({
                    text = "Settings...",
                    glyph = "settings",
                    variant = "ghost",
                    onClick = openSettings,
                }),
            }),
        }),
    }))
end
