--!nonstrict
-- ui_help.luau
-- Help & Shortcuts cheat sheet modal/view.
local theme = require("./theme.luau")

local M = {}

local function shortcutRow(keys, desc)
	return ui.row({ gap = 8, align = "center", paddingV = 2 }, {
		ui.row({
			paddingH = 6,
			paddingV = 2,
			radius = 4,
			fill = "surface_container_highest/0.6",
		}, {
			ui.label({ text = keys, fontSize = 11, fontWeight = "bold", color = "primary" }),
		}),
		ui.label({ text = desc, fontSize = 11, color = theme.MUTED, flexGrow = 1, wrap = true }),
	})
end

local function syntaxRow(symbol, desc)
	return ui.row({ gap = 8, align = "center", paddingV = 2 }, {
		ui.row({
			paddingH = 6,
			paddingV = 2,
			radius = 4,
			fill = "surface_container_highest/0.6",
		}, {
			ui.label({ text = symbol, fontSize = 11, fontWeight = "bold" }),
		}),
		ui.label({ text = desc, fontSize = 11, color = theme.MUTED, flexGrow = 1, wrap = true }),
	})
end

function M.view()
	return ui.scroll({ flexGrow = 1, fill = true }, {
		ui.column({ gap = 12, fill = true }, {
			-- Section 1: Keyboard Shortcuts
			ui.column({ gap = 6 }, {
				ui.row({ gap = 6, align = "center" }, {
					ui.glyph({ name = "keyboard", size = 14, color = "primary" }),
					ui.label({
						text = noctalia.tr("ui.panel.help_view.shortcuts_title"),
						fontSize = 12,
						fontWeight = "bold",
					}),
				}),
				shortcutRow("Ctrl + Enter", noctalia.tr("ui.panel.help_view.shortcut_ctrl_enter_desc")),
				shortcutRow("Enter", noctalia.tr("ui.panel.help_view.shortcut_enter_desc")),
				shortcutRow("Esc", noctalia.tr("ui.panel.help_view.shortcut_esc_desc")),
			}),

			ui.separator({}),

			-- Section 2: Quick Add Syntax
			ui.column({ gap = 6 }, {
				ui.row({ gap = 6, align = "center" }, {
					ui.glyph({ name = "sparkles", size = 14, color = "primary" }),
					ui.label({
						text = noctalia.tr("ui.panel.help_view.syntax_title"),
						fontSize = 12,
						fontWeight = "bold",
					}),
				}),
				syntaxRow("#project", noctalia.tr("ui.panel.help_view.syntax_project_desc")),
				syntaxRow("@label", noctalia.tr("ui.panel.help_view.syntax_label_desc")),
				syntaxRow("p1 .. p4", noctalia.tr("ui.panel.help_view.syntax_priority_desc")),
				syntaxRow("today / 5pm / ev fri", noctalia.tr("ui.panel.help_view.syntax_dates_desc")),
				syntaxRow("// note", noctalia.tr("ui.panel.help_view.syntax_desc_desc")),
			}),

			ui.separator({}),

			-- Section 3: Launcher Quick Capture
			ui.column({ gap = 4 }, {
				ui.row({ gap = 6, align = "center" }, {
					ui.glyph({ name = "terminal", size = 14, color = "primary" }),
					ui.label({
						text = noctalia.tr("ui.panel.help_view.launcher_title"),
						fontSize = 12,
						fontWeight = "bold",
					}),
				}),
				ui.label({
					text = noctalia.tr("ui.panel.help_view.launcher_desc"),
					fontSize = 11,
					color = theme.MUTED,
					wrap = true,
				}),
			}),
		}),
	})
end

return M
