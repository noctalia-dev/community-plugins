--!nonstrict
-- Panel entry point: composes the sound library, audio engine, and UI.
local sounds = require("./sound_library.luau")
local AudioEngine = require("./audio_engine.luau")
local engine = AudioEngine.new(sounds)
local pluginRoot = noctalia.pluginDir() or "."
local customIconFont, customIconError = noctalia.loadFont("icons/fluent-person-sound-spatial.otf")
if not customIconFont and customIconError then
    noctalia.notifyError("Ambient Sounds", "Icon font failed: " .. customIconError)
end
local soundIconFonts = {}

local function soundIcon(sound)
    if sound.custom_icon then
        local font = soundIconFonts[sound.icon]
        if font == false then
            return ui.glyph({ name = sound.fallback_icon or "music", size = 22, color = "primary" })
        end
        if font == nil then
            font = noctalia.loadFont(pluginRoot .. "/" .. sound.icon)
            soundIconFonts[sound.icon] = font or false
        end
        if font then
            return ui.label({ text = "\u{E000}", fontFamily = font, fontSize = 22, color = "primary" })
        end
    end
    return ui.glyph({ name = sound.icon, size = 22, color = "primary" })
end

local function soundCard(sound)
    return ui.column({ gap = 12, padding = 16, flexGrow = 1, minWidth = 240,
        fill = sound.enabled and "surface_variant/0.38" or "surface_variant/0.20", radius = 16,
        border = sound.enabled and "primary/0.45" or "outline/0.35", borderWidth = 1 }, {
        ui.row({ gap = 12, align = "center" }, {
            ui.row({ width = 46, height = 46, radius = 12, border = "outline/0.25", borderWidth = 1, align = "center", justify = "center" }, {
                soundIcon(sound),
            }),
            ui.column({ gap = 3, flexGrow = 1 }, {
                ui.label({ text = sound.title, fontSize = 15, fontWeight = "bold" }),
                ui.label({ text = sound.description, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
            }),
            ui.toggle({
                checked = sound.enabled,
                onChange = function(value)
                    engine:toggleSound(sound.id, value == "true")
                    render()
                end,
            }),
        }),
        ui.separator({ thickness = 1, color = "outline/0.25" }),
        ui.row({ gap = 10, align = "center" }, {
            ui.label({ text = "VOLUME", fontSize = 10, color = "on_surface_variant", width = 52 }),
            ui.slider({ min = 0, max = 100, step = 1, value = sound.level, controlSize = "sm", flexGrow = 1,
                onChange = function(value) engine:setSoundVolume(sound.id, tonumber(value) or 0); render() end }),
            ui.label({ text = sound.level .. "%", fontSize = 11, color = "primary", width = 35, textAlign = "end" }),
        }),
        ui.button({
            glyph = "bolt",
            glyphSize = 14,
            text = sound.amplified and "Amplified" or "Amplify",
            variant = sound.amplified and "primary" or "outline",
            controlSize = "sm",
            onClick = function()
                engine:setAmplified(sound.id, not sound.amplified)
                render()
            end,
        }),
    })
end

function render()
    local cardRows = {}
    for index, sound in ipairs(sounds) do
        local row = cardRows[math.ceil(index / 4)]
        if not row then
            row = {}
            table.insert(cardRows, row)
        end
        table.insert(row, soundCard(sound))
    end

    local grid = {}
    for _, row in ipairs(cardRows) do
        while #row < 4 do table.insert(row, ui.spacer({ flexGrow = 1, minWidth = 240 })) end
        table.insert(grid, ui.row({ gap = 12, align = "stretch" }, row))
    end

    panel.render(ui.column({ gap = 18, padding = 22, height = 676, fill = "surface/0.45" }, {
        ui.row({ gap = 18, padding = 20, align = "center", fill = "surface_variant/0.30", radius = 18,
            border = engine.running and "primary/0.65" or "primary/0.35", borderWidth = 1 }, {
            ui.row({ width = 58, height = 58, fill = "surface/0.75", radius = 16, border = "primary/0.7", borderWidth = 1, align = "center", justify = "center" }, {
                customIconFont
                    and ui.label({ text = "\u{E000}", fontFamily = customIconFont, fontSize = 30, color = "primary" })
                    or ui.glyph({ name = "music", size = 30, color = "primary" }),
            }),
            ui.column({ gap = 4, flexGrow = 1 }, {
                ui.label({ text = "Ambient Sounds", fontSize = 25, fontWeight = "bold" }),
                ui.label({ text = engine.running and "Engine running" or "High-Fidelity Ambient Sound Mixer", fontSize = 12, color = "on_surface_variant" }),
            }),
            ui.button({ glyph = engine.running and "player-stop" or "player-play", glyphSize = 16, text = engine.running and "STOP ENGINE" or "START ENGINE", variant = engine.running and "outline" or "primary", controlSize = "md",
                onClick = function() if engine.running then engine:stopAll() else engine:start() end; render() end }),
        }),
        ui.scroll({ gap = 12, flexGrow = 1, align = "stretch" }, grid),
    }))
end

function onOpen(_context)
    render()
end

function onExit(_signal, _reason)
    engine:cleanup()
end
