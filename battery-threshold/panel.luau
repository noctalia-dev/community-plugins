--!nonstrict
local is_open = false

local function render_panel()
	if not is_open then
		return
	end

	local is_available = noctalia.state.get("is_available") == true
	local is_writable = noctalia.state.get("is_writable") == true
	local threshold = noctalia.state.get("current_threshold") or 0
	local model_name = noctalia.state.get("battery_model_name") or ""

	local title_text = noctalia.tr("panel.title")
	local sub_text = ""
	if not is_available then
		sub_text = noctalia.tr("panel.not-available")
	else
		sub_text = model_name
	end

	local hint_text = ""
	local hint_color = "on_surface_variant"
	if not is_writable then
		hint_text = noctalia.tr("panel.read-only")
		hint_color = "error"
	else
		hint_text = noctalia.tr("panel.adjust-limit")
	end

	local children = {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.column({ gap = 2 }, {
				ui.label({ text = title_text, fontSize = 16, fontWeight = "bold", color = "primary" }),
				ui.label({ text = sub_text, fontSize = 12, color = "on_surface_variant" }),
			}),
			ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
		}),
	}

	if is_available then
		table.insert(children, ui.separator({ thickness = 1, color = "outline/0.3", spacing = 8 }))

		if is_writable then
			table.insert(
				children,
				ui.column({ gap = 8 }, {
					ui.row({ align = "center", justify = "space_between" }, {
						ui.label({ text = noctalia.tr("panel.title"), fontSize = 14, color = "on_surface" }),
						ui.label({
							text = tostring(threshold) .. "%",
							fontSize = 16,
							fontWeight = "bold",
							color = "primary",
						}),
					}),
					ui.row({ align = "center", gap = 8 }, {
						ui.label({ text = "40%", fontSize = 11, color = "on_surface_variant" }),
						ui.slider({
							min = 40,
							max = 100,
							step = 5,
							value = threshold,
							enabled = is_writable,
							onChange = "onSliderChange",
						}),
						ui.label({ text = "100%", fontSize = 11, color = "on_surface_variant" }),
					}),
					ui.label({ text = hint_text, fontSize = 11, color = hint_color, textAlign = "center" }),
				})
			)
		else
			table.insert(
				children,
				ui.column({ gap = 12, align = "center" }, {
					ui.label({ text = hint_text, fontSize = 12, color = "error", textAlign = "center", maxLines = 2 }),
					ui.button({
						text = "Configure Permissions",
						glyph = "shield-lock",
						variant = "primary",
						onClick = "onRunSetup",
					}),
				})
			)
		end
	end

	panel.render(ui.column({ gap = 12, padding = 12 }, children))
end

function onOpen(context: string?)
	is_open = true
	render_panel()
end

function onClose()
	is_open = false
end

function onSliderChange(value: string)
	local num = tonumber(value)
	if num then
		noctalia.state.set("set_threshold_request", num)
		noctalia.state.set("current_threshold", num)
		render_panel()
	end
end

function onCloseClicked()
	panel.close()
end

function onRunSetup()
	noctalia.state.set("run_setup_request", true)
end

noctalia.state.watch("current_threshold", function()
	if is_open then
		render_panel()
	end
end)

noctalia.state.watch("is_writable", function()
	if is_open then
		render_panel()
	end
end)

noctalia.state.watch("is_available", function()
	if is_open then
		render_panel()
	end
end)
