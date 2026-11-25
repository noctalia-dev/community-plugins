local M = {}

M.PANEL_ID = "dunarand/bookmarks:panel"
M.STATE_OPEN = "bookmarks_open"

-- Coerces native booleans, string coercions, and UI event objects into a
-- strict boolean, as required by ui.toggle's `checked` prop.
function M.parseBool(val)
	if type(val) == "table" then
		return val.checked == true or val.value == true
	end
	return val == true or val == "true" or val == 1
end

-- Distinguishes folders from bookmarks.
function M.entryType(entry)
	return (type(entry) == "table" and entry.type == "folder") and "folder" or "bookmark"
end

-- Prefer the user-configured data_path setting; fall back to the plugin's
-- own persistent data directory when unset.
function M.resolveDataPath()
	local configured = noctalia.getConfig("data_path")
	if type(configured) == "string" and noctalia.string.trim(configured) ~= "" then
		return noctalia.expandPath(noctalia.string.trim(configured)), nil
	end

	local dataDir, dataDirErr = noctalia.pluginDataDir()
	if dataDir == nil then
		return nil, dataDirErr
	end
	return dataDir .. "/data.json", nil
end

-- Reads and decodes data.json, returning (data, errorMsg).
-- Returns an empty table and nil error when the file does not exist yet.
function M.loadBookmarks()
	local path, pathErr = M.resolveDataPath()
	if path == nil then
		return {}, tostring(pathErr)
	end
	if not noctalia.fileExists(path) then
		return {}, nil
	end
	local raw, readErr = noctalia.readFile(path)
	if raw == nil then
		return {}, noctalia.tr("err.read_failed", { error = tostring(readErr) })
	end
	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		return {}, noctalia.tr("err.corrupt", { error = tostring(decodeErr) })
	end
	return decoded, nil
end

-- Encodes and writes the bookmarks array to data.json, returning (ok, errorMsg).
function M.saveBookmarks(bookmarks)
	local path, pathErr = M.resolveDataPath()
	if path == nil then
		return false, tostring(pathErr or noctalia.tr("err.no_data_dir"))
	end
	local encoded, encodeErr = noctalia.json.encode(bookmarks)
	if encoded == nil then
		return false, tostring(encodeErr)
	end
	local ok, writeErr = noctalia.writeFile(path, encoded)
	if not ok then
		return false, tostring(writeErr)
	end
	return true, nil
end

-- Flat list of { entry, path } across root and one level of folders,
-- bookmarks only (folders themselves aren't launchable results).
function M.flatten(bookmarks)
	local flat = {}
	if type(bookmarks) ~= "table" then
		return flat
	end
	for _, entry in ipairs(bookmarks) do
		if M.entryType(entry) == "folder" then
			for _, subEntry in ipairs(entry.items or {}) do
				if M.entryType(subEntry) ~= "folder" then
					table.insert(flat, { entry = subEntry, path = entry.label or "" })
				end
			end
		else
			table.insert(flat, { entry = entry, path = nil })
		end
	end
	return flat
end

local function scoreField(token, text, weight)
	if text == "" then
		return nil
	end
	local s = noctalia.fuzzyScore(token, text)
	return s ~= nil and (s * weight) or nil
end

local function scoreItem(tokens, item)
	local label = item.entry.label or ""
	local desc = noctalia.string.trim(item.entry.description or "")
	local folder = noctalia.string.trim(item.path or "")

	local total = 0
	for _, token in ipairs(tokens) do
		local best = scoreField(token, label, 1.0)
		local descScore = scoreField(token, desc, 0.7)
		if descScore ~= nil then
			best = (best == nil) and descScore or math.max(best, descScore)
		end
		local folderScore = scoreField(token, folder, 0.5)
		if folderScore ~= nil then
			best = (best == nil) and folderScore or math.max(best, folderScore)
		end
		if best == nil then
			return nil
		end
		total = total + best
	end
	return total / #tokens
end

-- Fuzzy-searches bookmark labels, descriptions, and folder names across root
-- and one level of folders, using Noctalia's native matcher. Space-separated
-- tokens are matched independently (AND semantics, order-independent, and
-- able to span fields). Description-only (0.7) and folder-only (0.5) matches
-- are weighted below label matches. When query is empty, returns all
-- flattened bookmarks with score = 0.
function M.searchBookmarks(bookmarks, query)
	local trimmed = noctalia.string.trim(query or "")
	local flat = M.flatten(bookmarks)
	local results = {}

	local tokens = {}
	if trimmed ~= "" then
		for token in trimmed:gmatch("%S+") do
			table.insert(tokens, token)
		end
	end

	for _, item in ipairs(flat) do
		if #tokens == 0 then
			table.insert(results, { entry = item.entry, path = item.path, score = 0 })
		else
			local score = scoreItem(tokens, item)
			if score ~= nil then
				table.insert(results, { entry = item.entry, path = item.path, score = score })
			end
		end
	end

	if #tokens > 0 then
		table.sort(results, function(a, b)
			return a.score > b.score
		end)
	end

	return results
end

-- Executes a bookmark command respecting runInTerminal and runInBackground.
function M.runBookmark(entry)
	if type(entry) ~= "table" then
		return false
	end
	local cmd = entry.cmd
	if type(cmd) ~= "string" or cmd == "" then
		noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err.no_command"))
		return false
	end
	local label = entry.label or cmd

	local ok
	if M.parseBool(entry.runInTerminal) then
		ok = noctalia.runInTerminal(cmd)
	elseif M.parseBool(entry.runInBackground) then
		ok = noctalia.runAsync(cmd)
	else
		ok = noctalia.runAsync(cmd, function(result)
			if result.exitCode ~= 0 then
				local detail = noctalia.string.trim(result.stderr or "")
				local msg = noctalia.tr(
					"err.exit_code",
					{ label = label, code = tostring(result.exitCode) }
				)
				if detail ~= "" then
					msg = msg .. ": " .. detail
				end
				noctalia.notifyError(noctalia.tr("title"), msg)
			end
		end)
	end

	if not ok then
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err.launch_failed", { label = label })
		)
		return false
	end
	return true
end

return M
