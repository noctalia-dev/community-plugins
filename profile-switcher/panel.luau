--!nonstrict

local profiles = require("./profiles.luau")

local activeProfile = noctalia.state.get("activeProfile")

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function scheduleEnabled(profile)
	return profile.schedule and profile.schedule.enabled ~= false
end

local function scheduleText(profile)
	if not profile.schedule then
		return noctalia.tr("common.manual")
	end

	if profile.schedule.enabled == false then
		return noctalia.tr("common.manual")
	end

	if not profile.schedule.from or not profile.schedule["until"] then
		return noctalia.tr("common.no_schedule")
	end

	return profile.schedule.from .. " - " .. profile.schedule["until"]
end

local function requestActivation(profile)
	noctalia.runAsync({
		"noctalia",
		"msg",
		"plugin",
		"m4sc/profile-switcher:service",
		"all",
		"activate",
		profile.id,
	})
end

local function openEditor(profile)
	noctalia.state.set("editProfileId", profile.id)

	panel.close()

	noctalia.togglePanel("m4sc/profile-switcher:editor")
end

local function createProfile()
	noctalia.state.set("editProfileId", "__new__")

	panel.close()

	noctalia.togglePanel("m4sc/profile-switcher:editor")
end

------------------------------------------------------------
-- Profile card
------------------------------------------------------------

local function profileCard(profile)
	local selected = activeProfile == profile.id

	local automatic = scheduleEnabled(profile)

	return ui.row({
		key = "profile-" .. profile.id,

		gap = 10,

		paddingH = 16,
		paddingV = 13,

		align = "center",

		fill = selected and "primary/0.14" or "surface_variant/0.40",

		radius = 12,

		border = selected and "primary/0.75" or "outline/0.20",

		borderWidth = selected and 1.5 or 1,

		onClick = function()
			requestActivation(profile)
		end,
	}, {
		------------------------------------------------
		-- Profile info
		------------------------------------------------

		ui.column({
			gap = 4,
			flexGrow = 1,
		}, {
			ui.label({
				text = profile.name,

				fontSize = 15,

				fontWeight = selected and "bold" or "semibold",

				color = selected and "primary" or "on_surface",
			}),

			ui.row({
				gap = 6,
				align = "center",
			}, {
				ui.glyph({
					name = automatic and "clock" or "hand-stop",

					size = 13,

					color = "on_surface_variant",
				}),

				ui.label({
					text = scheduleText(profile),

					fontSize = 12,

					color = "on_surface_variant",
				}),
			}),
		}),

		------------------------------------------------
		-- Edit button
		------------------------------------------------

		ui.button({
			glyph = "edit",

			variant = "ghost",

			controlSize = "sm",

			onClick = function()
				openEditor(profile)
			end,
		}),

		------------------------------------------------
		-- Active indicator
		------------------------------------------------

		ui.glyph({
			name = selected and "circle-check-filled" or "chevron-right",

			size = 19,

			color = selected and "primary" or "on_surface_variant",
		}),
	})
end

------------------------------------------------------------
-- Render
------------------------------------------------------------

local function render()
	local loaded = profiles.loadAll()

	local cards = {}

	--------------------------------------------------------
	-- Build profile cards
	--------------------------------------------------------

	for _, profile in ipairs(loaded) do
		table.insert(cards, profileCard(profile))
	end

	--------------------------------------------------------
	-- Empty state
	--------------------------------------------------------

	if #cards == 0 then
		table.insert(
			cards,

			ui.column({
				gap = 6,

				padding = 18,

				align = "center",

				fill = "surface_variant/0.25",

				radius = 12,
			}, {
				ui.label({
					text = noctalia.tr("panel.no_profiles"),

					fontSize = 14,

					fontWeight = "semibold",
				}),

				ui.label({
					text = "~/.config/noctalia/profiles",

					fontSize = 10,

					color = "on_surface_variant",
				}),

				ui.button({
					text = noctalia.tr("panel.create_profile"),

					glyph = "plus",

					variant = "secondary",

					controlSize = "sm",

					onClick = function()
						createProfile()
					end,
				}),
			})
		)
	end

	--------------------------------------------------------
	-- Panel
	--------------------------------------------------------

	panel.render(ui.column({
		height = 370,

		padding = 18,

		gap = 12,
	}, {
		------------------------------------------------
		-- Header
		------------------------------------------------

		ui.row({
			align = "center",

			justify = "space_between",

			gap = 12,
		}, {
			ui.column({
				gap = 2,

				flexGrow = 1,
			}, {
				ui.label({
					text = noctalia.tr("panel.title"),

					fontSize = 18,

					fontWeight = "bold",
				}),

				ui.label({
					text = noctalia.tr("panel.subtitle"),

					fontSize = 11,

					color = "on_surface_variant",
				}),
			}),

			------------------------------------------------
			-- Header actions
			------------------------------------------------

			ui.row({
				gap = 4,

				align = "center",
			}, {
				ui.button({
					glyph = "plus",

					variant = "ghost",

					controlSize = "sm",

					onClick = function()
						createProfile()
					end,
				}),

				ui.button({
					glyph = "x",

					variant = "ghost",

					controlSize = "sm",

					onClick = function()
						panel.close()
					end,
				}),
			}),
		}),

		------------------------------------------------
		-- Active profile
		------------------------------------------------

		ui.row({
			gap = 7,

			align = "center",
		}, {
			ui.glyph({
				name = "circle-filled",

				size = 8,

				color = "primary",
			}),

			ui.label({
				text =
                    activeProfile
                        and noctalia.tr(
                            "panel.active_profile",
                            { name = activeProfile }
                        )
                        or noctalia.tr(
                            "panel.no_active_profile"
                        ),

				fontSize = 12,

				color = "on_surface_variant",
			}),
		}),

		------------------------------------------------
		-- Separator
		------------------------------------------------

		ui.separator({
			spacing = 3,

			color = "outline/0.22",
		}),

		------------------------------------------------
		-- Profile list
		------------------------------------------------

		ui.scroll({
			height = 220,

			gap = 9,

			paddingV = 2,
		}, cards),
	}))
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

function onOpen(_context)
	activeProfile = noctalia.state.get("activeProfile")

	render()
end

noctalia.state.watch("activeProfile", function(value)
	activeProfile = value

	render()
end)
