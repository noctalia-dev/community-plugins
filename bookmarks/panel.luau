-- Prefer the user-configured data_path setting; fall back to the plugin's
-- own persistent data directory when unset.
local function resolveDataPath()
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

local path, pathErr = resolveDataPath()
if path == nil then
	noctalia.log("bookmarks: could not resolve data path: " .. tostring(pathErr))
end

local view = "list" -- "list" | "new"
local formRev = 0

local bookmarks = {}
local listError = nil

local currentFolder = nil -- nil = root, else index into `bookmarks` of the open folder
local editMode = false -- when true, rows show reorder/edit/delete controls

local searchQuery = ""
local searchRev = 0 -- bumped to reseed the search input on open
local focusSearchOnRender = false -- one-shot: grabs the search input on the next render only

local selectedIndex = nil -- 1-based position within the currently visible list, or nil

local draftKind = "bookmark" -- "bookmark" | "folder", set when the form opens
local draftGlyph = "bookmark"
local draftLabel = ""
local draftCmd = ""
local draftDescription = ""
local draftRunInBackground = false
local draftRunInTerminal = false
local draftError = nil
local editingIndex = nil -- nil = creating new, number = editing the entry at that index in the active list
local editingRoot = false -- true when editingIndex refers to `bookmarks` (root) instead of activeList()

-- Coerces native booleans, string coercions, and UI event objects into a
-- strict boolean, as required by ui.toggle's `checked` prop.
local function parseBool(val)
	if type(val) == "table" then
		return val.checked == true or val.value == true
	end
	return val == true or val == "true" or val == 1
end

-- Returns the array we're currently viewing/editing: root, or the open
-- folder's items. Falls back to root if currentFolder points at something
-- that's gone (e.g. deleted from under us).
local function activeList()
	if currentFolder == nil then
		return bookmarks
	end
	local folder = bookmarks[currentFolder]
	if folder == nil or folder.type ~= "folder" then
		currentFolder = nil
		return bookmarks
	end
	folder.items = folder.items or {}
	return folder.items
end

local function entryType(entry)
	return entry.type == "folder" and "folder" or "bookmark"
end

-- Fuzzy-searches bookmark labels only (not commands, not folder names)
-- across root and every folder's contents, using Noctalia's native
-- matcher. Returns results sorted best-match-first, each as
-- { entry, path, folderIndex, index }, where folderIndex/index locate the
-- entry for running/editing it (folderIndex = nil for root entries).
local function searchBookmarks(query)
	local trimmed = noctalia.string.trim(query)
	if trimmed == "" then
		return {}
	end

	local results = {}
	for index, entry in ipairs(bookmarks) do
		if entryType(entry) == "folder" then
			for subIndex, subEntry in ipairs(entry.items or {}) do
				if entryType(subEntry) ~= "folder" then
					local score = noctalia.fuzzyScore(trimmed, subEntry.label or "")
					if score ~= nil then
						table.insert(results, {
							entry = subEntry,
							path = entry.label or "",
							folderIndex = index,
							index = subIndex,
							score = score,
						})
					end
				end
			end
		else
			local score = noctalia.fuzzyScore(trimmed, entry.label or "")
			if score ~= nil then
				table.insert(results, {
					entry = entry,
					path = nil,
					folderIndex = nil,
					index = index,
					score = score,
				})
			end
		end
	end

	table.sort(results, function(a, b)
		return a.score > b.score
	end)
	return results
end

local function loadBookmarks()
	if path == nil then
		bookmarks = {}
		return
	end
	if not noctalia.fileExists(path) then
		bookmarks = {}
		listError = nil
		return
	end
	local raw, readErr = noctalia.readFile(path)
	if raw == nil then
		bookmarks = {}
		listError = noctalia.tr("err_read_failed", { error = tostring(readErr) })
		return
	end
	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		bookmarks = {}
		listError = noctalia.tr("err_corrupt", { error = tostring(decodeErr) })
		return
	end
	bookmarks = decoded
	listError = nil
end

local function saveBookmarks()
	if path == nil then
		return false, noctalia.tr("err_no_data_dir")
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

