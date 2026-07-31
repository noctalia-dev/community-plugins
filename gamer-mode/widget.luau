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

-- withTemp appends a temperature only when there is one to show, so a machine without
-- sensors reads as "GPU 18%" rather than "GPU 18% 0°C".
local function withTemp(label, showTemps, temp)
    if showTemps and tonumber(temp) then
        return label .. string.format(" %d°C", math.floor(tonumber(temp) + 0.5))
    end
    return label
end

function M.formatTooltip(m, showTemps, gm)
    m = m or {}
    if not m.available then
        return noctalia.tr("widget.tooltip_loading")
    end

    local parts = {
        withTemp("CPU " .. percent(m.cpuPerc), showTemps, m.cpuTemp),
        "RAM " .. gibibytes(m.memUsedMb),
    }
    -- GPU and VRAM segments are omitted entirely when unsupported: an empty reading is
    -- more honest than a zero that looks like an idle GPU.
    if m.gpuAvailable and m.gpuPerc then
        parts[#parts + 1] = withTemp("GPU " .. percent(m.gpuPerc), showTemps, m.gpuTemp)
    end
    if m.vramUsedMb then
        parts[#parts + 1] = "VRAM " .. gibibytes(m.vramUsedMb)
    end

    local tooltip = table.concat(parts, " | ")
    if gm and gm.enabled then
        tooltip = noctalia.tr("notify.enabled_title") .. " | " .. tooltip
    end
    return tooltip
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph") or "device-gamepad-2")
    barWidget.setTooltip(M.formatTooltip(metrics, noctalia.getConfig("show_temps") ~= false, gameMode))
    -- Accent the glyph while gamer mode is on, so the bar shows the state at a glance
    -- without needing the tooltip.
    barWidget.setGlyphColor(gameMode.enabled and "primary" or "on_surface")
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
