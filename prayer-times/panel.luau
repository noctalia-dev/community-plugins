--!nonstrict
-- Panel listing today's prayer times with a live countdown.

local prayers = {}
local tomorrowFajr = nil
local sunrise = ""
local hijri = ""
local gregorian = ""
local location = ""
local errorMsg = ""
local hasData = false
local isJumuah = false

local ICONS = {
	Fajr = "moon-stars",
	Sunrise = "sunrise",
	Dhuhr = "sun-high",
	Asr = "sun-low",
	Maghrib = "sunset",
	Isha = "moon",
}

local function nowSeconds()
	local t = os.date("*t")
	return t.hour * 3600 + t.min * 60 + t.sec
end

local function formatCountdown(secs)
	if secs < 0 then
		secs = 0
	end
	local h = math.floor(secs / 3600)
	local m = math.floor((secs % 3600) / 60)
	local s = secs % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	if m > 0 then
		return string.format("%d:%02d", m, s)
	end
	return string.format("%ds", s)
end

local function prayerName(id)
	if id == "Dhuhr" and isJumuah then
		return noctalia.tr("prayer.jumuah")
	end
	return noctalia.tr("prayer." .. string.lower(id))
end

local function findNext()
	if #prayers == 0 then
		return nil, nil
	end
	local now = nowSeconds()
	for _, p in ipairs(prayers) do
		if p.seconds > now then
			return p, p.seconds - now
		end
	end
	if tomorrowFajr then
		return { id = "Fajr", time = prayers[1] and prayers[1].time or "?", seconds = tomorrowFajr },
			(86400 - now) + tomorrowFajr
	end
	return nil, nil
end

local function seedFromState()
	local p = noctalia.state.get("prayers")
	if type(p) == "table" then
		prayers = p
		hasData = #p > 0
	end
	local tf = noctalia.state.get("tomorrowFajr")
	if tf then
		tomorrowFajr = tonumber(tf)
	end
	local sr = noctalia.state.get("sunrise")
	if type(sr) == "string" then
		sunrise = sr
	end
	local hd = noctalia.state.get("hijri")
	if type(hd) == "string" then
		hijri = hd
	end
	local gd = noctalia.state.get("gregorian")
	if type(gd) == "string" then
		gregorian = gd
	end
	local loc = noctalia.state.get("location")
	if type(loc) == "string" then
		location = loc
	end
	local jm = noctalia.state.get("isJumuah")
	if jm ~= nil then
		isJumuah = jm == true
	end
	local err = noctalia.state.get("error")
	if type(err) == "string" then
		errorMsg = err
	end
end