-- Moves the entry currently at `fromIndex` so it sits immediately before
-- `beforeIndex` (both 1-based, referring to positions in `list` before the
-- move). `beforeIndex == #list + 1` means "move to the end". No-ops for a
-- drop that wouldn't change order, and rolls back on write failure.
local function moveEntryTo(list, fromIndex, beforeIndex)
	if fromIndex < 1 or fromIndex > #list then
		return
	end
	-- Dropping onto the gap immediately above or below your own row is a
	-- no-op, not a "move to the other side of yourself".
	if beforeIndex == fromIndex or beforeIndex == fromIndex + 1 then
		return
	end

	local snapshot = {}
	for i, v in ipairs(list) do
		snapshot[i] = v
	end

	local moved = table.remove(list, fromIndex)
	local insertAt = beforeIndex
	if beforeIndex > fromIndex then
		insertAt = beforeIndex - 1
	end
	table.insert(list, insertAt, moved)

	local ok, err = saveBookmarks()
	if not ok then
		for i = #list, 1, -1 do
			list[i] = nil
		end
		for i, v in ipairs(snapshot) do
			list[i] = v
		end
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_reorder_failed", { error = err })
		)
	end
end

-- Runs a bookmark's command. Two distinct failure paths get a notification:
-- the shell couldn't even be spawned, or it ran and exited non-zero.
-- Success stays silent, same as file-search's xdg-open.
local function runBookmark(entry)
	local cmd = entry.cmd
	if type(cmd) ~= "string" or cmd == "" then
		noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err_no_command"))
		return
	end
	local label = entry.label or cmd

	if parseBool(entry.runInTerminal) then
		noctalia.runInTerminal(cmd)
		return
	end

	local finalCmd = cmd
	if parseBool(entry.runInBackground) then
		finalCmd = "nohup " .. cmd .. " >/dev/null 2>&1 &"
	end

	local ok = noctalia.runAsync(finalCmd, function(result)
		if parseBool(entry.runInBackground) then
			return
		end

		if result.exitCode ~= 0 then
			local detail = noctalia.string.trim(result.stderr or "")
			local msg =
				noctalia.tr("err_exit_code", { label = label, code = tostring(result.exitCode) })
			if detail ~= "" then
				msg = msg .. ": " .. detail
			end
			noctalia.notifyError(noctalia.tr("title"), msg)
		end
		-- exitCode == 0: succeeded, no notification
	end)

	if not ok then
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_launch_failed", { label = label })
		)
	end
end

-- Thin insertion-point drop zone rendered between rows (and before the
-- first / after the last). `place` is "before"/"after" relative to
-- `anchorIndex`, encoded into `value` for onReorderEntry to decode.
local function insertionGap(anchorIndex, place)
	return ui.dropZone({
		key = "gap-" .. place .. "-" .. anchorIndex,
		accepts = { "bookmark-entry" },
		value = place .. "|" .. anchorIndex,
		onDrop = "onReorderEntry",
		height = 6,
		expandOnDrag = true,
		hitSlop = 20,
	})
end

-- Returns the ordered list of rows currently visible for keyboard
-- navigation, in the same order they're rendered. Each entry is
-- { kind = "search", result } or { kind = "entry", entry, index }, so
-- Enter can dispatch the right action regardless of view.
local function visibleRows()
	local trimmed = noctalia.string.trim(searchQuery)
	if currentFolder == nil and trimmed ~= "" then
		local rows = {}
		for _, result in ipairs(searchBookmarks(searchQuery)) do
			table.insert(rows, { kind = "search", result = result })
		end
		return rows
	end

	local list = activeList()
	local rows = {}
	for index, entry in ipairs(list) do
		table.insert(rows, { kind = "entry", entry = entry, index = index })
	end
	return rows
end

-- Runs whatever the given visible-row entry represents: opens a folder,
-- or runs and closes on a bookmark (search result or normal row alike).
local function activateRow(row)
	if row == nil then
		return
	end
	if row.kind == "search" then
		runBookmark(row.result.entry)
		onClose()
		panel.close()
		return
	end
	if entryType(row.entry) == "folder" then
		onOpenFolder(row.index)
	else
		runBookmark(row.entry)
		onClose()
		panel.close()
	end
end

