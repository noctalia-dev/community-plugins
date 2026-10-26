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
