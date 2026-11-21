--!nonstrict
-- Panel: the physical disks with their model, current kernel name and stable
-- IDs, so the user can copy an ID into the Disks, Order or Disk colors
-- setting instead of typing it. Plugins cannot write their settings, so the
-- panel copies to the clipboard. The widget's settings are per bar instance,
-- which noctalia.openSettings() does not reach; middle-clicking the widget
-- opens them (a built-in gesture), and the hint says so.

local diskstats = require("./lib/diskstats.luau")

local SYS_BLOCK = "/sys/block"
local names = {}
local ids = {}
-- The disk whose ID was copied last, marked until the next copy or open.
local copiedName = nil

local function tr(key, vars)
	return noctalia.tr("panel." .. key, vars)
end

local function scan()
	local physical
	physical, ids = diskstats.scan(noctalia, SYS_BLOCK)
	-- The same order as the LEDs without a configured order.
	names = diskstats.select({}, physical, {}, ids)
end

local render

local function copy(name)
	local value = diskstats.preferredId(name, ids[name])
	if noctalia.copyToClipboard(value, "text/plain") then
		copiedName = name
	end
	render()
end

-- One line of secondary text, left out when the value is unknown.
local function detail(key, value, rows)
	if value ~= nil then
		rows[#rows + 1] = ui.label({ text = tr(key, { value = value }), color = "on_surface_variant", fontSize = 12 })
	end
end

local function diskRow(name)
	local diskIds = ids[name] or {}
	local _, kind = diskstats.preferredId(name, diskIds)
	local text = {
		ui.label({ text = diskIds.model or name, fontWeight = "medium", color = "on_surface" }),
	}
	-- Without a model the kernel name is already the title.
	if diskIds.model ~= nil then
		detail("name", name, text)
	end
	detail("serial", diskIds.serial, text)
	detail("wwid", diskIds.wwid, text)
	local copied = copiedName == name
	return ui.row({ gap = 12, align = "center" }, {
		ui.column({ gap = 2, flexGrow = 1 }, text),
		ui.button({
			text = copied and tr("copied") or tr("copy"),
			glyph = copied and "check" or "copy",
			controlSize = "sm",
			variant = copied and "primary" or "default",
			tooltip = tr("copy_tooltip." .. kind),
			onClick = function()
				copy(name)
			end,
		}),
	})
end

render = function()
	local header = {
		ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
	}
	if noctalia.getSetting("shell.show_close_buttons") ~= false then
		header[#header + 1] = ui.button({
			glyph = "close",
			onClick = function()
				panel.close()
			end,
		})
	end
	local rows = {}
	for _, name in ipairs(names) do
		rows[#rows + 1] = diskRow(name)
	end
	if #rows == 0 then
		rows[1] = ui.label({ text = tr("no_disks"), color = "on_surface_variant" })
	end
	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, header),
		ui.label({ text = tr("hint"), color = "on_surface_variant", maxLines = 4 }),
		ui.scroll({ flexGrow = 1, gap = 14 }, rows),
	}))
end

function onOpen(_context)
	copiedName = nil
	scan()
	render()
end
