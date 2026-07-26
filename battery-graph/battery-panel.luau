graph_time = 3600 * 24

local cmd = "gdbus call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower/devices/battery_BAT0 --method org.freedesktop.UPower.Device.GetHistory charge " .. graph_time .. " 1000"

function update()
  noctalia.setUpdateInterval(10 * 1000)
  noctalia.runAsync(cmd, parse)
  end

function parse(result)
	local points = {}
	for tuple in result.stdout:gmatch("%(([^%)]+)%)") do
		local fields = {}
		for field in tuple:gmatch("[^,]+") do
			field = field:match("^%s*(.-)%s*$") -- trim whitespace
			field = field:gsub("^%S+%s+", "") -- strip "uint32 " style prefix (only if followed by more content)
			table.insert(fields, field)
		end
		local ts, value = tonumber(fields[1]), tonumber(fields[2])
		if value ~= 0.0 then
			points[ts] = value
		end
	end


    local interpolated_points = interpolate(points, 60)
    render(table.concat(interpolated_points, " "), interpolated_points)
end

function interpolate(points, interpol_time)
	local interpolated_points = {}

	local tkeys = {}
	for k in pairs(points) do
		table.insert(tkeys, k)
	end
	table.sort(tkeys)
	-- use the keys to retrieve the values in the sorted order
	local prev_sample = 1
	local first_sample_time = tkeys[1]
	table.insert(interpolated_points, tonumber(points[tkeys[1]])/100)
	local time_done = 0
	while time_done < graph_time do
		local cur_time = time_done + first_sample_time
		if tkeys[prev_sample + 1] and cur_time > tkeys[prev_sample + 1] then
			prev_sample += 1
		end

		table.insert(interpolated_points, tonumber(points[tkeys[prev_sample]])/100)
		time_done += interpol_time
	end
    return interpolated_points
end


function render(point_str,points)
  panel.render(ui.column({ gap = 8, align = "stretch" }, {
        ui.label({ text = "Battery rate", fontWeight = "bold" }),
        -- ui.label({ text = point_str, fontWeight = "bold" }),
        ui.graph({
            values = points,
            color = "primary",
            lineWidth = 2,
            fillOpacity = 0.15,
            width = 200,             
            height = 80,
        }),
    }))
end