local function entryRow(entry, index)
	local isFolder = entryType(entry) == "folder"

	local trailing = {}
	if isFolder then
		table.insert(
			trailing,
			ui.button({
				glyph = "chevron-right",
				variant = "ghost",
				controlSize = "sm",
				tooltip = noctalia.tr("open_tooltip"),
				onClick = function()
					onOpenFolder(index)
				end,
			})
		)
	elseif not editMode and parseBool(noctalia.getConfig("show_info_button")) then
		local description = noctalia.string.trim(entry.description or "")
		local cmd = entry.cmd or ""
		local infoTooltip = noctalia.tr("info_cmd_line", { cmd = cmd })
		if description ~= "" then
			infoTooltip = infoTooltip
				.. "\n"
				.. noctalia.tr("info_description_line", { description = description })
		end
		table.insert(
			trailing,
			ui.button({
				glyph = "help-circle",
				variant = "ghost",
				controlSize = "sm",
				tooltip = infoTooltip,
				onClick = function() end,
			})
		)
	end
	if not isFolder and editMode then
		trailing = {
			ui.button({
				glyph = "pencil",
				variant = "secondary",
				controlSize = "sm",
				tooltip = noctalia.tr("edit_tooltip"),
				onClick = function()
					onEditEntry(index)
				end,
			}),
			ui.button({
				glyph = "trash",
				variant = "destructive",
				controlSize = "sm",
				tooltip = noctalia.tr("delete_tooltip"),
				onClick = function()
					onDeleteEntry(index)
				end,
			}),
		}
	end

	local rowChildren = {}
	if editMode then
		table.insert(
			rowChildren,
			ui.dragSource({
				key = "grip-" .. index,
				dragType = "bookmark-entry",
				payload = tostring(index),
				previewAncestor = 1,
				liftFromLayout = true,
				tooltip = noctalia.tr("drag_tooltip"),
				width = 16,
				height = 16,
			}, {
				ui.glyph({ name = "grip-vertical", size = 14, color = "on_surface_variant" }),
			})
		)
	end

	local isSelected = selectedIndex == index
	local activateEntry = function()
		if isFolder then
			onOpenFolder(index)
		else
			runBookmark(entry)
			onClose()
			panel.close()
		end
	end
	table.insert(
		rowChildren,
		ui.row({
			key = "bm-main-" .. index,
			gap = 8,
			align = "center",
			flexGrow = 1,
			height = 30,
			tooltip = (not isFolder) and entry.cmd or nil,
			onClick = activateEntry,
			onHover = function(state)
				if state == "true" then
					selectedIndex = index
					render()
				end
			end,
		}, {
			ui.glyph({
				name = entry.glyph or (isFolder and "folder" or "bookmark"),
				size = 16,
				color = "on_surface",
			}),
			ui.label({
				text = entry.label or "",
				fontSize = 13,
				color = isSelected and "primary" or "on_surface",
				fontWeight = isSelected and "bold" or "regular",
				flexGrow = 1,
				maxLines = 1,
			}),
		})
	)

	for _, node in ipairs(trailing) do
		table.insert(rowChildren, node)
	end

	return ui.row({ key = "bm-" .. index, gap = 8, align = "center", height = 30 }, rowChildren)
end

-- One row in the flat search results list: runs the bookmark on click,
-- same as a normal row, and shows its containing folder as a small path
-- label when the match came from inside one.
local function searchResultRow(result, rowIndex)
	local entry = result.entry
	local isSelected = selectedIndex == rowIndex
	local runEntry = function()
		runBookmark(entry)
		onClose()
		panel.close()
	end

	local children = {
		ui.button({
			glyph = entry.glyph or "bookmark",
			variant = "ghost",
			glyphSize = 16,
			width = 24,
			height = 24,
			tooltip = entry.cmd,
			onClick = runEntry,
		}),
		ui.label({
			text = entry.label or "",
			fontSize = 13,
			color = isSelected and "primary" or "on_surface",
			fontWeight = isSelected and "bold" or "regular",
			flexGrow = 1,
			maxLines = 1,
		}),
	}
	if result.path ~= nil then
		table.insert(
			children,
			ui.label({
				text = result.path,
				fontSize = 11,
				color = "on_surface_variant",
				maxLines = 1,
			})
		)
	end

	return ui.row({
		key = "search-" .. rowIndex,
		gap = 8,
		align = "center",
		height = 30,
		onClick = runEntry,
		onHover = function(state)
			if state == "true" then
				selectedIndex = rowIndex
				render()
			end
		end,
	}, children)
end

