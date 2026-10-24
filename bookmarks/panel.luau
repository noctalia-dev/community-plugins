local shared = require("./shared.luau")

local entryType = shared.entryType
local parseBool = shared.parseBool

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

local DELETE_DOUBLE_PRESS_MS = 600 -- max delay between presses to confirm deletion
local lastDeletePressTime = 0
local lastDeleteTargetKey = nil

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

local function clampSelection(list)
	if #list == 0 then
		selectedIndex = nil
	elseif selectedIndex == nil then
		selectedIndex = 1
	else
		selectedIndex = math.clamp(selectedIndex, 1, #list)
	end
	rememberSelection(currentFolder)
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
	for _, item in ipairs(shared.flatten(bookmarks)) do
		local score = noctalia.fuzzyScore(trimmed, item.entry.label or "")
		if score ~= nil then
			table.insert(results, { entry = item.entry, path = item.path, score = score })
		end
	end

	table.sort(results, function(a, b)
		return a.score > b.score
	end)
	return results
end

local function loadBookmarks()
	local data, err = shared.loadBookmarks()
	bookmarks = data
	listError = err
end

local function saveBookmarks()
	return shared.saveBookmarks(bookmarks)
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
		return false
	end
	-- Dropping onto the gap immediately above or below your own row is a
	-- no-op, not a "move to the other side of yourself".
	if beforeIndex == fromIndex or beforeIndex == fromIndex + 1 then
		return false
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
		return false
	end
	return true
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

local function runBookmark(entry)
	shared.runBookmark(entry)
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
		height = 2,
		expandOnDrag = true,
		hitSlop = 20,
	})
end

