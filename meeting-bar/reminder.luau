--!nonstrict
local common = require("./common.luau")

local function dismiss(kind)
	noctalia.state.set("reminderAction", { kind = kind, nonce = noctalia.nowMs() })
end

function update()
	local event = noctalia.state.get("reminder")
	if not event then
		return
	end
	layer.render(
		ui.column(
			{ fill = "surface/0.97", flexGrow = 1, align = "center", justify = "center", gap = 24, padding = 32 },
			{
				ui.glyph({ name = "video", size = 56, color = "primary" }),
				ui.label({ text = common.model.relative(event, noctalia.nowMs()), fontSize = 24, color = "primary" }),
				ui.label({
					text = common.model.clean(event.title),
					fontSize = 36,
					fontWeight = "bold",
					maxWidth = 800,
					maxLines = 3,
					textAlign = "center",
				}),
				ui.label({
					text = common.time(event.startMs)
						.. "–"
						.. common.time(event.endMs)
						.. " · "
						.. common.model.clean(event.calendarName),
					fontSize = 18,
				}),
				ui.row({ gap = 16 }, {
					ui.button({
						text = "Join meeting",
						glyph = "video",
						variant = "primary",
						onClick = function()
							if common.openLink(event.url) then
								dismiss("dismiss")
							end
						end,
					}),
					ui.button({
						text = "Snooze " .. tostring(noctalia.getConfig("snooze_minutes")) .. " min",
						onClick = function()
							dismiss("snooze")
						end,
					}),
					ui.button({
						text = "Dismiss",
						onClick = function()
							dismiss("dismiss")
						end,
					}),
				}),
			}
		)
	)
end

noctalia.setUpdateInterval(1000)
noctalia.state.watch("reminder", function()
	update()
end)
