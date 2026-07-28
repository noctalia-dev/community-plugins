graph_time = 3600 * noctalia.getConfig("graph_time")
battery_path = noctalia.getConfig("battery_path")
interpol_time = 60 * noctalia.getConfig("interpol_time")

local function validate(s)
	if s:match("^/org/freedesktop/UPower/devices/[%a%d_]+$") ~= nil then
        return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
	else
		noctalia.log("Invalid battery dbus path. Check that it is correct")
	end
end


local cmd = table.concat({"gdbus call --system --dest org.freedesktop.UPower --object-path",validate(battery_path),"--method org.freedesktop.UPower.Device.GetHistory charge",graph_time, "1000"}, " ")

function update()
  noctalia.setUpdateInterval(interpol_time * 1000)
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

    local interpolated_points = interpolate(points)
    render(table.concat(interpolated_points, " "), interpolated_points)
end

function interpolate(points )
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
	while tkeys[prev_sample + 1] and time_done < graph_time do
		local cur_time = time_done + first_sample_time
		if  cur_time > tkeys[prev_sample + 1] then
			prev_sample += 1
		end

		table.insert(interpolated_points, tonumber(points[tkeys[prev_sample]])/100)
		time_done += interpol_time
	end
    return interpolated_points
end


function render(point_str,points)
  panel.render(ui.column({ gap = 8, radius = 8, align = "stretch", fill = "surface_variant" }, {
	  ui.row( {paddingH= 10, paddingV = 6},{		ui.label({text = noctalia.tr("text.graph_name"), fontSize = 24, fontWeight = "heavy", textAlign = "center"}),}),
        ui.graph({
            values = points,
            color = "primary",
            lineWidth = 2,
            fillOpacity = 0.45,
            height = 200,
			width = 400
        }),
    }))
end

