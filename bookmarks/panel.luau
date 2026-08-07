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

-- Last selected index per scope, keyed by currentFolder (0 for root, since
-- folder indices start at 1). Restores position when re-entering a folder
-- or coming back to root instead of resetting to 1.
local rememberedSelection = {}

local function rememberSelection(folder)
	rememberedSelection[folder or 0] = selectedIndex
end

local function recallSelection(folder, rowCount)
	if rowCount == nil or rowCount <= 0 then
		return nil
	end
	return math.min(math.max(rememberedSelection[folder or 0] or 1, 1), rowCount)
end

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
-- { entry, path }, where path is the containing folder's label (nil for
-- root entries). Search results are only ever run, never edited in place,
-- so no index back into `bookmarks` is kept.
local function searchBookmarks(query)
	local trimmed = noctalia.string.trim(query)
	if trimmed == "" then
		return {}
	end

	local results = {}
	for _, entry in ipairs(bookmarks) do
		if entryType(entry) == "folder" then
			for _, subEntry in ipairs(entry.items or {}) do
				if entryType(subEntry) ~= "folder" then
					local score = noctalia.fuzzyScore(trimmed, subEntry.label or "")
					if score ~= nil then
						table.insert(
							results,
							{ entry = subEntry, path = entry.label or "", score = score }
						)
					end
				end
			end
		else
			local score = noctalia.fuzzyScore(trimmed, entry.label or "")
			if score ~= nil then
				table.insert(results, { entry = entry, path = nil, score = score })
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
		listError = noctalia.tr("err.read_failed", { error = tostring(readErr) })
		return
	end
	local decoded, decodeErr = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		bookmarks = {}
		listError = noctalia.tr("err.corrupt", { error = tostring(decodeErr) })
		return
	end
	bookmarks = decoded
	listError = nil
end

local function saveBookmarks()
	if path == nil then
		return false, noctalia.tr("err.no_data_dir")
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

local function snapshotArray(list)
	local copy = {}
	for i, v in ipairs(list) do
		copy[i] = v
	end
	return copy
end

-- Replaces `list`'s contents in place with `snapshot`'s, used to roll back
-- a move when saveBookmarks() fails partway through.
local function restoreArray(list, snapshot)
	for i = #list, 1, -1 do
		list[i] = nil
	end
	for i, v in ipairs(snapshot) do
		list[i] = v
	end
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

	local snapshot = snapshotArray(list)

	local moved = table.remove(list, fromIndex)
	local insertAt = beforeIndex
	if beforeIndex > fromIndex then
		insertAt = beforeIndex - 1
	end
	table.insert(list, insertAt, moved)

	local ok, err = saveBookmarks()
	if not ok then
		restoreArray(list, snapshot)
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err.reorder_failed", { error = err })
		)
	end
end

-- Moves a single bookmark (never a folder - nesting stays one level deep)
-- from `fromList` at `fromIndex` onto the end of `toList`. Used for both
-- directions of filing: root -> into a folder, and folder -> back to root.
-- Rolls back both lists on write failure, same pattern as moveEntryTo.
local function moveEntryAcross(fromList, fromIndex, toList)
	local entry = fromList[fromIndex]
	if entry == nil or entryType(entry) ~= "bookmark" then
		return false
	end

	local fromSnapshot = snapshotArray(fromList)
	local toSnapshot = snapshotArray(toList)

	table.remove(fromList, fromIndex)
	table.insert(toList, entry)

	local ok, err = saveBookmarks()
	if not ok then
		restoreArray(fromList, fromSnapshot)
		restoreArray(toList, toSnapshot)
		noctalia.notifyError(
			noctalia.tr("title"),
			noctalia.tr("err.reorder_failed", { error = err })
		)
		return false
	end
	return true, entry
end

-- Runs a bookmark's command. Two distinct failure paths get a notification:
-- the shell couldn't even be spawned, or it ran and exited non-zero.
-- Success stays silent, same as file-search's xdg-open.
local function runBookmark(entry)
	local cmd = entry.cmd
	if type(cmd) ~= "string" or cmd == "" then
		noctalia.notifyError(noctalia.tr("title"), noctalia.tr("err.no_command"))
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
				noctalia.tr("err.exit_code", { label = label, code = tostring(result.exitCode) })
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
			noctalia.tr("err.launch_failed", { label = label })
		)
	end
end

-- Runs a bookmark and closes the panel, the standard "user picked a
-- bookmark" action shared by every activation path (rows, search results,
-- keyboard Enter).
local function runAndClose(entry)
	runBookmark(entry)
	onClose()
	panel.close()
