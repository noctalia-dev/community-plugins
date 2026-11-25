--!nonstrict
-- ui_onboarding.luau
-- First-run onboarding card when no Todoist API token is configured.
local theme = require("./theme.luau")

local M = {}

function M.card(props)
	return ui.scroll({ flexGrow = 1, fill = true }, {
		ui.column({
			gap = 12,
			fill = true,
			padding = 16,
			radius = 10,
			background = "surface_container_low",
		}, {
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "sparkles", size = 20, color = "primary" }),
				ui.label({
					text = noctalia.tr("ui.panel.onboarding.welcome_title"),
					fontSize = 15,
					fontWeight = "bold",
					color = "primary",
				}),
			}),
			ui.label({
				text = noctalia.tr("ui.panel.onboarding.welcome_desc"),
				fontSize = 12,
				color = theme.MUTED,
				maxLines = 3,
				wrap = true,
			}),
			ui.label({
				text = noctalia.tr("ui.panel.not_configured"),
				fontSize = 12,
				color = theme.DANGER,
				fontWeight = "bold",
				maxLines = 2,
			}),
			ui.separator({}),
			ui.column({ gap = 6 }, {
				ui.label({
					text = noctalia.tr("ui.panel.onboarding.step1_title"),
					fontWeight = "bold",
					fontSize = 12,
				}),
				ui.label({
					text = noctalia.tr("ui.panel.onboarding.step1_desc"),
					fontSize = 11,
					color = theme.MUTED,
					wrap = true,
				}),
				ui.button({
					text = noctalia.tr("ui.panel.onboarding.step1_btn"),
					glyph = "external-link",
					variant = "secondary",
					controlSize = "sm",
					onClick = function()
						if props and props.openUrl then
							props.openUrl("https://app.todoist.com/app/settings/integrations/developer")
						end
					end,
				}),
			}),
			ui.column({ gap = 6 }, {
				ui.label({
					text = noctalia.tr("ui.panel.onboarding.step2_title"),
					fontWeight = "bold",
					fontSize = 12,
				}),
				ui.label({
					text = noctalia.tr("ui.panel.onboarding.step2_desc"),
					fontSize = 11,
					color = theme.MUTED,
					wrap = true,
				}),
				ui.button({
					text = noctalia.tr("ui.panel.onboarding.step2_btn"),
					glyph = "settings",
					variant = "primary",
					controlSize = "sm",
					onClick = function()
						noctalia.openSettings()
					end,
				}),
			}),
		}),
	})
end

return M