local function listView()
	local list = activeList()
	local children = {}

	local searching = currentFolder == nil and noctalia.string.trim(searchQuery) ~= ""

	if currentFolder ~= nil then
		local folder = bookmarks[currentFolder]
		table.insert(
			children,
			ui.row({ gap = 8, align = "center" }, {
				ui.button({
					glyph = "chevron-left",
					variant = "ghost",
					controlSize = "sm",
					tooltip = noctalia.tr("back_button"),
					onClick = "onBackToRoot",
				}),
				ui.row({
					gap = 6,
					align = "center",
					flexGrow = 1,
					onClick = "onEditFolderHeader",
				}, {
					ui.glyph({
						name = "pencil",
						size = 13,
						color = "on_surface_variant",
					}),
					ui.label({
						text = (folder and folder.label) or "",
						fontSize = 13,
						fontWeight = "bold",
						color = "on_surface",
						flexGrow = 1,
						maxLines = 1,
					}),
				}),
			})
		)
	end

	if currentFolder == nil then
		local wantsFocus = focusSearchOnRender
		focusSearchOnRender = false
		table.insert(
			children,
			ui.input({
				key = "search-input-" .. searchRev,
				value = searchQuery,
				placeholder = noctalia.tr("search_placeholder"),
				controlSize = "sm",
				focus = wantsFocus,
				onChange = "onSearchChanged",
				onSubmit = "onSearchSubmit",
			})
		)
	end

	if searching then
		local results = searchBookmarks(searchQuery)
		if #results == 0 then
			table.insert(
				children,
				ui.label({
					text = noctalia.tr("no_search_results"),
					color = "on_surface_variant",
					fontSize = 12,
				})
			)
		else
			local rows = {}
			for rowIndex, result in ipairs(results) do
				table.insert(rows, searchResultRow(result, rowIndex))
			end
			table.insert(children, ui.scroll({ flexGrow = 1, gap = 2 }, rows))
		end
		return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
	end

	local topButtons = {
		ui.button({
			key = "new-bookmark",
			text = noctalia.tr("new_bookmark"),
			glyph = "plus",
			variant = "primary",
			flexGrow = 1,
			enabled = path ~= nil,
			onClick = "onNewBookmark",
		}),
	}
	-- Folders can only be created at root: one level of nesting only. The
	-- button is omitted entirely inside a folder, rather than just disabled,
	-- since nesting isn't a supported concept here at all.
	if currentFolder == nil then
		table.insert(
			topButtons,
			ui.button({
				key = "new-folder",
				text = noctalia.tr("new_folder"),
				glyph = "folder-plus",
				variant = "secondary",
				flexGrow = 1,
				enabled = path ~= nil,
				onClick = "onNewFolder",
			})
		)
	end

	table.insert(
		topButtons,
		ui.button({
			key = "toggle-edit-mode",
			glyph = editMode and "eye" or "eye-off",
			variant = "ghost",
			controlSize = "sm",
			width = 32,
			tooltip = noctalia.tr(editMode and "hide_controls_tooltip" or "show_controls_tooltip"),
			onClick = "onToggleEditMode",
		})
	)

	table.insert(children, ui.row({ gap = 8 }, topButtons))

	if listError ~= nil then
		table.insert(children, ui.label({ text = listError, color = "error", fontSize = 12 }))
	elseif #list == 0 then
		table.insert(
			children,
			ui.label({
				text = noctalia.tr("no_bookmarks"),
				color = "on_surface_variant",
				fontSize = 12,
			})
		)
	else
		local rows = {}
		local count = #list
		for index, entry in ipairs(list) do
			if editMode then
				table.insert(rows, insertionGap(index, "before"))
			end
			table.insert(rows, entryRow(entry, index))
		end
		if editMode and count > 0 then
			table.insert(rows, insertionGap(count, "after"))
		end
		table.insert(children, ui.scroll({ flexGrow = 1, gap = 2 }, rows))
	end

	if currentFolder ~= nil then
		table.insert(
			children,
			ui.button({
				key = "delete-folder",
				text = noctalia.tr("delete_folder_button"),
				glyph = "trash",
				variant = "destructive",
				onClick = "onDeleteFolder",
			})
		)
	end

	return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