end

-- Thin insertion-point drop zone rendered between rows (and before the
-- first / after the last). `place` is "before"/"after" relative to
-- `anchorIndex`, encoded into `value` for _onReorderEntry to decode.
local function insertionGap(anchorIndex, place)
	return ui.dropZone({
		key = "gap-" .. place .. "-" .. anchorIndex,
		accepts = { "bookmark-entry" },
		value = place .. "|" .. anchorIndex,
		onDrop = "_onReorderEntry",
		height = 6,
		expandOnDrag = true,
		hitSlop = 20,
	})
end

-- Wraps a folder row so the whole row (root view only) doubles as a drop
-- target: dropping a bookmark onto it files that bookmark into the folder,
-- appended at the end. `value` is "into|<folderIndex>", read by
-- _onReorderEntry alongside the "before|after" insertion-gap values already
-- in use for same-list reordering. `hitSlop` matters here: the insertion
-- gaps immediately above/below this row extend their own hit area well
-- past their thin visible strip (see insertionGap), so without a
-- competing hitSlop of its own this zone would rarely win a drop even
-- when the pointer is squarely over the folder row - "closest wins" needs
-- both zones actually in the running.
local function folderDropTarget(folderIndex, child)
	return ui.dropZone({
		key = "into-" .. folderIndex,
		accepts = { "bookmark-entry" },
		value = "into|" .. folderIndex,
		onDrop = "_onReorderEntry",
		direction = "column",
		radius = 8,
		border = "primary/0.45",
		borderWidth = 1.5,
		expandOnDrag = true,
		hitSlop = 20,
	}, { child })
end

-- Persistent drop bar shown at the top of a folder's contents while in edit
-- mode: dropping a bookmark here pulls it back out to the root list,
-- appended at the end. Always present (not just an insertion gap) so an
-- otherwise-empty folder still offers a way to release an item back out.
local function moveToRootDropBar()
	return ui.dropZone({
		key = "move-to-root",
		accepts = { "bookmark-entry" },
		value = "out|root",
		onDrop = "_onReorderEntry",
		direction = "row",
		align = "center",
		gap = 8,
		height = 34,
		radius = 8,
		fill = "primary/0.08",
		border = "primary/0.35",
		borderWidth = 1.5,
		expandOnDrag = true,
		hitSlop = 12,
	}, {
		ui.glyph({ name = "corner-left-up", size = 14, color = "primary" }),
		ui.label({
			text = noctalia.tr("edit.drop_out_of_folder"),
			fontSize = 12,
			color = "primary",
			flexGrow = 1,
		}),
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
		runAndClose(row.result.entry)
		return
	end
	if entryType(row.entry) == "folder" then
		_onOpenFolder(row.index)
	else
		runAndClose(row.entry)
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
					_onOpenFolder(index)
				end,
			})
		)
	elseif not editMode and parseBool(noctalia.getConfig("show_info_button")) then
		local description = noctalia.string.trim(entry.description or "")
		local cmd = entry.cmd or ""
		local infoTooltip = noctalia.tr("info.cmd_line", { cmd = cmd })
		if description ~= "" then
			infoTooltip = infoTooltip
				.. "\n"
				.. noctalia.tr("info.description_line", { description = description })
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
				tooltip = noctalia.tr("edit.edit_tooltip"),
				onClick = function()
					_onEditEntry(index)
				end,
			}),
			ui.button({
				glyph = "trash",
				variant = "destructive",
				controlSize = "sm",
				tooltip = noctalia.tr("edit.delete_tooltip"),
				onClick = function()
					_onDeleteEntry(index)
				end,
			}),
		}
	end

	local isSelected = selectedIndex == index
	local activateEntry = function()
		if isFolder then
			_onOpenFolder(index)
		else
			runAndClose(entry)
		end
	end

	-- In edit mode a folder's glyph sits in a filled chip rather than bare,
	-- the same visual language as the move-to-root drop bar (filled
	-- primary/border), so "this accepts a dropped bookmark" reads at a
	-- glance instead of only revealing itself once a drag is already
	-- underway and the host's own highlight kicks in.
	-- Note: ui.box does not render child content (its documented props are
	-- fill/radius/border/size only), so the chip wrapper uses ui.row -
	-- which supports both children and the same fill/radius styling - with
	-- align/justify = "center" to center the glyph inside it.
	local folderGlyph = ui.glyph({
		name = entry.glyph or (isFolder and "folder" or "bookmark"),
		size = 16,
		color = (isFolder and editMode) and "primary" or "on_surface",
	})
	if isFolder and editMode then
		folderGlyph = ui.row({
			fill = "primary/0.12",
			radius = 6,
			width = 24,
			height = 24,
			align = "center",
			justify = "center",
		}, { folderGlyph })
	end

	-- Flat, single-level row: grip, glyph, label, and trailing controls are
	-- all direct children of "bm-<index>", the same node that sits as a
	-- sibling of the insertion gaps in the `rows` array built by listView.
	-- This matters for previewAncestor/liftFromLayout below - they walk up
	-- from the dragSource by ancestor count, so the drag source needs to be
	-- exactly one level under the node that's actually a gap's neighbor in
	-- the list. An earlier version wrapped glyph+label in their own nested
	-- sub-row; liftFromLayout then only collapsed that inner wrapper while
	-- the outer list-item row (the real gap sibling) stayed in layout as a
	-- leftover sliver next to the real gap - reading as two highlightable
	-- spaces where the dragged row used to be instead of one.
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
				tooltip = noctalia.tr("edit.drag_tooltip"),
				width = 16,
				height = 16,
			}, {
				ui.glyph({ name = "grip-vertical", size = 14, color = "on_surface_variant" }),
			})
		)
	end
	table.insert(rowChildren, folderGlyph)
	table.insert(
		rowChildren,
		ui.label({
			text = entry.label or "",
			fontSize = 13,
			color = isSelected and "primary" or "on_surface",
			fontWeight = isSelected and "bold" or "regular",
			flexGrow = 1,
			maxLines = 1,
		})
	)
	for _, node in ipairs(trailing) do
		table.insert(rowChildren, node)
	end

	local row = ui.row({
		key = "bm-" .. index,
		gap = 8,
		align = "center",
		height = 30,
		onClick = activateEntry,
		onHover = function(state)
			if state == "true" then
				selectedIndex = index
				render()
			end
		end,
	}, rowChildren)

	-- Only root-level folders accept drops (nesting stays one level deep,
	-- and folders never contain other folders), and only while edit mode
	-- exposes drag handles at all.
	if isFolder and editMode and currentFolder == nil then
		return folderDropTarget(index, row)
	end
	return row
