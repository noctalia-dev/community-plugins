local STATE_KEY = "noctalia_ytmusic.state"

local state = require("./views/state.luau")
local rerender = require("./views/rerender.luau")
local sidebar_comp = require("./views/components/sidebar.luau")
local playerbar_comp = require("./views/components/playerbar.luau")
local auth_comp = require("./views/components/auth.luau")
local home_comp = require("./views/components/home.luau")
local discover_comp = require("./views/components/discover.luau")
local playlist_comp = require("./views/components/playlist.luau")
local queue_comp = require("./views/components/queue.luau")
local settings_comp = require("./views/components/settings.luau")
local offline_comp = require("./views/components/offline.luau")
local artist_comp = require("./views/components/artist.luau")

local function build_content()
	local content = {}

	local page_builders = {
		playlist = playlist_comp.build,
		discover = discover_comp.build,
		queue = queue_comp.build,
		settings = settings_comp.build,
		offline = offline_comp.build,
		artist = artist_comp.build,
	}

	local builder = page_builders[state.view.content_page]
	if builder then
		for _, item in ipairs(builder()) do
			table.insert(content, item)
		end
	else
		if not state.logged_in() then
			table.insert(content, auth_comp.build_signin_prompt())
		else
			for _, item in ipairs(home_comp.build()) do
				table.insert(content, item)
			end
		end
	end

	return ui.scroll({ key = "content-scroll", flexGrow = 1, gap = 12, paddingH = 16, paddingV = 12 }, content)
end

local function render_panel()
	local body = {}

	table.insert(
		body,
		ui.row({
			key = "main-row",
			align = "stretch",
			flexGrow = 1,
			gap = 12,
			borderWidth = 0,
		}, {
			sidebar_comp.build_sidebar(),

			ui.column({
				key = "right-col",
				flexGrow = 1,
				borderWidth = 0,
				gap = 0,
			}, {
				sidebar_comp.build_topbar(),
				ui.separator({ key = "sep-top", color = "outline" }),
				build_content(),
			}),
		})
	)

	table.insert(body, ui.row({ key = "player-spacer", height = 12, borderWidth = 0 }))

	table.insert(body, ui.row({ key = "sep-player", height = 1, fill = "on_surface/0.3", borderWidth = 0 }))

	table.insert(body, playerbar_comp.build())

	panel.render(ui.column({
		key = "ytmusic-root",
		gap = 0,
		padding = 0,
		flexGrow = 1,
	}, body))
end

rerender.set(render_panel)

function onSidebarHover(hover_state, key)
	state.hover_update("sidebar", hover_state, key)
end
function onCardHover(hover_state, key)
	state.hover_update("card", hover_state, key)
end
function onTrackHover(hover_state, key)
	state.hover_update("track", hover_state, key)
end

function onOpen(_context)
	-- home_library_ready is deliberately NOT reset here: probes showed a
	-- false->true flip re-materializes the whole panel twice per open, which
	-- costs more than building the library grid inline. Sticky = single pass.
	local curr = noctalia.state.get(STATE_KEY)
	if curr then
		state.apply(curr)
	end
end

if noctalia.state and noctalia.state.watch then
	noctalia.state.watch(STATE_KEY, state.apply)
	local curr = noctalia.state.get(STATE_KEY)
	if curr then
		state.apply(curr)
	end
end

render_panel()
