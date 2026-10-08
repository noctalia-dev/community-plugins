local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local BROWSERS = require("../../utils/browsers.luau")

local DEP_ORDER = { "ytdlp", "mpv", "jq", "nc", "curl" }

local DEP_LABEL = {
	ytdlp = "yt-dlp",
	mpv = "mpv",
	jq = "jq",
	nc = "netcat",
	curl = "curl",
}

local DEP_IMPACT = {
	ytdlp = "search, playback and downloads won't work",
	mpv = "no audio playback",
	jq = "search, library and playlists won't work",
	nc = "duration, controls and auto-advance won't work",
	curl = "thumbnails won't load",
}

local STEP_TEXTS = {
	"Close any open windows of your browser.",
	"Pick a browser below — it opens a fresh window. Sign in to YouTube Music there.",
	"Leave the browser open, then pick the same browser again to pull the cookies in.",
}

local function short_ver(name, detail)
	detail = tostring(detail or "")
	if name == "mpv" or name == "curl" then
		local a, b = detail:match("^(%S+)%s+(%S+)")
		if a then
			return a .. " " .. b
		end
		return ""
	end
	return detail
end

-- ── Status ───────────────────────────────────────────────────────────────────
-- One hero card that reads the connection state at a glance. Every state keeps
-- the same skeleton (glyph, title, message); only the tint and copy change.

