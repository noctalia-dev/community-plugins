--!nonstrict

local function makeRow(id, title, subtitle, icon)
	return {
		id = id or "",
		title = title,
		subtitle = subtitle or "Unknown",
		icon = icon,
		glyph = (icon and nil) or "book",
	}
end

local function showResults(query, books)
	local results = {}
	for i, book in ipairs(books) do
		results[i] = makeRow(book["formats"][1], book["title"], book["authors"], book["cover"])
	end
	launcher.setResults(query, results)
end

-- Remove the `Initialized urlfixer` string that
-- can occurs before or after the json
local function trim(output: string)
	output = output:gsub("^Initialized urlfixer", "")
	output = output:gsub("Initialized urlfixer$", "")
	return noctalia.string.trim(output)
end

function onQuery(query: string)
	local filter = noctalia.string.trim(query)
	local search_cmd = {
		"calibredb",
		"list",
		"--for-machine",
		"--search",
		filter,
		"--fields",
		"title,authors,formats,cover",
	}

	noctalia.runAsync(search_cmd, function(result)
		if result.exitCode ~= 0 then
			noctalia.log(result.stderr)
			return
		end

		local output = trim(result.stdout)
		local books, err = noctalia.json.decode(output)

		if err ~= nil then
			noctalia.log(err)
			return
		end

		showResults(query, books)
	end)
end

function onActivate(id)
	noctalia.runAsync({ "xdg-open", id })
end
