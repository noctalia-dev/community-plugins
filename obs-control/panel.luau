--!nonstrict

local function action(name)
    noctalia.state.set("action", name)
end

local function render()
    local status = noctalia.state.get("status") or {}
    local busy = noctalia.state.get("busy") == true
    panel.render(ui.column({ gap = 12 }, {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = "OBS Studio", fontSize = 18, fontWeight = "bold", color = "primary" }),
            ui.button({ glyph = "settings", variant = "ghost", onClick = "settings" }),
        }),
        ui.label({ text = status.error or (busy and noctalia.tr("working")) or
            (status.connected and noctalia.tr("connected")) or status.message or noctalia.tr("disconnected"),
            color = status.error and "error" or "on_surface_variant", wrap = true }),
        ui.button({ text = noctalia.tr(status.record and "stop-record" or "start-record"),
            glyph = "circle", variant = status.record and "destructive" or "primary",
            enabled = not busy, onClick = "record" }),
        ui.button({ text = noctalia.tr(status.replay and "stop-replay" or "start-replay"),
            glyph = "history", enabled = not busy, onClick = "replay" }),
        ui.button({ text = noctalia.tr("save-replay"), glyph = "download",
            enabled = not busy and status.replay == true, onClick = "saveReplay" }),
        ui.button({ text = noctalia.tr(status.stream and "stop-stream" or "start-stream"),
            glyph = "broadcast", variant = status.stream and "destructive" or "default",
            enabled = not busy, onClick = "stream" }),
        ui.row({ gap = 8 }, {
            ui.button({ text = noctalia.tr("launch"), glyph = "external-link", enabled = not busy, onClick = "launch" }),
            ui.button({ text = noctalia.tr("videos"), glyph = "folder", enabled = not busy and status.connected == true, onClick = "videos" }),
        }),
    }))
end

function record() action("toggle-record") end
function replay() action("toggle-replay") end
function saveReplay() action("save-replay") end
function stream() action("toggle-stream") end
function launch() action("launch") end
function videos() action("open-videos") end
function settings() noctalia.openSettings() end
function onOpen(_context) render() end
noctalia.state.watch("status", function(_value) render() end)
noctalia.state.watch("busy", function(_value) render() end)