end

-- One row in the flat search results list: runs the bookmark on click,
-- same as a normal row, and shows its containing folder as a small path
-- label when the match came from inside one.
local function searchResultRow(result, rowIndex)
	local entry = result.entry
	local isSelected = selectedIndex == rowIndex
	local runEntry = function()
		runAndClose(entry)
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
					onClick = "_onBackToRoot",
				}),
				ui.row({
					gap = 6,
					align = "center",
					flexGrow = 1,
					onClick = "_onEditFolderHeader",
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
				onChange = "_onSearchChanged",
				onSubmit = "_onSearchSubmit",
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
			text = noctalia.tr("entry_form.new_bookmark"),
			glyph = "plus",
			variant = "primary",
			flexGrow = 1,
			enabled = path ~= nil,
			onClick = "_onNewBookmark",
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
				text = noctalia.tr("entry_form.new_folder"),
				glyph = "folder-plus",
				variant = "secondary",
				flexGrow = 1,
				enabled = path ~= nil,
				onClick = "_onNewFolder",
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
			tooltip = noctalia.tr(
				editMode and "edit.hide_controls_tooltip" or "edit.show_controls_tooltip"
			),
			onClick = "_onToggleEditMode",
		})
	)

	table.insert(children, ui.row({ gap = 8 }, topButtons))

	-- Inside a folder, edit mode always offers a way to drop a bookmark back
	-- out to root - including when the folder is currently empty, so it
	-- stays a valid drag target rather than disappearing along with the
	-- "no bookmarks" message.
	if currentFolder ~= nil and editMode then
		table.insert(children, moveToRootDropBar())
	end

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
		local count = #list
		local rows = {}
		for index = 1, count do
			if editMode then
				table.insert(rows, insertionGap(index, "before"))
			end
			table.insert(rows, entryRow(list[index], index))
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
				text = noctalia.tr("folder.delete_folder_button"),
				glyph = "trash",
				variant = "destructive",
				onClick = "_onDeleteFolder",
			})
		)
	end

	return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
end

