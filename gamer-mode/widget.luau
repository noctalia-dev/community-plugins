--!nonstrict
--
-- Bar widget: a glyph plus a live tooltip. It owns no state -- it renders whatever the
-- service publishes and sends commands back through `noctalia.state`.

local PANEL_ID = "nomadcxx/gamer-mode:main"
local MIB_PER_GIB = 1024

local M = {}

local metrics = noctalia.state.get("metrics") or { available = false }
local gameMode = noctalia.state.get("game_mode") or { enabled = false, suspended = {} }
local nonceCounter = 0

local function gibibytes(mib)
    return string.format("%.1fG", (tonumber(mib) or 0) / MIB_PER_GIB)
end

local function percent(fraction)
    return string.format("%d%%", math.floor((tonumber(fraction) or 0) * 100 + 0.5))
end

-- Rows rather than a joined string: setTooltip renders a list of {key, value} tables as
-- an aligned two-column block.
function M.tooltipRows(m, showTemps, gm)
    m = type(m) == "table" and m or {}
    local rows = {}
    if not m.available then
        rows[#rows + 1] = { key = noctalia.tr("widget.tooltip_loading"), value = "—" }
    else
        rows[#rows + 1] = { key = noctalia.tr("widget.cpu"), value = percent(m.cpuPerc) }
        if showTemps and tonumber(m.cpuTemp) then
            rows[#rows + 1] = { key = noctalia.tr("widget.cpu_temp"), value = string.format("%d°C", math.floor(tonumber(m.cpuTemp) + 0.5)) }
        end
        rows[#rows + 1] = { key = noctalia.tr("widget.ram"), value = gibibytes(m.memUsedMb) }

        -- GPU and VRAM rows are omitted entirely when unsupported: an empty reading is
        -- more honest than a zero that looks like an idle GPU.
        if m.gpuAvailable and m.gpuPerc then
            rows[#rows + 1] = { key = noctalia.tr("widget.gpu"), value = percent(m.gpuPerc) }
        end
        if showTemps and tonumber(m.gpuTemp) then
            rows[#rows + 1] = { key = noctalia.tr("widget.gpu_temp"), value = string.format("%d°C", math.floor(tonumber(m.gpuTemp) + 0.5)) }
        end
        if m.vramUsedMb then
            rows[#rows + 1] = { key = noctalia.tr("widget.vram"), value = gibibytes(m.vramUsedMb) }
        end
    end

    local validGm = type(gm) == "table" and gm or {}
    local suspended = type(validGm.suspended) == "table" and validGm.suspended or {}
    rows[#rows + 1] = {
        key = noctalia.tr("widget.gamer_mode"),
        value = validGm.enabled == true
            and noctalia.trp("widget.gamer_mode_on", #suspended)
            or noctalia.tr("widget.gamer_mode_off"),
    }
    return rows
end

-- Trimmed locally on purpose. The real binding is `noctalia.string.trim`, but the test
-- harness exposes a top-level `noctalia.trim`, so code written against the mock would
-- pass the suite and fail in the shell. A Lua pattern depends on neither.
local function trimmed(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function iconFile()
    local resting = trimmed(noctalia.getConfig("icon_file"))
    if resting == "" then
        return nil
    end
    if gameMode.enabled then
        local active = trimmed(noctalia.getConfig("icon_file_active"))
        if active ~= "" then
            return active
        end
    end
    return resting
end

local function render()
    local icon = iconFile()
    if icon then
        -- watch = true, so editing the file updates the bar without a reload. An image
        -- cannot be tinted, which is what icon_file_active exists to work around.
        barWidget.setImage(icon, true, 18)
    else
        barWidget.setGlyph(noctalia.getConfig("glyph") or "device-gamepad-2")
        barWidget.setGlyphColor(gameMode.enabled and "primary" or "on_surface")
    end
    barWidget.setTooltip(M.tooltipRows(metrics, noctalia.getConfig("show_temps") ~= false, gameMode))
end

local function sendCommand(action)
    nonceCounter = nonceCounter + 1
    noctalia.state.set("command", {
        nonce = noctalia.nowMs() * 1000 + nonceCounter,
        action = action,
    })
end

-- Left-click opens the panel by default. A first click should show what the machine is
-- doing, not suspend a list of programs the user has not read yet.
function M.onClick()
    if (noctalia.getConfig("click_action") or "open_panel") == "toggle" then
        sendCommand("toggle")
    else
        noctalia.togglePanel(PANEL_ID)
    end
end

-- Right-click always toggles, whatever click_action says, so the one-click path stays
-- available without opening the panel first.
function M.onRightClick()
    sendCommand("toggle")
end

noctalia.state.watch("metrics", function(value)
    metrics = type(value) == "table" and value or { available = false }
    render()
end)

noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, suspended = {} }
    render()
end)

-- ── shell entry points (must be globals) ──

function onClick()
    M.onClick()
end

function onRightClick()
    M.onRightClick()
end

function onConfigChanged()
    render()
end

render()

return M
