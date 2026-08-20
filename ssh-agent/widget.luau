--!nonstrict
-- Bar widget — a thin client of the [[service]] entry (agent.luau owns all
-- the process/state logic). This replaces BarWidget.qml.
--
-- v5 bar widgets don't support a custom multi-item right-click context menu
-- (there's no ui.* menu component). The old "Refresh / Start Agent /
-- Settings" menu maps onto gestures instead:
--   left click   -> toggle the panel (has Refresh / Start / Stop buttons)
--   right click  -> quick refresh
--   middle click -> opens this plugin's settings (built-in host default)

local PLUGIN_PANEL = "martasskv5/ssh-agent:ssh-agent-panel"

local agentRunning = false
local loadedKeys = {}

local function render()
	barWidget.setGlyph(agentRunning and "key" or "key-off")
	barWidget.setGlyphColor(agentRunning and "primary" or "on_surface_variant")

	local count = #loadedKeys
	local statusText = agentRunning and "Running" or "Stopped"
	local tooltip = statusText
	if count > 0 then
		tooltip = tooltip .. " — Keys: " .. count
	end
	barWidget.setTooltip(tooltip)
end

local function applyStatus(status)
	if type(status) == "table" then
		agentRunning = status.agent_running == true
		loadedKeys = status.loaded_keys or {}
	end
	render()
end

applyStatus(noctalia.state.get("status"))
noctalia.state.watch("status", applyStatus)

function onClick()
	noctalia.togglePanel(PLUGIN_PANEL)
end

function onRightClick()
	noctalia.state.set("command", { action = "refresh", ts = noctalia.nowMs() })
end