local function formView()
	local isFolder = draftKind == "folder"
	local title
	if editingIndex ~= nil then
		title = isFolder and noctalia.tr("entry_form.edit_folder")
			or noctalia.tr("entry_form.edit_bookmark")
	else
		title = isFolder and noctalia.tr("entry_form.new_folder")
			or noctalia.tr("entry_form.new_bookmark")
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
				tooltip = noctalia.tr("entry_form.cancel_button"),
				onClick = "_onCancelBookmark",
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
				placeholder = noctalia.tr("entry_form.glyph_field"),
				controlSize = "sm",
				flexGrow = 1,
				onChange = "_onGlyphChange",
			}),
		}),

		ui.input({
			key = "label-input-" .. formRev,
			value = draftLabel,
			placeholder = isFolder and noctalia.tr("entry_form.folder_name_field")
				or noctalia.tr("entry_form.label_field"),
			controlSize = "sm",
			focus = true,
			onChange = "_onLabelChange",
		}),
	}

	if not isFolder then
		table.insert(
			children,
			ui.input({
				key = "cmd-input-" .. formRev,
				value = draftCmd,
				placeholder = noctalia.tr("entry_form.cmd_field"),
				controlSize = "sm",
				onChange = "_onCmdChange",
			})
		)

		table.insert(
			children,
			ui.input({
				key = "description-input-" .. formRev,
				value = draftDescription,
				placeholder = noctalia.tr("entry_form.description_field"),
				controlSize = "sm",
				onChange = "_onDescriptionChange",
			})
		)

		table.insert(
			children,
			ui.row({ gap = 8, align = "center" }, {
				ui.toggle({
					checked = draftRunInBackground,
					enabled = true,
					onChange = "_onRunInBackgroundChange",
				}),
				ui.label({
					text = noctalia.tr("entry_form.run_in_background_field"),
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
					onChange = "_onRunInTerminalChange",
				}),
				ui.label({
					text = noctalia.tr("entry_form.run_in_terminal_field"),
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
				text = noctalia.tr("entry_form.save_button"),
				variant = "primary",
				onClick = "_onSaveBookmark",
			}),
			ui.button({
				text = noctalia.tr("entry_form.cancel_button"),
				variant = "destructive",
				onClick = "_onCancelBookmark",
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

function _onNewBookmark()
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

function _onNewFolder()
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

function _onOpenFolder(index)
	local list = activeList()
	local entry = list[index]
	if entry == nil or entryType(entry) ~= "folder" then
		return
	end
	-- Remember where we were in root before diving into the folder.
	rememberSelection(currentFolder)
	-- currentFolder is only ever set from root (folders are one level deep),
	-- so `index` here is always an index into the root `bookmarks` array.
	currentFolder = index
	selectedIndex = recallSelection(currentFolder, #(entry.items or {}))
	render()
end

function _onBackToRoot()
	-- Remember where we were inside the folder before leaving it.
	rememberSelection(currentFolder)
	currentFolder = nil
	selectedIndex = recallSelection(currentFolder, #bookmarks)
	render()
end

-- Editing the currently open folder's own name/glyph: the folder entry
-- lives in root `bookmarks` at `currentFolder`, not in activeList() (which
-- is the folder's *contents*), so this goes through root explicitly.
function _onEditFolderHeader()
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

function _onDeleteFolder()
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
			noctalia.tr("err.delete_failed", { error = err })
		)
		render()
		return
	end

	noctalia.notify(
		noctalia.tr("title"),
		noctalia.tr("folder.folder_deleted", { label = removed.label or "" })
	)
	-- Folder selections are now stale (indices after the deleted one
	-- shifted), so drop everything but root's.
	rememberedSelection = { [0] = rememberedSelection[0] }
	currentFolder = nil
	selectedIndex = recallSelection(currentFolder, #bookmarks)
	render()
end

function _onEditEntry(index)
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

function _onCancelBookmark()
	editingIndex = nil
	editingRoot = false
	view = "list"
	render()
end

function _onGlyphChange(value)
	draftGlyph = value
	render()
end

function _onLabelChange(value)
	draftLabel = value
end

function _onCmdChange(value)
	draftCmd = value
end

function _onDescriptionChange(value)
	draftDescription = value
end

function _onRunInBackgroundChange(value)
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

function _onRunInTerminalChange(value)
	-- Discard any UI objects or strings gracefully back into native booleans
	draftRunInTerminal = parseBool(value)
	if draftRunInTerminal then
		draftRunInBackground = false
	end
	render()
end

function _onSaveBookmark()
	local label = noctalia.string.trim(draftLabel)
	local glyph = noctalia.string.trim(draftGlyph)
	local isFolder = draftKind == "folder"

	if label == "" then
		draftError = noctalia.tr(
			isFolder and "entry_form.err_label_required" or "entry_form.err_label_cmd_required"
		)
		render()
		return
	end

	local cmd = nil
	if not isFolder then
		cmd = noctalia.string.trim(draftCmd)
		if cmd == "" then
			draftError = noctalia.tr("entry_form.err_label_cmd_required")
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
		draftError = noctalia.tr("err.save_failed", { error = err })
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

function _onToggleEditMode()
	editMode = not editMode
	render()
end

function _onSearchChanged(value)
	searchQuery = value
	selectedIndex = 1
	render()
end

function _onSearchSubmit()
	local rows = visibleRows()
	activateRow(rows[selectedIndex] or rows[1])
end

-- Drop callback for the bookmark list's drag-and-drop reordering.
-- `payload` is the dragged row's original index (string, from
-- ui.dragSource); `target` is "before|N" or "after|N" from the drop
-- zone's `value`, N being the anchor row's index at render time.
function _onReorderEntry(payload, target)
	local fromIndex = tonumber(payload)
	if fromIndex == nil then
		return
	end
	local place, rest = target:match("^([^|]+)|(.+)$")
	if place == nil then
		return
	end

	-- "into|<folderIndex>": drop a bookmark from the root list onto a
	-- folder row to file it inside, appended at the end of that folder's
	-- items. Root-only (folders are only ever dragged/dropped at root).
	if place == "into" then
		if currentFolder ~= nil then
			return
		end
		local folderIndex = tonumber(rest)
		if folderIndex == nil then
			return
		end
		local folder = bookmarks[folderIndex]
		if folder == nil or entryType(folder) ~= "folder" then
			return
		end
		folder.items = folder.items or {}
		moveEntryAcross(bookmarks, fromIndex, folder.items)
		render()
		return
	end

	-- "out|root": drop a bookmark from inside the open folder back onto
	-- root, appended at the end. Only meaningful while a folder is open.
	if place == "out" then
		if currentFolder == nil then
			return
		end
		local list = activeList()
		moveEntryAcross(list, fromIndex, bookmarks)
		render()
		return
	end

	local anchorIndex = tonumber(rest)
	if anchorIndex == nil then
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

function _onDeleteEntry(index)
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
			noctalia.tr("folder.folder_deleted", { label = entry.label or "" })
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
			noctalia.tr("err.delete_failed", { error = err })
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
-- Root-only, same as ctrl+f: searching already isn't offered inside a
-- folder, so context is ignored there.
--
-- To open in search mode and close from a single keybind:
--   noctalia msg panel-toggle dunarand/bookmarks:panel search
function onOpen(context)
	view = "list"

	editingIndex = nil
	editingRoot = false
	editMode = false
	currentFolder = nil
	searchQuery = ""
	searchRev += 1
	selectedIndex = 1
	rememberedSelection = {}
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

-- Keyboard navigation:
--   - ctrl+j/down and ctrl+k/up move the selection through the currently
--     visible rows (search results or the active folder's contents),
--     wrapping past either end.
--   - ctrl+l/right enters the selected folder, if any.
--   - ctrl+h/left returns from a folder to the root list.
--   - Return activates the selected row (opens a folder or runs a bookmark).
--   - ctrl+f focuses the search box (root view only, since folders don't
--     have one).
--   - ctrl+n opens the new-bookmark form.
--     root-only - same restriction as the "New Folder" button).
-- Only acts on key-down (pressed == true) so each chord fires once per press.
function onKey(chord, pressed)
	if not pressed then
		return
	end
	if view ~= "list" then
		return
	end

	if chord == "ctrl+f" then
		if currentFolder == nil then
			searchRev += 1
			focusSearchOnRender = true
			render()
		end
		return
	end

	if chord == "ctrl+n" then
		_onNewBookmark()
		return
	end

	if chord == "ctrl+h" or chord == "left" then
		if currentFolder ~= nil then
			_onBackToRoot()
		end
		return
	end

	local rows = visibleRows()
	local count = #rows
	if count == 0 then
		selectedIndex = nil
		return
	end

	if chord == "ctrl+j" or chord == "down" then
		if selectedIndex == nil then
			selectedIndex = 1
		else
			selectedIndex = selectedIndex % count + 1
		end
		render()
	elseif chord == "ctrl+k" or chord == "up" then
		if selectedIndex == nil then
			selectedIndex = count
		else
			selectedIndex = (selectedIndex - 2) % count + 1
		end
		render()
	elseif chord == "ctrl+l" or chord == "right" then
		local row = rows[selectedIndex]
		if row ~= nil and row.kind == "entry" then
			if entryType(row.entry) == "folder" then
				_onOpenFolder(row.index)
			end
		end
	elseif chord == "return" then
		local row = rows[selectedIndex]
		activateRow(row)
	end
end

function update()
	render()
end