-- Wraps a folder row so the whole row (root view only) doubles as a drop
-- target: dropping a bookmark onto it files that bookmark into the folder,
-- appended at the end. `value` is "into|<folderIndex>", read by
-- _onReorderEntry alongside the "before|after" insertion-gap values already
-- in use for same-list reordering.
local function folderDropTarget(folderIndex, child)
	return ui.dropZone({
		key = "into-" .. folderIndex,
		accepts = { "bookmark-entry" },
		value = "into|" .. folderIndex,
		onDrop = "_onReorderEntry",
		direction = "column",
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

local function bookmarkTooltip(entry)
	if entryType(entry) == "folder" then
		return nil
	end
	local description = noctalia.string.trim(entry.description or "")
	local cmd = noctalia.string.trim(entry.cmd or "")
	if description ~= "" and cmd ~= "" then
		return noctalia.tr("info.description_line", { description = description })
			.. "\n"
			.. noctalia.tr("info.cmd_line", { cmd = cmd })
	elseif description ~= "" then
		return noctalia.tr("info.description_line", { description = description })
	elseif cmd ~= "" then
		return noctalia.tr("info.cmd_line", { cmd = cmd })
	end
	return nil
end

local function entryRow(entry, index)
	local isFolder = entryType(entry) == "folder"

	local trailing = {}
	if isFolder then
		table.insert(
			trailing,
			ui.button({
				key = "entry-open-" .. index,
				glyph = "chevron-right",
				variant = "ghost",
				controlSize = "sm",
				width = 22,
				height = 22,
				glyphSize = 13,
				tooltip = noctalia.tr("open_tooltip"),
				onClick = function()
					_onOpenFolder(index)
				end,
			})
		)
	end
	if not isFolder and editMode then
		trailing = {
			ui.button({
				key = "entry-edit-" .. index,
				glyph = "pencil",
				variant = "ghost",
				controlSize = "sm",
				width = 22,
				height = 22,
				glyphSize = 13,
				tooltip = noctalia.tr("edit.edit_tooltip"),
				onClick = function()
					_onEditEntry(index)
				end,
			}),
			ui.button({
				key = "entry-del-" .. index,
				glyph = "trash",
				variant = "ghost",
				controlSize = "sm",
				width = 22,
				height = 22,
				glyphSize = 13,
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

	local folderGlyph = ui.glyph({
		name = entry.glyph or (isFolder and "folder" or "bookmark"),
		size = 16,
		color = "on_surface",
	})

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
			fontWeight = isSelected and "bold" or nil,
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
		tooltip = not editMode and bookmarkTooltip(entry) or nil,
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
		ui.glyph({
			name = entry.glyph or "bookmark",
			size = 16,
			color = "on_surface",
		}),
		ui.label({
			text = entry.label or "",
			fontSize = 13,
			color = isSelected and "primary" or "on_surface",
			fontWeight = isSelected and "bold" or nil,
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
		tooltip = bookmarkTooltip(entry),
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
			ui.row({ key = "folder-header-row", gap = 8, align = "center" }, {
				ui.button({
					key = "back-to-root",
					glyph = "chevron-left",
					variant = "ghost",
					controlSize = "sm",
					tooltip = noctalia.tr("back_button"),
					onClick = "_onBackToRoot",
				}),
				ui.row({
					key = "folder-title-row",
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
				}),
				ui.button({
					key = "open-settings",
					glyph = "settings",
					variant = "ghost",
					controlSize = "sm",
					width = 32,
					tooltip = noctalia.tr("settings_tooltip"),
					onClick = "_onOpenSettings",
				}),
			})
		)
	end

	if currentFolder == nil then
		local wantsFocus = focusSearchOnRender
		focusSearchOnRender = false
		table.insert(
			children,
			ui.row({ key = "search-header-row", gap = 8, align = "center" }, {
				ui.row({
					key = "search-input-box",
					gap = 6,
					align = "center",
					fill = "surface_variant/0.5",
					radius = 8,
					paddingH = 8,
					height = 32,
					flexGrow = 1,
				}, {
					ui.glyph({
						name = "search",
						size = 14,
						color = "on_surface_variant",
					}),
					ui.input({
						key = "search-input-" .. searchRev,
						value = searchQuery,
						placeholder = noctalia.tr("search_placeholder"),
						controlSize = "sm",
						frameVisible = false,
						flexGrow = 1,
						focus = wantsFocus,
						onChange = "_onSearchChanged",
						onSubmit = "_onSearchSubmit",
					}),
				}),
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
				}),
				ui.button({
					key = "open-settings",
					glyph = "settings",
					variant = "ghost",
					controlSize = "sm",
					width = 32,
					tooltip = noctalia.tr("settings_tooltip"),
					onClick = "_onOpenSettings",
				}),
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
			-- `revealKey` (plugin_api >= 33) keeps the keyboard selection in
			-- view: the scroll brings the child with that key into the
			-- viewport whenever it changes.
			table.insert(
				children,
				ui.scroll({
					key = "search-scroll",
					flexGrow = 1,
					gap = 2,
					revealKey = selectedIndex and ("search-" .. selectedIndex) or nil,
				}, rows)
			)
		end
		return ui.column({ gap = 10, padding = 14, flexGrow = 1 }, children)
	end

	local canAdd = shared.resolveDataPath() ~= nil
	local topButtons = {
		ui.button({
			key = "new-bookmark",
			text = noctalia.tr("entry_form.new_bookmark"),
			glyph = "plus",
			variant = "primary",
			flexGrow = 1,
			enabled = canAdd,
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
				enabled = canAdd,
				onClick = "_onNewFolder",
			})
		)
	end

	table.insert(children, ui.row({ key = "top-action-buttons", gap = 8 }, topButtons))

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
		-- Keep the keyboard selection in view. The key must match the
		-- scroll's direct child for that row, which is the folder drop-zone
		-- wrapper ("into-N") for root folders in edit mode, else the row
		-- itself ("bm-N") - see entryRow / folderDropTarget.
		local revealKey = nil
		local selectedEntry = selectedIndex and list[selectedIndex]
		if selectedEntry ~= nil then
			if entryType(selectedEntry) == "folder" and editMode and currentFolder == nil then
				revealKey = "into-" .. selectedIndex
			else
				revealKey = "bm-" .. selectedIndex
			end
		end
		table.insert(
			children,
			ui.scroll({
				key = "list-scroll-" .. tostring(currentFolder or 0),
				flexGrow = 1,
				gap = editMode and 0 or 2,
				revealKey = revealKey,
			}, rows)
		)
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
		ui.row({ key = "form-header-row", align = "center", justify = "space_between" }, {
			ui.label({
				text = title,
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				flexGrow = 1,
			}),
			ui.button({
				key = "form-close-button",
				glyph = "close",
				variant = "ghost",
				tooltip = noctalia.tr("entry_form.cancel_button"),
				onClick = "_onCancelBookmark",
			}),
		}),

		ui.row({
			key = "form-glyph-row",
			gap = 8,
			align = "center",
			fill = "surface_variant/0.5",
			radius = 8,
			paddingH = 8,
			height = 32,
		}, {
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
				frameVisible = false,
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
		ui.row({ key = "form-bottom-buttons", gap = 8, justify = "end" }, {
			ui.button({
				key = "form-save-button",
				text = noctalia.tr("entry_form.save_button"),
				variant = "primary",
				onClick = "_onSaveBookmark",
			}),
			ui.button({
				key = "form-cancel-button",
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
	lastDeletePressTime = 0
	lastDeleteTargetKey = nil
	-- Remember where we were in root before diving into the folder.
	rememberSelection(currentFolder)
	-- currentFolder is only ever set from root (folders are one level deep),
	-- so `index` here is always an index into the root `bookmarks` array.
	currentFolder = index
	selectedIndex = recallSelection(currentFolder, #(entry.items or {}))
	render()
end

function _onBackToRoot()
	lastDeletePressTime = 0
	lastDeleteTargetKey = nil
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
	if editingIndex == nil and not editingRoot then
		selectedIndex = #list
		rememberSelection(currentFolder)
	end
	editingIndex = nil
	editingRoot = false
	view = "list"
	render()
end

function _onToggleEditMode()
	editMode = not editMode
	render()
end

function _onOpenSettings()
	noctalia.openSettings()
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
		if moveEntryAcross(bookmarks, fromIndex, folder.items) then
			rememberedSelection = { [0] = rememberedSelection[0] }
			clampSelection(bookmarks)
		end
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
		if moveEntryAcross(list, fromIndex, bookmarks) then
			clampSelection(list)
		end
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
	if currentFolder == nil then
		rememberedSelection = { [0] = rememberedSelection[0] }
	end
	clampSelection(list)
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
	rememberedSelection = {}
	lastDeletePressTime = 0
	lastDeleteTargetKey = nil
	loadBookmarks()
	selectedIndex = #bookmarks > 0 and 1 or nil
	noctalia.state.set(shared.STATE_OPEN, true)
	if context == "search" then
		focusSearchOnRender = true
	end
	render()
end

function onClose()
	noctalia.state.set(shared.STATE_OPEN, false)
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
--   - ctrl+shift+n opens the new-folder form (root-only).
--   - ctrl+e opens the edit form for the selected bookmark/folder (or folder header).
--   - ctrl+d (double press within 600ms) deletes the selected bookmark/folder (or folder).
--   - ctrl+shift+k/up moves the selected bookmark/folder up by one.
--   - ctrl+shift+j/down moves the selected bookmark/folder down by one.
-- Only acts on key-down (pressed == true) so each chord fires once per press.
function onKey(chord, pressed)
	if not pressed then
		return
	end
	if view ~= "list" then
		return
	end

	if chord ~= "ctrl+d" then
		lastDeletePressTime = 0
		lastDeleteTargetKey = nil
	end

	if chord == "ctrl+f" then
		if currentFolder == nil then
			searchRev += 1
			focusSearchOnRender = true
			render()
		end
		return
	end

	if chord == "ctrl+shift+n" then
		if currentFolder == nil then
			_onNewFolder()
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

	if chord == "ctrl+e" then
		local row = selectedIndex and rows[selectedIndex]
		if row ~= nil and row.kind == "entry" then
			_onEditEntry(row.index)
		elseif currentFolder ~= nil and #rows == 0 then
			_onEditFolderHeader()
		end
		return
	end

	if chord == "ctrl+d" then
		local row = selectedIndex and rows[selectedIndex]
		local targetKey = nil
		if row ~= nil and row.kind == "entry" then
			targetKey = "entry:" .. tostring(currentFolder or 0) .. ":" .. tostring(row.index)
		elseif currentFolder ~= nil and #rows == 0 then
			targetKey = "folder:" .. tostring(currentFolder)
		end

		if targetKey ~= nil then
			local now = noctalia.nowMs()
			if lastDeleteTargetKey == targetKey and (now - lastDeletePressTime) <= DELETE_DOUBLE_PRESS_MS then
				lastDeletePressTime = 0
				lastDeleteTargetKey = nil
				if row ~= nil and row.kind == "entry" then
					_onDeleteEntry(row.index)
				elseif currentFolder ~= nil and #rows == 0 then
					_onDeleteFolder()
				end
			else
				lastDeletePressTime = now
				lastDeleteTargetKey = targetKey
			end
		end
		return
	end

	if chord == "ctrl+shift+k" or chord == "ctrl+shift+up" then
		local row = selectedIndex and rows[selectedIndex]
		if row ~= nil and row.kind == "entry" then
			local fromIndex = row.index
			if fromIndex > 1 then
				local list = activeList()
				if moveEntryTo(list, fromIndex, fromIndex - 1) then
					selectedIndex = fromIndex - 1
					rememberSelection(currentFolder)
					render()
				end
			end
		end
		return
	end

	if chord == "ctrl+shift+j" or chord == "ctrl+shift+down" then
		local row = selectedIndex and rows[selectedIndex]
		if row ~= nil and row.kind == "entry" then
			local fromIndex = row.index
			local list = activeList()
			if fromIndex < #list then
				if moveEntryTo(list, fromIndex, fromIndex + 2) then
					selectedIndex = fromIndex + 1
					rememberSelection(currentFolder)
					render()
				end
			end
		end
		return
	end

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
