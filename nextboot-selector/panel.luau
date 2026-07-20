function tr(key)
	return noctalia.tr(key)
end

function cfg(key)
	return noctalia.getConfig(key)
end

local env = getfenv()
local excludedKeywords = cfg("excluded_keywords")
local privilegeCmd = cfg("privilege_command")
local closeOnSelect = cfg("close_on_select")
local rebootOnSelect = cfg("reboot_on_select")
local rebootCmd = cfg("reboot_command")

function parseEntries(output)
	local entries = {}

	local bootNext = output:match("BootNext:%s*(%x+)")
	local bootCurrent = output:match("BootCurrent:%s*(%x+)")

	local selectedId = bootNext or bootCurrent
	if selectedId then
		selectedId = selectedId:upper()
	end

	for line in output:gmatch("[^\r\n]+") do
		local id, active, name = line:match("^Boot(%x%x%x%x)(%*?)%s+([^\t]+)")
		if id then
			id = id:upper()
			table.insert(entries, {
				id = id,
				name = name,
				isActive = active == "*",
				isSelected = selectedId ~= nil and id == selectedId,
			})
		end
	end

	return entries
end

function excludeEntries(entries, keywords)
	local filtered = {}
	for _, entry in ipairs(entries) do
		local haystack = entry.name:lower()
		local excluded = false
		for _, word in ipairs(keywords) do
			if haystack:find(word:lower(), 1, true) then
				excluded = true
				break
			end
		end
		if not excluded then
			table.insert(filtered, entry)
		end
	end
	return filtered
end

function resetBootNext()
	noctalia.runAsync(`{privilegeCmd} efibootmgr --delete-bootnext`, function(result)
		load()
	end, 5000)
end

function render(entries)
	local entriesButton = {}
	for i, entry in ipairs(entries) do
		local callBackFn = `setBootNext_{entry.id}`
		env[callBackFn] = function()
			noctalia.runAsync(`{privilegeCmd} efibootmgr --bootnext {entry.id}`, function(result)
				if not result.timedOut then
					if result.exitCode == 0 then
						load()

						if rebootOnSelect then
							noctalia.runAsync(rebootCmd)
						end

						if closeOnSelect then
							panel.close()
						end
					else
						noctalia.notify(tr("notification.failed_to_set_next_boot"), result.stderr)
					end
				else
					noctalia.notify(tr("notification.failed_to_set_next_boot"), tr("notification.timed_out"))
				end
			end, 60 * 1000)
		end

		table.insert(
			entriesButton,
			ui.button({
				text = entry.name,
				selected = entry.isSelected,
				enabled = entry.isActive,
				onClick = callBackFn,
				contentAlign = "start",
				glyph = if entry.isSelected then "circle-check" else "circle",
				glyphSize = 18,
			})
		)
	end

	panel.render(ui.column({
		flexGrow = 1,
	}, {
		ui.row({
			justify = "space_between",
			align = "center"
		}, {
			ui.label({
				text = tr("panel.title"),
				fontSize = 16
			}),
			ui.button({
				text = tr("panel.reset"),
				glyph = "reload",
				variant = "ghost",
				controlSize = "sm",
				onClick = "resetBootNext"
			})
		}),
		ui.separator({
			thickness = 2,
			orientation = "horizontal",
			spacing = 8,
		}),
		ui.scroll({
			flexGrow = 1,
			gap = 8,
		}, entriesButton),
	}))
end

function load()
	noctalia.runAsync("efibootmgr", function(result)
		if result.exitCode == 0 then
			local entries = parseEntries(result.stdout)
			render(excludeEntries(entries, excludedKeywords))
		end
	end, 5000)
end

function onOpen()
	load()
end