local function build_status_card()
	local glyph, color, title = "login", "on_surface_variant", "Not connected"
	local fill, border = "surface_variant/0.35", nil

	if state.data.status == "ready" then
		glyph, color, title = "check", "primary", "Connected"
		fill, border = "primary/0.08", "primary/0.35"
	elseif state.data.status == "error" then
		glyph, color, title = "alert-triangle", "error", "Connection failed"
		fill, border = "error/0.08", "error/0.35"
	elseif state.data.extracting then
		glyph, color, title = "loader", "primary", "Extracting cookies..."
	end

	local text_children = {
		ui.label({ text = title, fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface" }),
	}
	if state.data.status_text and state.data.status_text ~= "" then
		table.insert(
			text_children,
			ui.label({ text = state.data.status_text, fontSize = theme.fontTitle, color = "on_surface_variant" })
		)
	end
	if state.data.status == "error" and state.data.last_error and state.data.last_error ~= "" then
		local err = state.data.last_error
		if #err > 160 then
			err = err:sub(1, 160) .. "..."
		end
		table.insert(text_children, ui.label({ text = err, fontSize = theme.fontBody, color = "on_surface_variant" }))
	end

	local children = {
		ui.glyph({ name = glyph, size = 26, color = color }),
		ui.column({ gap = 3, flexGrow = 1, radius = theme.radius }, text_children),
	}
	if state.data.status == "ready" and (state.data.cookie_count or 0) > 0 then
		table.insert(
			children,
			ui.column({ gap = 0, align = "end", radius = theme.radius }, {
				ui.label({
					text = tostring(state.data.cookie_count),
					fontSize = theme.fontHero,
					fontWeight = "bold",
					color = "primary",
				}),
				ui.label({ text = "cookies", fontSize = theme.fontCaption, color = "on_surface_variant" }),
			})
		)
	end

	return ui.row({
		key = "cookie-status-card",
		gap = 14,
		align = "center",
		padding = 16,
		borderWidth = border and 1 or 0,
		border = border,
		fill = fill,
		radius = theme.radius,
	}, children)
end

-- ── Steps ────────────────────────────────────────────────────────────────────
-- Numbered badges rather than bare lines, so the sequence reads as a sequence.

local function build_steps()
	local rows = {}
	for i, text in ipairs(STEP_TEXTS) do
		table.insert(
			rows,
			ui.row({ key = "cookie-step-" .. i, gap = 12, align = "start", radius = theme.radius }, {
				ui.row({
					align = "center",
					justify = "center",
					width = 22,
					height = 22,
					borderWidth = 0,
					fill = "primary/0.12",
					radius = theme.radius,
				}, {
					ui.label({ text = tostring(i), fontSize = theme.fontBody, fontWeight = "bold", color = "primary" }),
				}),
				ui.label({
					text = text,
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
					flexGrow = 1,
				}),
			})
		)
	end
	return rows
end

local function section_title(text)
	return ui.label({
		text = text,
		fontSize = theme.fontHeading,
		fontWeight = "bold",
		color = "on_surface_variant",
	})
end

-- ── Browsers ─────────────────────────────────────────────────────────────────
-- A launchpad of tiles. Installed ones light up on hover, the one being used
-- shows a spinner, missing ones stay flat and dim.

local function build_browser_cells()
	local cells = {}
	for _, b in ipairs(BROWSERS) do
		local key = "browser-btn-" .. b.id
		local is_avail = state.data.available[b.id]
		local is_current = (state.data.extracting and state.data.browser == b.id)
		local is_hovered = (state.view.hover_key.card == key)

		local glyph, label_color = b.icon, "on_surface"
		local fill, border = "surface_variant/0.3", "outline"
		local click = function()
			if state.data.browser == b.id and state.data.status_text:find("Opened") then
				request("extract", { browser = b.id })
			else
				request("open_login", { browser = b.id })
			end
		end

		if is_current then
			glyph, label_color = "loader", "primary"
			fill, border = "primary/0.1", "primary"
			click = function()
				request("extract", { browser = b.id })
			end
		elseif not is_avail then
			label_color = "on_surface_variant/0.45"
			fill, border = "surface_variant/0.12", "outline/0.3"
			click = nil
		elseif is_hovered then
			label_color, fill, border = "primary", "primary/0.1", "primary/0.5"
		end

		table.insert(
			cells,
			ui.row({
				key = key,
				gap = 10,
				align = "center",
				justify = "center",
				paddingV = 14,
				paddingH = 12,
				borderWidth = 1,
				border = border,
				fill = fill,
				flexGrow = 1,
				radius = theme.radius,
				onClick = click,
				onHover = is_avail and "onCardHover" or nil,
			}, {
				ui.glyph({ name = glyph, size = 20, color = label_color }),
				ui.label({ text = b.label, fontSize = theme.fontTitle, color = label_color }),
			})
		)
	end
	return cells
end

local function build_browser_grid()
	local rows = {}
	for _, row in ipairs(common.chunk_rows(build_browser_cells(), 3, "browser-grid", 12)) do
		table.insert(rows, row)
	end
	return rows
end

-- ── Health ───────────────────────────────────────────────────────────────────
-- A spec sheet: name on the left, version or failure reason on the right.
-- Returns nil until the first check has run.

local function health_fill()
	local h = state.data.health
	if type(h) ~= "table" or next(h) == nil then
		return nil
	end

	local rows, bad = {}, 0
	for _, name in ipairs(DEP_ORDER) do
		local dep = h[name]
		if dep then
			local label = DEP_LABEL[name] or name
			local status = dep.status or "missing"
			local glyph, color, meta

			if status == "missing" then
				glyph, color = "x", "error"
				meta = DEP_IMPACT[name] or "not found"
				bad = bad + 1
			elseif status == "warn" then
				glyph, color = "alert-triangle", "error"
				meta = tostring(dep.detail or "")
				bad = bad + 1
			else
				glyph, color = "check", "primary"
				local ver = short_ver(name, dep.detail)
				meta = ver ~= "" and ver or "ok"
			end

			table.insert(
				rows,
				ui.row(
					{ key = "health-row-" .. name, gap = 10, align = "center", padding = 6, radius = theme.radius },
					{
						ui.glyph({ name = glyph, size = 16, color = color }),
						ui.label({ text = label, fontSize = theme.fontTitle, color = "on_surface", flexGrow = 1 }),
						ui.label({ text = meta, fontSize = theme.fontBody, color = "on_surface_variant" }),
					}
				)
			)
		end
	end

	if #rows == 0 then
		return nil
	end
	return rows, bad
end

local function refresh_button()
	local checking = state.data.checking_health == true
	return ui.button({
		key = "btn-health-refresh",
		glyph = checking and "loader" or "refresh",
		variant = "ghost",
		controlSize = "sm",
		tooltip = checking and "Checking dependencies..." or "Re-check dependencies",
		onClick = checking and nil or function()
			request("refresh_health")
		end,
	})
end

local function health_card(rows)
	return ui.column({
		key = "health-card",
		gap = 2,
		padding = 10,
		borderWidth = 1,
		border = "outline/0.3",
		fill = "surface_variant/0.2",
		radius = theme.radius,
	}, rows)
end

-- `heading` names the block when it is embedded in another page ("HEALTH
-- CHECK"); omitted, it reports its own verdict as the summary for the Health
-- tab. Returns nil until the first check has run.
local function build_health_block(heading)
	local rows, bad = health_fill()
	if not rows then
		return nil
	end

	local left = heading
	if not left then
		left = bad == 0 and ("All " .. #rows .. " dependencies ready")
			or (bad .. " of " .. #rows .. " dependencies need attention")
	end

	return {
		ui.row({ key = "health-head", align = "center", justify = "space_between", radius = theme.radius }, {
			ui.label({ text = left, fontSize = theme.fontHeading, fontWeight = "bold", color = "on_surface_variant" }),
			refresh_button(),
		}),
		health_card(rows),
	}
end

-- Health tab. Unlike the inline section this always renders: while the first
-- check is still running it shows the spinner instead of an empty tab.
local function build_health_page()
	local block = build_health_block(nil)
	if block then
		return block
	end
	return {
		ui.row({ key = "health-head", align = "center", justify = "space_between", radius = theme.radius }, {
			ui.label({
				text = "Checking dependencies...",
				fontSize = theme.fontHeading,
				fontWeight = "bold",
				color = "on_surface_variant",
			}),
			refresh_button(),
		}),
	}
end

local function spacer(height)
	return ui.row({ key = "spacer-auth-" .. tostring(height), height = height, borderWidth = 0, radius = theme.radius })
end

-- ── Pages ────────────────────────────────────────────────────────────────────

local function build_cookies_page()
	local page = {}

	table.insert(page, build_status_card())
	table.insert(page, spacer(16))
	table.insert(page, section_title("LOG IN & EXTRACT"))
	table.insert(page, spacer(10))
	for _, item in ipairs(build_steps()) do
		table.insert(page, item)
	end
	table.insert(page, spacer(16))
	table.insert(page, section_title("CHOOSE A BROWSER"))
	table.insert(page, spacer(10))
	for _, item in ipairs(build_browser_grid()) do
		table.insert(page, item)
	end

	return page
end

local function build_signin_prompt()
	local hero = ui.column({ key = "signin-hero", gap = 4, align = "center", radius = theme.radius }, {
		ui.glyph({ name = "brand-youtube-filled", size = 44, color = "primary" }),
		ui.label({ text = "YouTube Music", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
		ui.label({
			text = "Sign in once to browse, search and play from your own account.",
			fontSize = theme.fontTitle,
			color = "on_surface_variant",
		}),
	})

	-- Full width, otherwise the grid and the health block shrink to their
	-- content inside the centred hero.
	local body = {
		ui.column(
			{ key = "cookie-steps", gap = 10, align = "start", width = "fill", radius = theme.radius },
			build_steps()
		),
	}
	for _, item in ipairs(build_browser_grid()) do
		table.insert(body, item)
	end

	local health = build_health_block("HEALTH CHECK")
	if health then
		for _, item in ipairs(health) do
			table.insert(body, item)
		end
	end

	return ui.column({
		key = "signin-prompt",
		align = "center",
		justify = "center",
		gap = 18,
		padding = 24,
		flexGrow = 1,
		radius = theme.radius,
	}, {
		hero,
		ui.column({ key = "signin-body", gap = 18, width = "fill", radius = theme.radius }, body),
	})
end

return {
	build_signin_prompt = build_signin_prompt,
	build_cookies_page = build_cookies_page,
	build_health_page = build_health_page,
}