local function formView()
	local isFolder = draftKind == "folder"
	local title
	if editingIndex ~= nil then
		title = isFolder and noctalia.tr("edit_folder") or noctalia.tr("edit_bookmark")
	else
		title = isFolder and noctalia.tr("new_folder") or noctalia.tr("new_bookmark")
	end

	local children = {
		ui.row({ align = "center", justify = "space_between" }, {
			ui.label({
				text = title,
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				flexGrow = 1,
			}),
			ui.button({
				glyph = "close",
				variant = "ghost",
				tooltip = noctalia.tr("cancel_button"),
				onClick = "onCancelBookmark",
			}),
		}),

		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({
				name = draftGlyph ~= "" and draftGlyph or (isFolder and "folder" or "bookmark"),
				size = 18,
				color = "primary",
			}),
			ui.input({
				key = "glyph-input-" .. formRev,
				value = draftGlyph,
				placeholder = noctalia.tr("glyph_field"),
				controlSize = "sm",
				flexGrow = 1,
				onChange = "onGlyphChange",
			}),
		}),

		ui.input({
			key = "label-input-" .. formRev,
			value = draftLabel,
			placeholder = isFolder and noctalia.tr("folder_name_field")
				or noctalia.tr("label_field"),
			controlSize = "sm",
			focus = true,
			onChange = "onLabelChange",
		}),
	}

	if not isFolder then
		table.insert(
			children,
			ui.input({
				key = "cmd-input-" .. formRev,
				value = draftCmd,
				placeholder = noctalia.tr("cmd_field"),
				controlSize = "sm",
				onChange = "onCmdChange",
			})
		)

		table.insert(
			children,
			ui.input({
				key = "description-input-" .. formRev,
				value = draftDescription,
				placeholder = noctalia.tr("description_field"),
				controlSize = "sm",
				onChange = "onDescriptionChange",
			})
		)

		table.insert(
			children,
			ui.row({ gap = 8, align = "center" }, {
				ui.toggle({
					checked = draftRunInBackground,
					enabled = true,
					onChange = "onRunInBackgroundChange",
				}),
				ui.label({
					text = noctalia.tr("run_in_background_field"),
					fontSize = 13,
					color = "on_surface",
				}),
			})
		)

		table.insert(
			children,
			ui.row({ gap = 8, align = "center" }, {
				ui.toggle({
					checked = draftRunInTerminal,
					enabled = true,
					onChange = "onRunInTerminalChange",
				}),
				ui.label({
					text = noctalia.tr("run_in_terminal_field"),
					fontSize = 13,
					color = "on_surface",
				}),
			})
		)
	end

	if draftError ~= nil then
		table.insert(children, ui.label({ text = draftError, color = "error", fontSize = 12 }))
	end

	table.insert(
		children,
		ui.row({ gap = 8, justify = "end" }, {
			ui.button({
				text = noctalia.tr("save_button"),
				variant = "primary",
				onClick = "onSaveBookmark",
			}),
			ui.button({
				text = noctalia.tr("cancel_button"),
				variant = "destructive",
				onClick = "onCancelBookmark",
			}),
		})
	)

	return ui.column({ gap = 10, padding = 14 }, children)
end

function render()
	if view == "new" then
		panel.render(formView())
	else
		panel.render(listView())
	end
end

function onNewBookmark()
	editingIndex = nil
	editingRoot = false
	draftKind = "bookmark"
	draftGlyph = "bookmark"
	draftLabel = ""
	draftCmd = ""
	draftDescription = ""
	draftRunInBackground = false
	draftRunInTerminal = false
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onNewFolder()
	-- Folders are root-only (one level of nesting), so this should be
	-- unreachable while inside a folder, but guard anyway since it's
	-- reached via a button click, not just render-time gating.
	if currentFolder ~= nil then
		return
	end
	editingIndex = nil
	editingRoot = false
	draftKind = "folder"
	draftGlyph = "folder"
	draftLabel = ""
	draftCmd = ""
	draftDescription = ""
	draftRunInBackground = false
	draftRunInTerminal = false
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onOpenFolder(index)
	local list = activeList()
	local entry = list[index]
	if entry == nil or entryType(entry) ~= "folder" then
		return
	end
	-- currentFolder is only ever set from root (folders are one level deep),
	-- so `index` here is always an index into the root `bookmarks` array.
	currentFolder = index
	selectedIndex = 1
	render()
end

function onBackToRoot()
	currentFolder = nil
	selectedIndex = 1
	render()
end