local function render()
	local nextPrayer, remaining = findNext()

	local header = ui.row({ align = "center", justify = "space_between" }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "building-mosque", size = 18, color = "primary" }),
			ui.label({
				text = noctalia.tr("panel.title"),
				fontSize = 15,
				fontWeight = "semibold",
				color = "on_surface",
			}),
		}),
		ui.row({ align = "center", gap = 4 }, {
			ui.button({
				glyph = "settings",
				variant = "ghost",
				tooltip = noctalia.tr("panel.settings"),
				onClick = "onSettings",
			}),
			ui.button({
				glyph = "refresh",
				variant = "ghost",
				tooltip = noctalia.tr("panel.refresh"),
				onClick = "onRefresh",
			}),
			ui.button({ glyph = "x", variant = "ghost", onClick = "onClose" }),
		}),
	})

	local meta = {}
	if location ~= "" then
		meta[#meta + 1] = ui.label({
			text = noctalia.tr("panel.location") .. ": " .. location,
			fontSize = 11,
			color = "on_surface_variant",
		})
	end
	if gregorian ~= "" or hijri ~= "" then
		local dateText = gregorian
		if hijri ~= "" then
			dateText = (dateText ~= "" and (dateText .. " · ") or "") .. hijri
		end
		meta[#meta + 1] = ui.label({ text = dateText, fontSize = 11, color = "on_surface_variant" })
	end

	local banner
	if nextPrayer and remaining ~= nil then
		local name = prayerName(nextPrayer.id)
		if remaining <= 60 then
			banner = ui.column({ align = "center", gap = 4, paddingV = 6 }, {
				ui.label({
					text = name .. " — " .. noctalia.tr("panel.now"),
					fontSize = 16,
					fontWeight = "bold",
					color = "primary",
				}),
			})
		else
			banner = ui.column({ align = "center", gap = 2, paddingV = 4 }, {
				ui.label({
					text = noctalia.tr("panel.next") .. ": " .. name,
					fontSize = 11,
					color = "on_surface_variant",
				}),
				ui.label({
					text = formatCountdown(remaining),
					fontSize = 24,
					fontWeight = "bold",
					color = "primary",
				}),
				ui.label({
					text = noctalia.tr("panel.in"),
					fontSize = 11,
					color = "on_surface_variant",
				}),
			})
		end
	elseif not hasData then
		banner = ui.column({ align = "center", paddingV = 8 }, {
			ui.label({
				text = errorMsg ~= "" and errorMsg or noctalia.tr("panel.loading"),
				fontSize = 13,
				color = errorMsg ~= "" and "error" or "on_surface_variant",
			}),
		})
	end

	local rows = {}
	for _, p in ipairs(prayers) do
		local isNext = nextPrayer and p.id == nextPrayer.id
		local color = isNext and "primary" or "on_surface"
		local timeColor = isNext and "primary" or "on_surface_variant"
		local weight = isNext and "semibold" or "normal"

		rows[#rows + 1] = ui.row({
			key = p.id,
			align = "center",
			justify = "space_between",
			paddingH = 12,
			paddingV = isNext and 10 or 8,
			fill = isNext and "surface_container" or nil,
			radius = isNext and 10 or nil,
		}, {
			ui.row({ align = "center", gap = 10 }, {
				ui.glyph({ name = ICONS[p.id] or "moon", size = 14, color = color }),
				ui.label({
					text = prayerName(p.id),
					fontSize = 13,
					fontWeight = weight,
					color = color,
				}),
			}),
			ui.label({ text = p.time, fontSize = 13, fontWeight = weight, color = timeColor }),
		})

		if p.id == "Fajr" and sunrise ~= "" then
			rows[#rows + 1] = ui.row({
				key = "Sunrise",
				align = "center",
				justify = "space_between",
				paddingH = 12,
				paddingV = 8,
			}, {
				ui.row({ align = "center", gap = 10 }, {
					ui.glyph({ name = "sunrise", size = 14, color = "on_surface_variant" }),
					ui.label({
						text = noctalia.tr("prayer.sunrise"),
						fontSize = 13,
						color = "on_surface_variant",
					}),
				}),
				ui.label({ text = sunrise, fontSize = 13, color = "on_surface_variant" }),
			})
		end
	end

	local children = { header }
	if #meta > 0 then
		children[#children + 1] = ui.column({ gap = 2 }, meta)
	end
	children[#children + 1] = ui.separator({ spacing = 2, color = "outline_variant", opacity = 0.2 })
	if banner then
		children[#children + 1] = banner
	end
	if #rows > 0 then
		children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 2, align = "stretch" }, {
			ui.column({ gap = 2 }, rows),
		})
	end

	panel.render(ui.column({ flexGrow = 1, gap = 8 }, children))
end

noctalia.state.watch("prayers", function(val)
	if type(val) == "table" then
		prayers = val
		hasData = #val > 0
	end
	render()
end)
noctalia.state.watch("tomorrowFajr", function(val)
	tomorrowFajr = tonumber(val)
	render()
end)
noctalia.state.watch("sunrise", function(val)
	if type(val) == "string" then
		sunrise = val
	end
	render()
end)
noctalia.state.watch("hijri", function(val)
	if type(val) == "string" then
		hijri = val
	end
	render()
end)
noctalia.state.watch("gregorian", function(val)
	if type(val) == "string" then
		gregorian = val
	end
	render()
end)
noctalia.state.watch("location", function(val)
	if type(val) == "string" then
		location = val
	end
	render()
end)
noctalia.state.watch("isJumuah", function(val)
	isJumuah = val == true
	render()
end)
noctalia.state.watch("error", function(val)
	if type(val) == "string" then
		errorMsg = val
	end
	if not hasData then
		render()
	end
end)

function onOpen(_context)
	if panel.setWantsSecondTicks then
		panel.setWantsSecondTicks(true)
	end
	seedFromState()
	render()
end

function onClose()
	panel.close()
end

function onSettings()
	panel.close()
	noctalia.openSettings()
end

function onRefresh()
	noctalia.state.set("command", { action = "refresh" })
	-- Also poke the service via IPC for reliability
	noctalia.runAsync("noctalia msg plugin bekiryildirimcode/prayer-times:fetcher all refresh")
end

function update()
	if hasData then
		render()
	end
end