-- Editing the currently open folder's own name/glyph: the folder entry
-- lives in root `bookmarks` at `currentFolder`, not in activeList() (which
-- is the folder's *contents*), so this goes through root explicitly.
function onEditFolderHeader()
	if currentFolder == nil then
		return
	end
	local entry = bookmarks[currentFolder]
	if entry == nil then
		return
	end
	editingIndex = currentFolder
	editingRoot = true
	draftKind = "folder"
	draftGlyph = entry.glyph or "folder"
	draftLabel = entry.label or ""
	draftCmd = ""
	draftDescription = ""
	draftRunInBackground = false
	draftRunInTerminal = false
	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onDeleteFolder()
	if currentFolder == nil then
		return
	end
	local entry = bookmarks[currentFolder]
	if entry == nil or entryType(entry) ~= "folder" then
		return
	end

	local removed = table.remove(bookmarks, currentFolder)
	if removed == nil then
		return
	end
	local ok, err = saveBookmarks()
	if not ok then
		table.insert(bookmarks, currentFolder, removed)
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_delete_failed", { error = err })
		)
		render()
		return
	end

	noctalia.notify(
		noctalia.tr("title"),
		noctalia.tr("folder_deleted", { label = removed.label or "" })
	)
	currentFolder = nil
	render()
end

function onEditEntry(index)
	local list = activeList()
	editingRoot = false
	local entry = list[index]
	if entry == nil then
		return
	end
	editingIndex = index
	draftKind = entryType(entry)
	draftGlyph = entry.glyph or (draftKind == "folder" and "folder" or "bookmark")
	draftLabel = entry.label or ""
	draftCmd = entry.cmd or ""
	draftDescription = entry.description or ""

	-- Strictly enforce the native boolean type right from JSON initialization
	draftRunInBackground = parseBool(entry.runInBackground)
	draftRunInTerminal = parseBool(entry.runInTerminal)

	draftError = nil
	formRev += 1
	view = "new"
	render()
end

function onCancelBookmark()
	editingIndex = nil
	editingRoot = false
	view = "list"
	render()
end

function onGlyphChange(value)
	draftGlyph = value
	render()
end

function onLabelChange(value)
	draftLabel = value
end

function onCmdChange(value)
	draftCmd = value
end

function onDescriptionChange(value)
	draftDescription = value
end

function onRunInBackgroundChange(value)
	-- Discard any UI objects or strings gracefully back into native booleans
	draftRunInBackground = parseBool(value)
	-- Mutually exclusive with "run in terminal": enabling one turns the
	-- other off immediately, rather than letting both sit checked until
	-- the form is reopened.
	if draftRunInBackground then
		draftRunInTerminal = false
	end
	render()
end

function onRunInTerminalChange(value)
	-- Discard any UI objects or strings gracefully back into native booleans
	draftRunInTerminal = parseBool(value)
	if draftRunInTerminal then
		draftRunInBackground = false
	end
	render()
end

function onSaveBookmark()
	local label = noctalia.string.trim(draftLabel)
	local glyph = noctalia.string.trim(draftGlyph)
	local isFolder = draftKind == "folder"

	if label == "" then
		draftError = noctalia.tr(isFolder and "err_label_required" or "err_label_cmd_required")
		render()
		return
	end

	local cmd = nil
	if not isFolder then
		cmd = noctalia.string.trim(draftCmd)
		if cmd == "" then
			draftError = noctalia.tr("err_label_cmd_required")
			render()
			return
		end
	end

	if glyph == "" then
		glyph = isFolder and "folder" or "bookmark"
	end

	local list = editingRoot and bookmarks or activeList()
	local newEntry
	if isFolder then
		local previousItems = nil
		if editingIndex ~= nil then
			local existing = list[editingIndex]
			previousItems = existing and existing.items or nil
		end
		newEntry = { type = "folder", glyph = glyph, label = label, items = previousItems or {} }
	else
		newEntry = {
			type = "bookmark",
			glyph = glyph,
			label = label,
			cmd = cmd,
			description = noctalia.string.trim(draftDescription),
			runInBackground = draftRunInBackground,
			runInTerminal = draftRunInTerminal,
		}
	end

	local previous = nil
	if editingIndex ~= nil then
		previous = list[editingIndex]
		list[editingIndex] = newEntry
	else
		table.insert(list, newEntry)
	end

	local ok, err = saveBookmarks()
	if not ok then
		-- roll back the in-memory change on write failure
		if editingIndex ~= nil then
			list[editingIndex] = previous
		else
			table.remove(list)
		end
		draftError = noctalia.tr("err_save_failed", { error = err })
		render()
		return
	end

	noctalia.notify(
		noctalia.tr("title"),
		noctalia.tr(editingIndex ~= nil and "entry_updated" or "entry_saved", { label = label })
	)
	editingIndex = nil
	editingRoot = false
	view = "list"
	render()
end

function onToggleEditMode()
	editMode = not editMode
	render()
end

function onSearchChanged(value)
	searchQuery = value
	selectedIndex = 1
	render()
end

function onSearchSubmit()
	local rows = visibleRows()
	activateRow(rows[selectedIndex] or rows[1])
end

-- Drop callback for the bookmark list's drag-and-drop reordering.
-- `payload` is the dragged row's original index (string, from
-- ui.dragSource); `target` is "before|N" or "after|N" from the drop
-- zone's `value`, N being the anchor row's index at render time.
function onReorderEntry(payload, target)
	local fromIndex = tonumber(payload)
	local place, anchorText = target:match("^([^|]+)|(.+)$")
	local anchorIndex = tonumber(anchorText)
	if fromIndex == nil or anchorIndex == nil then
		return
	end

	local beforeIndex = anchorIndex
	if place == "after" then
		beforeIndex = anchorIndex + 1
	end

	local list = activeList()
	moveEntryTo(list, fromIndex, beforeIndex)
	render()
end

function onDeleteEntry(index)
	local list = activeList()
	local entry = list[index]
	if entry == nil then
		return
	end
	if entryType(entry) == "folder" and #(entry.items or {}) > 0 then
		-- Deleting a non-empty folder takes its contents with it; the row's
		-- delete button has no separate confirm dialog available (panels
		-- have no native modal), so this is a same-click destructive action
		-- same as bookmark delete. Surfaced via notification after the fact
		-- rather than blocking, to stay consistent with existing delete UX.
		noctalia.notify(
			noctalia.tr("title"),
			noctalia.tr("folder_deleted", { label = entry.label or "" })
		)
	end

	local removed = table.remove(list, index)
	if removed == nil then
		return
	end
	local ok, err = saveBookmarks()
	if not ok then
		table.insert(list, index, removed)
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err_delete_failed", { error = err })
		)
		render()
		return
	end
	render()
end

-- `context == "search"` lets an external trigger (a compositor keybind via
-- `noctalia msg panel-open dunarand/bookmarks:panel search`, or any other
-- IPC caller) open the panel straight into a focused search box, turning
-- the bookmark list into a fast fuzzy launcher without a second keypress.
-- Root-only, same as ctrl+s: searching already isn't offered inside a
-- folder, so context is ignored there.
function onOpen(context)
	view = "list"
	editingIndex = nil
	editingRoot = false
	editMode = false
	currentFolder = nil
	searchQuery = ""
	searchRev += 1
	selectedIndex = 1
	loadBookmarks()
	noctalia.state.set("bookmarks_open", true)
	if context == "search" then
		focusSearchOnRender = true
	end
	render()
end

function onClose()
	noctalia.state.set("bookmarks_open", false)
end

-- Keyboard navigation: ctrl+n/down and ctrl+p/up move the selection through
-- the currently visible rows (search results or the active folder's list),
-- looping past either end; Return activates whatever is selected; ctrl+s
-- jumps focus to the search box (root view only, since that's the only
-- place it's rendered). Only acts on key-down (pressed == true) so each
-- chord fires once per press.
function onKey(chord, pressed)
	if not pressed then
		return
	end
	if view ~= "list" then
		return
	end

	if chord == "ctrl+s" then
		if currentFolder == nil then
			searchRev += 1
			focusSearchOnRender = true
			render()
		end
		return
	end

	local rows = visibleRows()
	local count = #rows
	if count == 0 then
		selectedIndex = nil
		return
	end

	if chord == "ctrl+n" or chord == "down" then
		if selectedIndex == nil then
			selectedIndex = 1
		else
			selectedIndex = selectedIndex % count + 1
		end
		render()
	elseif chord == "ctrl+p" or chord == "up" then
		if selectedIndex == nil then
			selectedIndex = count
		else
			selectedIndex = (selectedIndex - 2) % count + 1
		end
		render()
	elseif chord == "Return" then
		local row = rows[selectedIndex]
		activateRow(row)
	end
end

function update()
	render()
end
