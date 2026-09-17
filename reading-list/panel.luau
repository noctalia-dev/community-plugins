--!nonstrict
-- Reading List panel — library filters and item editor.

local items = {}
local managedCollections = {}
local ready = false
local serviceError = ""
local view = "list"
local editingId = nil
local draft = nil
local formKey = 0
local search = ""
local filter = "all"
local collectionFilter = ""
local pendingDelete = false
local pendingCardDeleteId = nil
local showAdvanced = false
local pickingImage = false
local pickingImport = false
local panelClosedForPicker = false
local selectionMode = false
local selectedIds = {}
local bulkDeleteArmed = false
local bulkCollection = ""
local shareFormat = "md"
local shareIncludeNotes = false
local shareIds = {}
local lastExportPath = ""
local lastImportSummary = ""
local showCollectionCreator = false
local newCollection = ""
local pendingCollectionDelete = false
local sortMode = "newest"
local reportRange = "30days"

local TYPE_OPTIONS = { "Article", "Book", "Image" }
local TYPE_VALUES = { "article", "book", "image" }
local STATUS_OPTIONS = { "Unread", "Reading", "Read", "Archived" }
local STATUS_VALUES = { "unread", "reading", "read", "archived" }
local RATING_OPTIONS = { "Not rated", "★", "★★", "★★★", "★★★★", "★★★★★" }
local SHARE_OPTIONS = { "Markdown", "HTML", "JSON" }
local SHARE_VALUES = { "md", "html", "json" }
local SORT_VALUES = { "newest", "queue", "oldest", "title", "rating", "progress" }
local REPORT_RANGE_VALUES = { "7days", "30days", "all" }

local function tr(key, fallback, subst)
  local value = noctalia.tr(key, subst)
  return value ~= key and value or fallback
end

local function sortOptions()
  return {
    tr("sort.newest", "Newest first"),
    tr("sort.queue", "Queue order"),
    tr("sort.oldest", "Oldest first"),
    tr("sort.title", "Title"),
    tr("sort.rating", "Highest rated"),
    tr("sort.progress", "Most progress"),
  }
end

local function reportRangeOptions()
  return {
    tr("reports.last-7-days", "Last 7 days"),
    tr("reports.last-30-days", "Last 30 days"),
    tr("reports.all-time", "All time"),
  }
end

local function send(cmd)
  noctalia.state.set("reading_list.cmd", cmd)
end

local function findItem(id)
  for _, item in ipairs(items) do if item.id == id then return item end end
  return nil
end

local function indexOf(values, value)
  for i, current in ipairs(values) do if current == value then return i - 1 end end
  return 0
end

local function copyItem(item)
  local topics = {}
  for _, topic in ipairs(item.topics or {}) do table.insert(topics, topic) end
  return {
    id = item.id,
    type = item.type or "article",
    title = item.title or "",
    url = item.url or "",
    source = item.source or "",
    author = item.author or "",
    description = item.description or "",
    topics = table.concat(topics, ", "),
    collections = table.concat(item.collections or {}, ", "),
    status = item.status or "unread",
    progress = tonumber(item.progress) or 0,
    currentPage = tostring(item.currentPage or 0),
    totalPages = tostring(item.totalPages or 0),
    rating = tonumber(item.rating) or 0,
    estimatedMinutes = tostring(item.estimatedMinutes or 0),
    image = item.image or "",
    notes = item.notes or "",
    review = item.review or "",
  }
end

local function emptyDraft()
  local clip = noctalia.clipboardText() or ""
  if not clip:match("^https?://[^%s]+$") then clip = "" end
  return {
    type = "article", title = "", url = clip, source = "", author = "",
    description = "", topics = "", collections = "", status = "unread",
    progress = 0, currentPage = "0", totalPages = "0", rating = 0,
    estimatedMinutes = "0", image = "", notes = "", review = "",
  }
end

local function clipboardUrl()
  local value = noctalia.clipboardText() or ""
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  if value:match("^https?://[^%s]+$") then return value end
  return ""
end

local function fileName(path)
  if type(path) ~= "string" or path == "" then return "" end
  return path:match("([^/]+)$") or path
end

local function chooseImage()
  if pickingImage or draft == nil then return end
  local pluginDir = noctalia.pluginDir()
  if pluginDir == nil or pluginDir == "" then
    noctalia.notifyError(tr("picker.error-title", "Could not open image picker"),
      tr("picker.error", "The plugin folder could not be resolved."))
    return
  end
  pickingImage = true
  render()
  local started = noctalia.runAsync({ "python3", pluginDir .. "/pick_image.py" }, function(result)
    pickingImage = false
    local selected = (result.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if result.exitCode == 0 and selected ~= "" then
      draft.image = selected
    elseif result.exitCode ~= 1 then
      noctalia.notifyError(tr("picker.error-title", "Could not open image picker"),
        (result.stderr or "") ~= "" and result.stderr or tr("picker.error", "The desktop portal did not return an image."))
    end
    if panelClosedForPicker then
      -- Attached panels close when the portal takes focus. Keep the draft and
      -- reopen the editor once the picker returns.
      noctalia.togglePanel("ahmedhossamdev/reading-list:panel")
    else
      render()
    end
  end, 60000)
  if not started then
    pickingImage = false
    noctalia.notifyError(tr("picker.error-title", "Could not open image picker"),
      tr("picker.error", "The desktop portal did not return an image."))
    render()
  end
end

local function chooseImport()
  if pickingImport then return end
  local pluginDir = noctalia.pluginDir()
  if pluginDir == nil or pluginDir == "" then
    noctalia.notifyError(tr("import.error-title", "Could not open import picker"),
      tr("import.error", "The plugin folder could not be resolved."))
    return
  end
  pickingImport = true
  render()
  local started = noctalia.runAsync({ "python3", pluginDir .. "/pick_image.py", "import" }, function(result)
    pickingImport = false
    local selected = (result.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if result.exitCode == 0 and selected ~= "" then
      send({ op = "import_file", path = selected })
    elseif result.exitCode ~= 1 then
      noctalia.notifyError(tr("import.error-title", "Could not import reading list"),
        (result.stderr or "") ~= "" and result.stderr or tr("import.error", "The file could not be imported."))
    end
    if panelClosedForPicker then
      noctalia.togglePanel("ahmedhossamdev/reading-list:panel")
    else
      render()
    end
  end, 60000)
  if not started then
    pickingImport = false
    noctalia.notifyError(tr("import.error-title", "Could not import reading list"),
      tr("import.error", "The file could not be imported."))
    render()
  end
end

local function startAdd()
  editingId = nil; draft = emptyDraft(); pendingDelete = false; pendingCardDeleteId = nil; showAdvanced = false
  showCollectionCreator = false; newCollection = ""
  formKey += 1; view = "edit"; render()
end

local function quickAddFromClipboard()
  local url = clipboardUrl()
  if url == "" then startAdd(); return end
  send({ op = "add", item = { url = url, type = "article", status = "unread" } })
end

local function startEdit(id)
  local item = findItem(id)
  if item == nil then return end
  editingId = id; draft = copyItem(item); pendingDelete = false; pendingCardDeleteId = nil; showAdvanced = false
  showCollectionCreator = false; newCollection = ""
  formKey += 1; view = "edit"; render()
end

local function leaveEditor()
  view = "list"; editingId = nil; draft = nil; pendingDelete = false
  showCollectionCreator = false; newCollection = ""; render()
end

local function selectedIdList()
  local result = {}
  for id, selected in pairs(selectedIds) do if selected then table.insert(result, id) end end
  return result
end

local function selectionCount()
  local count = 0
  for _, selected in pairs(selectedIds) do if selected then count += 1 end end
  return count
end

local function toggleSelected(id)
  selectedIds[id] = not (selectedIds[id] == true)
  bulkDeleteArmed = false
  render()
end

local function finishBulk(action, value)
  local ids = selectedIdList()
  if #ids == 0 then return end
  if action == "collection" and (type(value) ~= "string" or value:gsub("%s+", "") == "") then return end
  send({ op = "bulk", ids = ids, action = action, value = value })
  selectedIds = {}; bulkDeleteArmed = false; bulkCollection = ""
  render()
end

local function saveDraft()
  if draft == nil then return end
  if editingId == nil then send({ op = "add", item = draft })
  else draft.id = editingId; send({ op = "update", item = draft }) end
  leaveEditor()
end

local function statusLabel(status)
  return tr("status." .. (status or "unread"), status or "Unread")
end

local function statusGlyph(status)
  if status == "read" then return "circle-check-filled" end
  if status == "reading" then return "book-open" end
  if status == "archived" then return "archive" end
  return "circle"
end

local function nextStatus(status)
  if status == "unread" then return "reading" end
  if status == "reading" then return "read" end
  return "unread"
end

local function typeGlyph(itemType)
  if itemType == "book" then return "book-2" end
  if itemType == "image" then return "photo" end
  return "article"
end

local function formatDate(ts)
  if type(ts) ~= "number" or ts <= 0 then return "" end
  local ok, value = pcall(os.date, "%b %d, %Y", ts)
  return ok and value or ""
end

local function matches(item)
  if filter == "favorites" and item.favorite ~= true then return false end
  if filter ~= "all" and filter ~= "favorites" and item.status ~= filter then return false end
  if collectionFilter ~= "" then
    local found = false
    for _, collection in ipairs(item.collections or {}) do
      if collection == collectionFilter then found = true; break end
    end
    if not found then return false end
  end
  local query = search:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return true end
  local haystack = table.concat({ item.title or "", item.url or "", item.source or "",
    item.author or "", item.description or "", table.concat(item.topics or {}, " "),
    table.concat(item.collections or {}, " "), item.review or "" }, " "):lower()
  return haystack:find(query, 1, true) ~= nil
end

local function allCollections()
  local result, seen = {}, {}
  for _, collection in ipairs(managedCollections) do
    local key = collection:lower()
    if collection ~= "" and not seen[key] then seen[key] = true; table.insert(result, collection) end
  end
  for _, item in ipairs(items) do
    for _, collection in ipairs(item.collections or {}) do
      local key = collection:lower()
      if not seen[key] then seen[key] = true; table.insert(result, collection) end
    end
  end
  table.sort(result, function(a, b) return a:lower() < b:lower() end)
  return result
end

local function collectionOptions(emptyLabel)
  local values = allCollections()
  local options = { emptyLabel }
  for _, collection in ipairs(values) do table.insert(options, collection) end
  return options, values
end

local function createCollection()
  local name = newCollection:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return end
  local exists = false
  for _, collection in ipairs(managedCollections) do
    if collection:lower() == name:lower() then name = collection; exists = true; break end
  end
  if not exists then table.insert(managedCollections, name) end
  send({ op = "add_collection", name = name })
  if view == "edit" and draft ~= nil then draft.collections = name end
  newCollection = ""
  showCollectionCreator = false
  render()
end

local function deleteFilteredCollection(deleteItems)
  if collectionFilter == "" then return end
  send({ op = "remove_collection", name = collectionFilter, deleteItems = deleteItems == true })
  collectionFilter = ""
  pendingCollectionDelete = false
  render()
end

local function collectionCreatorRow()
  return ui.row({ gap = 5, align = "center" }, {
    ui.input({ key = "new-collection", value = newCollection, flexGrow = 1, controlSize = "sm",
      focus = true, placeholder = tr("collections.name-placeholder", "Collection name"),
      onChange = function(value) newCollection = value end,
      submitOnEnter = true, onSubmit = "onCollectionSubmit" }),
    ui.button({ glyph = "check", text = tr("collections.add", "Add"), variant = "primary",
      controlSize = "sm", onClick = createCollection }),
    ui.button({ glyph = "close", variant = "ghost", width = 29, height = 29,
      tooltip = tr("panel.cancel", "Cancel"), onClick = function()
        newCollection = ""; showCollectionCreator = false; render()
      end }),
  })
end

function onCollectionSubmit()
  createCollection()
end

local function filteredItems()
  local result = {}
  for _, item in ipairs(items) do if matches(item) then table.insert(result, item) end end
  table.sort(result, function(a, b)
    if sortMode == "queue" then
      if (a.queueOrder or 0) ~= (b.queueOrder or 0) then return (a.queueOrder or 0) < (b.queueOrder or 0) end
    elseif sortMode == "oldest" then
      if (a.createdAt or 0) ~= (b.createdAt or 0) then return (a.createdAt or 0) < (b.createdAt or 0) end
    elseif sortMode == "title" then
      local aTitle = (a.title ~= "" and a.title or a.url):lower()
      local bTitle = (b.title ~= "" and b.title or b.url):lower()
      if aTitle ~= bTitle then return aTitle < bTitle end
    elseif sortMode == "rating" then
      if (a.rating or 0) ~= (b.rating or 0) then return (a.rating or 0) > (b.rating or 0) end
    elseif sortMode == "progress" then
      if (a.progress or 0) ~= (b.progress or 0) then return (a.progress or 0) > (b.progress or 0) end
    elseif (a.createdAt or 0) ~= (b.createdAt or 0) then
      return (a.createdAt or 0) > (b.createdAt or 0)
    end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  return result
end

local function startShare()
  shareIds = selectedIdList()
  if #shareIds == 0 then
    for _, item in ipairs(filteredItems()) do table.insert(shareIds, item.id) end
  end
  if #shareIds == 0 then return end
  view = "share"
  render()
end

local function openUrl(url)
  if type(url) == "string" and (url:match("^https://[^%s]+$") or url:match("^http://[^%s]+$")) then
    noctalia.runAsync({ "xdg-open", url })
  end
end

local function topicText(item)
  local shown = {}
  for i, topic in ipairs(item.topics or {}) do
    if i > 3 then table.insert(shown, "+" .. tostring(#item.topics - 3)); break end
    table.insert(shown, "#" .. topic)
  end
  return table.concat(shown, "  ")
end

local function artwork(item)
  if item.image ~= "" and noctalia.fileExists(item.image) then
    return ui.image({ key = "cover-" .. item.id, path = item.image, width = 64, height = 64,
      radius = 8, fit = "cover", border = "outline/0.35", borderWidth = 1 })
  end
  if item.icon ~= "" and noctalia.fileExists(item.icon) then
    return ui.column({ width = 64, height = 64, align = "center", justify = "center",
      fill = "surface_variant", radius = 8 }, {
      ui.image({ key = "icon-" .. item.id, path = item.icon, width = 32, height = 32,
        radius = 6, fit = "contain" }),
    })
  end
  return ui.column({ width = 64, height = 64, align = "center", justify = "center",
    fill = "surface_variant", radius = 8 }, {
    ui.glyph({ name = typeGlyph(item.type), size = 27, color = "primary" }),
  })
end

local function itemCard(item, queueIndex, queueIds)
  local title = item.title ~= "" and item.title or item.url
  local source = item.source ~= "" and item.source or tr("panel.local-item", "Local item")
  local titleControl = item.url ~= ""
    and ui.row({ gap = 5, align = "center", onClick = function() openUrl(item.url) end }, {
      ui.label({ text = title, fontSize = 13, fontWeight = "semibold", maxLines = 2,
        flexGrow = 1 }),
      ui.glyph({ name = "external-link", size = 12, color = "on_surface_variant" }),
    })
    or ui.label({ text = title, fontSize = 13, fontWeight = "semibold", maxLines = 2 })
  local contentChildren = {
    titleControl,
    ui.row({ gap = 5, align = "center" }, {
      item.image ~= "" and noctalia.fileExists(item.image)
        and item.icon ~= "" and noctalia.fileExists(item.icon)
        and ui.image({ key = "source-icon-" .. item.id, path = item.icon, width = 16, height = 16,
          radius = 3, fit = "contain" })
        or ui.glyph({ name = "world", size = 14, color = "on_surface_variant" }),
      ui.label({ text = source .. (item.author ~= "" and (" · " .. item.author) or ""),
        fontSize = 10, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
    }),
  }
  if item.description ~= "" then
    table.insert(contentChildren, ui.label({ text = item.description, fontSize = 10,
      color = "on_surface_variant", maxLines = 2 }))
  end
  if topicText(item) ~= "" then
    table.insert(contentChildren, ui.label({ text = topicText(item), fontSize = 10,
      color = "primary", maxLines = 1 }))
  end
  if item.status == "reading" and (item.progress or 0) > 0 and (item.progress or 0) < 100 then
    table.insert(contentChildren, ui.row({ gap = 7, align = "center" }, {
      ui.progress({ progress = math.min(1, (item.progress or 0) / 100), flexGrow = 1,
        height = 4, fill = "primary", track = "outline/0.25", radius = 3 }),
      ui.label({ text = tostring(math.floor(item.progress or 0)) .. "%", width = 30,
        fontSize = 9, color = "on_surface_variant", textAlign = "end" }),
    }))
  end

  local mainChildren = {}
  if selectionMode then
    table.insert(mainChildren, ui.button({ glyph = selectedIds[item.id] and "square-check-filled" or "square",
        variant = "ghost", width = 28, height = 28, glyphSize = 17,
        tooltip = tr("bulk.select", "Select item"), onClick = function() toggleSelected(item.id) end }))
  end
  table.insert(mainChildren, artwork(item))
  table.insert(mainChildren, ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, contentChildren))

  local actionChildren = {
    ui.button({ glyph = item.favorite and "star-filled" or "star", variant = "ghost",
      width = 28, height = 28, glyphSize = 16, tooltip = tr("panel.favorite", "Favorite"),
      onClick = function() send({ op = "toggle_favorite", id = item.id }) end }),
  }
  if sortMode == "queue" then
    local previousId = queueIndex ~= nil and queueIndex > 1 and queueIds[queueIndex - 1] or nil
    local nextId = queueIndex ~= nil and queueIndex < #queueIds and queueIds[queueIndex + 1] or nil
    table.insert(actionChildren, 1, ui.button({ glyph = "chevron-down", variant = "ghost",
      width = 27, height = 27, glyphSize = 14, enabled = nextId ~= nil,
      tooltip = tr("sort.move-down", "Move down in queue"),
      onClick = function() send({ op = "swap_queue", id = item.id, targetId = nextId }) end }))
    table.insert(actionChildren, 1, ui.button({ glyph = "chevron-up", variant = "ghost",
      width = 27, height = 27, glyphSize = 14, enabled = previousId ~= nil,
      tooltip = tr("sort.move-up", "Move up in queue"),
      onClick = function() send({ op = "swap_queue", id = item.id, targetId = previousId }) end }))
  end
  if (item.rating or 0) > 0 then
    table.insert(actionChildren, ui.label({ text = tostring(item.rating) .. "★",
      width = 28, fontSize = 9, color = "primary", textAlign = "center" }))
  end
  table.insert(actionChildren, ui.button({ glyph = "pencil", variant = "ghost",
    width = 28, height = 28, glyphSize = 15,
    tooltip = tr("panel.edit", "Edit"), onClick = function() startEdit(item.id) end }))
  table.insert(actionChildren, ui.button({ glyph = item.status == "archived" and "archive-off" or "archive",
    variant = "ghost", width = 28, height = 28, glyphSize = 15,
    tooltip = item.status == "archived" and tr("panel.unarchive", "Move to Unread")
      or tr("panel.archive", "Archive"),
    onClick = function()
      send({ op = "set_status", id = item.id,
        status = item.status == "archived" and "unread" or "archived" })
    end }))
  table.insert(actionChildren, ui.button({ glyph = "trash", variant = "ghost",
    width = 28, height = 28, glyphSize = 15,
    tooltip = tr("panel.delete", "Delete"), onClick = function()
      pendingCardDeleteId = item.id
      render()
    end }))
  local children = {
    ui.row({ gap = 10, align = "start" }, mainChildren),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 6 }, {
        ui.button({ glyph = statusGlyph(item.status),
          text = statusLabel(item.status), variant = "ghost", width = 94, height = 28,
          contentAlign = "start", fontSize = 10, glyphSize = 14,
          tooltip = tr("status.change", "Change to {status}", {
            status = statusLabel(nextStatus(item.status)),
          }),
          onClick = function() send({ op = "set_status", id = item.id,
            status = nextStatus(item.status) }) end }),
        item.fetching and ui.label({ text = tr("panel.fetching", "Fetching details…"),
          fontSize = 9, color = "primary" }) or ui.label({ text = formatDate(item.createdAt),
          fontSize = 9, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 1, align = "center" }, actionChildren),
    }),
  }

  if pendingCardDeleteId == item.id then
    table.insert(children, ui.row({ gap = 6, align = "center", justify = "space_between",
      fill = "error_container", radius = 7, padding = 6 }, {
      ui.label({ text = tr("panel.confirm-delete", "Delete this item?"),
        flexGrow = 1, fontSize = 10, color = "on_error_container" }),
      ui.button({ text = tr("panel.cancel", "Cancel"), variant = "ghost", controlSize = "sm",
        onClick = function() pendingCardDeleteId = nil; render() end }),
      ui.button({ glyph = "trash", text = tr("panel.delete", "Delete"),
        variant = "destructive", controlSize = "sm", onClick = function()
          pendingCardDeleteId = nil
          send({ op = "remove", id = item.id })
        end }),
    }))
  end

  return ui.column({ key = "card-" .. item.id, fill = "surface_variant", radius = 10,
    padding = 9, gap = 6, align = "stretch" }, children)
end

local function filterButton(value, label)
  return ui.button({ key = "filter-" .. value, text = label,
    variant = filter == value and "outline" or "ghost",
    height = 28, fontSize = 10, onClick = function() filter = value; render() end })
end

local function bulkToolbar()
  local count = selectionCount()
  if bulkDeleteArmed then
    return ui.row({ gap = 5, align = "center", fill = "error_container", radius = 8, padding = 6 }, {
      ui.label({ text = tr("bulk.confirm-delete", "Delete {count} selected items?", { count = count }),
        flexGrow = 1, fontSize = 10, color = "on_error_container" }),
      ui.button({ text = tr("panel.cancel", "Cancel"), variant = "ghost", controlSize = "sm",
        onClick = function() bulkDeleteArmed = false; render() end }),
      ui.button({ glyph = "trash", text = tr("panel.delete", "Delete"), variant = "destructive",
        controlSize = "sm", onClick = function() finishBulk("delete") end }),
    })
  end
  return ui.column({ gap = 4, fill = "surface_variant", radius = 8, padding = 5, align = "stretch" }, {
    ui.row({ gap = 3, align = "center" }, {
      ui.label({ text = tr("bulk.selected", "{count} selected", { count = count }),
        flexGrow = 1, fontSize = 10, color = "on_surface_variant" }),
      ui.button({ glyph = "circle", variant = "ghost", width = 29, height = 29,
        tooltip = tr("bulk.mark-unread", "Mark selected unread"), enabled = count > 0,
        onClick = function() finishBulk("status", "unread") end }),
      ui.button({ glyph = "book-open", variant = "ghost", width = 29, height = 29,
        tooltip = tr("bulk.mark-reading", "Mark selected as reading"), enabled = count > 0,
        onClick = function() finishBulk("status", "reading") end }),
      ui.button({ glyph = "circle-check", variant = "ghost", width = 29, height = 29,
        tooltip = tr("bulk.mark-read", "Mark selected read"), enabled = count > 0,
        onClick = function() finishBulk("status", "read") end }),
      ui.button({ glyph = "archive", variant = "ghost", width = 29, height = 29,
        tooltip = tr("bulk.archive", "Archive selected"), enabled = count > 0,
        onClick = function() finishBulk("status", "archived") end }),
      ui.button({ glyph = "trash", variant = "ghost", width = 29, height = 29,
        tooltip = tr("bulk.delete", "Delete selected"), enabled = count > 0,
        onClick = function() bulkDeleteArmed = true; render() end }),
    }),
    ui.row({ gap = 4, align = "center" }, {
      ui.select({ key = "bulk-collection", options = (function()
          local options = { tr("bulk.choose-collection", "Choose collection") }
          for _, collection in ipairs(allCollections()) do table.insert(options, collection) end
          return options
        end)(), flexGrow = 1, controlSize = "sm",
        selectedIndex = bulkCollection == "" and 0 or indexOf(allCollections(), bulkCollection) + 1,
        onChange = function(index, _text)
          local selected = tonumber(index) or 0
          bulkCollection = selected == 0 and "" or (allCollections()[selected] or "")
          render()
        end }),
      ui.button({ glyph = "folder-plus", variant = "ghost", width = 29, height = 29,
        tooltip = tr("bulk.add-collection", "Add collection to selected"),
        enabled = count > 0 and bulkCollection ~= "",
        onClick = function() finishBulk("collection", bulkCollection) end }),
    }),
  })
end

local function listView()
  local visible = filteredItems()
  local collections = allCollections()
  local body
  if not ready then
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
      ui.glyph({ name = "loader-2", size = 28, color = "primary" }),
      ui.label({ text = tr("panel.loading", "Loading your reading list…"), color = "on_surface_variant" }),
    })
  elseif #visible == 0 then
    local filtered = search ~= "" or filter ~= "all"
    local emptyChildren = {
      ui.glyph({ name = filtered and "filter-off" or "bookmarks", size = 40, color = "primary" }),
      ui.label({ text = filtered and tr("panel.no-results", "No items match this filter.")
        or tr("panel.empty", "Your reading list is empty."), textAlign = "center", color = "on_surface_variant" }),
    }
    if not filtered then
      table.insert(emptyChildren, ui.row({ gap = 6, align = "center" }, {
        ui.button({ glyph = "plus", text = tr("panel.add-first", "Add your first item"),
          variant = "primary", controlSize = "sm", onClick = startAdd }),
        ui.button({ glyph = "file-import", text = tr("import.action", "Import file"),
          variant = "outline", controlSize = "sm", enabled = not pickingImport, onClick = chooseImport }),
      }))
    end
    body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8, padding = 30 }, emptyChildren)
  else
    local cards = {}
    local queueIds = {}
    for _, item in ipairs(visible) do table.insert(queueIds, item.id) end
    for index, item in ipairs(visible) do table.insert(cards, itemCard(item, index, queueIds)) end
    body = ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, cards)
  end

  local listChildren = {
    ui.input({ key = "search", value = search, placeholder = tr("panel.search", "Search titles, topics, or websites…"),
      controlSize = "sm", onChange = function(value) search = value; render() end }),
    ui.row({ gap = 4, align = "center" }, {
      filterButton("all", tr("filter.all", "All")),
      filterButton("unread", tr("filter.unread", "Unread")),
      filterButton("reading", tr("filter.reading", "Reading")),
      filterButton("read", tr("filter.read", "Read")),
      filterButton("favorites", tr("filter.favorites", "Favorites")),
      filterButton("archived", tr("filter.archived", "Archived")),
    }),
  }
  local filterOptions = { tr("filter.all-collections", "All collections") }
  for _, collection in ipairs(collections) do table.insert(filterOptions, collection) end
  local libraryControls = {
    ui.select({ key = "sort-mode", options = sortOptions(), flexGrow = 1, controlSize = "sm",
      selectedIndex = indexOf(SORT_VALUES, sortMode), onChange = function(index, _text)
        sortMode = SORT_VALUES[(tonumber(index) or 0) + 1] or "newest"
        render()
      end }),
    ui.select({ key = "collection-filter", options = filterOptions, flexGrow = 1,
      selectedIndex = collectionFilter == "" and 0 or indexOf(collections, collectionFilter) + 1,
      controlSize = "sm", onChange = function(index, _text)
        local selected = tonumber(index) or 0
        collectionFilter = selected == 0 and "" or (collections[selected] or "")
        pendingCollectionDelete = false
        showCollectionCreator = false
        render()
      end }),
    ui.button({ glyph = "folder-plus", variant = "ghost", width = 30, height = 30,
      tooltip = tr("collections.new", "New collection"), onClick = function()
        showCollectionCreator = not showCollectionCreator
        pendingCollectionDelete = false
        newCollection = ""
        render()
      end }),
  }
  if collectionFilter ~= "" then
    table.insert(libraryControls, ui.button({ glyph = "trash", variant = "ghost",
      width = 30, height = 30, tooltip = tr("collections.delete", "Delete collection"),
      onClick = function() pendingCollectionDelete = true; showCollectionCreator = false; render() end }))
  end
  table.insert(listChildren, ui.row({ gap = 5, align = "center" }, libraryControls))
  if pendingCollectionDelete and collectionFilter ~= "" then
    table.insert(listChildren, ui.column({ gap = 5, fill = "error_container", radius = 8,
      padding = 7, align = "stretch" }, {
      ui.row({ gap = 5, align = "center" }, {
        ui.label({ text = tr("collections.confirm", "Delete the collection “{name}”?", {
          name = collectionFilter,
        }), flexGrow = 1, fontSize = 10, color = "on_error_container" }),
        ui.button({ glyph = "close", variant = "ghost", width = 28, height = 28,
          tooltip = tr("panel.cancel", "Cancel"), onClick = function() pendingCollectionDelete = false; render() end }),
      }),
      ui.label({ text = tr("collections.delete-help", "Choose whether the saved items should be kept."),
        fontSize = 9, color = "on_error_container" }),
      ui.row({ gap = 6, align = "center" }, {
        ui.button({ text = tr("collections.keep-items", "Keep items"), flexGrow = 1,
          variant = "outline", controlSize = "sm", onClick = function() deleteFilteredCollection(false) end }),
        ui.button({ glyph = "trash", text = tr("collections.delete-items", "Delete items"), flexGrow = 1,
          variant = "destructive", controlSize = "sm", onClick = function() deleteFilteredCollection(true) end }),
      }),
    }))
  end
  if showCollectionCreator then table.insert(listChildren, collectionCreatorRow()) end
  if selectionMode then table.insert(listChildren, bulkToolbar()) end
  table.insert(listChildren, body)

  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, listChildren)
end

local function fieldLabel(text)
  return ui.label({ text = text, fontSize = 10, color = "on_surface_variant", fontWeight = "medium" })
end

local function editorView()
  local key = tostring(formKey)
  local fields = {
    fieldLabel(tr("form.url", "URL")),
    ui.input({ key = "url-" .. key, value = draft.url, placeholder = "https://…", focus = editingId == nil,
      controlSize = "sm",
      onChange = function(value) draft.url = value end }),
    fieldLabel(tr("form.title", "Title")),
    ui.input({ key = "title-" .. key, value = draft.title, controlSize = "sm",
      placeholder = tr("form.title-placeholder", "Fetched automatically when left empty"),
      onChange = function(value) draft.title = value end }),
    ui.row({ gap = 8, align = "center" }, {
      ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
        fieldLabel(tr("form.type", "Type")),
        ui.select({ key = "type-" .. key, options = TYPE_OPTIONS, controlSize = "sm",
          selectedIndex = indexOf(TYPE_VALUES, draft.type),
          onChange = function(index, _text)
            draft.type = TYPE_VALUES[(tonumber(index) or 0) + 1] or "article"
            if draft.type == "image" or draft.type == "book" then showAdvanced = true end
            render()
          end }),
      }),
      ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
        fieldLabel(tr("form.status", "Status")),
        ui.select({ key = "status-" .. key, options = STATUS_OPTIONS, controlSize = "sm",
          selectedIndex = indexOf(STATUS_VALUES, draft.status),
          onChange = function(index, _text) draft.status = STATUS_VALUES[(tonumber(index) or 0) + 1] or "unread"; render() end }),
      }),
    }),
    fieldLabel(tr("form.topics", "Topics")),
    ui.input({ key = "topics-" .. key, value = draft.topics, controlSize = "sm",
      placeholder = tr("form.topics-placeholder", "kafka, programming, architecture"),
      onChange = function(value) draft.topics = value end }),
  }

  table.insert(fields, fieldLabel(tr("form.collection", "Collection")))
  local editorOptions, editorCollections = collectionOptions(tr("form.no-collection", "No collection"))
  local selectedCollection = (draft.collections or ""):match("^%s*([^,]+)") or ""
  table.insert(fields, ui.row({ gap = 5, align = "center" }, {
    ui.select({ key = "collection-" .. key, options = editorOptions, flexGrow = 1, controlSize = "sm",
      selectedIndex = selectedCollection == "" and 0 or indexOf(editorCollections, selectedCollection) + 1,
      onChange = function(index, _text)
        local selected = tonumber(index) or 0
        draft.collections = selected == 0 and "" or (editorCollections[selected] or "")
        render()
      end }),
    ui.button({ glyph = "folder-plus", variant = "ghost", width = 32, height = 32,
      tooltip = tr("collections.new", "New collection"), onClick = function()
        showCollectionCreator = not showCollectionCreator
        newCollection = ""
        render()
      end }),
  }))
  if showCollectionCreator then table.insert(fields, collectionCreatorRow()) end

  table.insert(fields, ui.button({ glyph = showAdvanced and "chevron-up" or "adjustments",
    text = showAdvanced and tr("form.less-details", "Hide details") or tr("form.more-details", "More details"),
    variant = "ghost", controlSize = "sm", contentAlign = "start",
    onClick = function() showAdvanced = not showAdvanced; render() end }))

  if showAdvanced then
    table.insert(fields, ui.row({ gap = 8, align = "center" }, {
      ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
        fieldLabel(tr("form.source", "Website / source")),
        ui.input({ key = "source-" .. key, value = draft.source, controlSize = "sm",
          placeholder = tr("form.source-placeholder", "Detected automatically"),
          onChange = function(value) draft.source = value end }),
      }),
      ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
        fieldLabel(tr("form.author", "Author")),
        ui.input({ key = "author-" .. key, value = draft.author, controlSize = "sm",
          placeholder = tr("form.author-placeholder", "Optional"),
          onChange = function(value) draft.author = value end }),
      }),
    }))
    table.insert(fields, fieldLabel(tr("form.image", "Cover or image")))
    if draft.image ~= "" and noctalia.fileExists(draft.image) then
      table.insert(fields, ui.image({ key = "picked-image-" .. key, path = draft.image,
        height = 96, radius = 8, fit = "contain", border = "outline/0.35", borderWidth = 1 }))
    end
    local imageRowChildren = {
      ui.button({ glyph = "folder-open", text = pickingImage and tr("picker.opening", "Opening…")
          or tr("picker.choose", "Choose image"), variant = "outline", controlSize = "sm",
        enabled = not pickingImage, onClick = chooseImage }),
      draft.image ~= "" and ui.label({ text = fileName(draft.image), flexGrow = 1,
        maxLines = 1, fontSize = 10, color = "on_surface_variant" })
        or ui.label({ text = tr("picker.none", "No image selected"), flexGrow = 1,
          fontSize = 10, color = "on_surface_variant" }),
    }
    if draft.image ~= "" then
      table.insert(imageRowChildren, ui.button({ glyph = "close", variant = "ghost", width = 30, height = 30,
        tooltip = tr("picker.remove", "Remove image"), onClick = function() draft.image = ""; render() end }))
    end
    table.insert(fields, ui.row({ gap = 6, align = "center" }, imageRowChildren))
    table.insert(fields, fieldLabel(tr("form.description", "Description")))
    table.insert(fields, ui.input({ key = "description-" .. key, value = draft.description, controlSize = "sm",
      placeholder = tr("form.description-placeholder", "A short summary"),
      onChange = function(value) draft.description = value end }))
    table.insert(fields, ui.separator({ spacing = 4 }))
    table.insert(fields, ui.row({ align = "center", justify = "space_between" }, {
      fieldLabel(tr("form.progress", "Reading progress")),
      ui.label({ text = tostring(math.floor(tonumber(draft.progress) or 0)) .. "%",
        fontSize = 10, color = "primary" }),
    }))
    table.insert(fields, ui.slider({ key = "progress-" .. key, min = 0, max = 100, step = 5,
      value = tonumber(draft.progress) or 0, onChange = function(value)
        draft.progress = tonumber(value) or 0
        render()
      end }))
    if draft.type == "book" then
      table.insert(fields, ui.row({ gap = 8, align = "center" }, {
        ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
          fieldLabel(tr("form.current-page", "Current page")),
          ui.input({ key = "current-page-" .. key, value = draft.currentPage, controlSize = "sm",
            onChange = function(value) draft.currentPage = value end }),
        }),
        ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
          fieldLabel(tr("form.total-pages", "Total pages")),
          ui.input({ key = "total-pages-" .. key, value = draft.totalPages, controlSize = "sm",
            onChange = function(value) draft.totalPages = value end }),
        }),
      }))
    end
    table.insert(fields, ui.row({ gap = 8, align = "center" }, {
      ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
        fieldLabel(tr("form.rating", "Rating")),
        ui.select({ key = "rating-" .. key, options = RATING_OPTIONS, controlSize = "sm",
          selectedIndex = math.floor(tonumber(draft.rating) or 0),
          onChange = function(index, _text) draft.rating = tonumber(index) or 0; render() end }),
      }),
      ui.column({ flexGrow = 1, gap = 3, align = "stretch" }, {
        fieldLabel(tr("form.estimated-minutes", "Estimated minutes")),
        ui.input({ key = "minutes-" .. key, value = draft.estimatedMinutes, controlSize = "sm",
          onChange = function(value) draft.estimatedMinutes = value end }),
      }),
    }))
    table.insert(fields, fieldLabel(tr("form.review", "Review")))
    table.insert(fields, ui.input({ key = "review-" .. key, value = draft.review,
      placeholder = tr("form.review-placeholder", "What did you think?"), multiline = true, height = 76,
      onChange = function(value) draft.review = value end }))
    table.insert(fields, fieldLabel(tr("form.notes", "Notes")))
    table.insert(fields, ui.input({ key = "notes-" .. key, value = draft.notes,
      placeholder = tr("form.notes-placeholder", "Your notes are saved below the frontmatter"),
      multiline = true, height = 100, onChange = function(value) draft.notes = value end }))
  end

  local footer
  if pendingDelete and editingId ~= nil then
    footer = ui.row({ gap = 6, align = "center", justify = "space_between" }, {
      ui.label({ text = tr("panel.confirm-delete", "Delete this item?"), color = "on_surface_variant" }),
      ui.row({ gap = 4 }, {
        ui.button({ text = tr("panel.cancel", "Cancel"), variant = "ghost", controlSize = "sm",
          onClick = function() pendingDelete = false; render() end }),
        ui.button({ glyph = "trash", text = tr("panel.delete", "Delete"), variant = "destructive", controlSize = "sm",
          onClick = function() send({ op = "remove", id = editingId }); leaveEditor() end }),
      }),
    })
  else
    local footerLeft = {}
    if editingId ~= nil then
      table.insert(footerLeft, ui.button({ glyph = "trash", variant = "ghost", width = 30, height = 30,
        glyphSize = 15, tooltip = tr("panel.delete", "Delete"),
        onClick = function() pendingDelete = true; render() end }))
      table.insert(footerLeft, ui.button({ glyph = "file-text", variant = "ghost", width = 30, height = 30,
        glyphSize = 15, tooltip = tr("obsidian.open-note", "Open note"), onClick = function()
          local item = findItem(editingId)
          if item ~= nil and type(item.notePath) == "string" and item.notePath ~= "" then
            noctalia.runAsync({ "xdg-open", item.notePath })
          end
        end }))
      table.insert(footerLeft, ui.button({ glyph = "refresh", variant = "ghost", width = 30, height = 30,
        glyphSize = 15, tooltip = tr("panel.refresh", "Refresh details"), enabled = draft.url ~= "",
        onClick = function() send({ op = "refresh_metadata", id = editingId }) end }))
    end
    local footerActions = {}
    table.insert(footerActions, ui.button({ text = tr("panel.cancel", "Cancel"), variant = "ghost",
      controlSize = "sm", onClick = leaveEditor }))
    table.insert(footerActions, ui.button({ glyph = "check", text = tr("panel.save", "Save"),
      variant = "primary", controlSize = "sm", onClick = saveDraft }))
    footer = ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 4 }, footerLeft),
      ui.row({ gap = 4 }, footerActions),
    })
  end

  return ui.column({ flexGrow = 1, gap = 8, align = "stretch" }, {
    ui.scroll({ key = "editor-scroll-" .. key, flexGrow = 1, gap = 5, align = "stretch" }, fields),
    ui.separator({}), footer,
  })
end

local function shareMarkdown()
  local lines = { "# Reading List", "" }
  for _, id in ipairs(shareIds) do
    local item = findItem(id)
    if item ~= nil then
      local title = item.title ~= "" and item.title or item.url
      table.insert(lines, item.url ~= "" and ("- [" .. title:gsub("%]", "\\]") .. "](" .. item.url .. ")")
        or ("- " .. title))
      if shareIncludeNotes and item.notes ~= "" then
        table.insert(lines, "  - Notes: " .. item.notes:gsub("\n", " "))
      end
    end
  end
  return table.concat(lines, "\n")
end

local function shareView()
  return ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 8 }, {
    ui.column({ fill = "surface_variant", radius = 10, padding = 12, gap = 8, align = "stretch" }, {
      ui.glyph({ name = "share", size = 32, color = "primary" }),
      ui.label({ text = tr("share.count", "Sharing {count} items", { count = #shareIds }),
        fontSize = 14, fontWeight = "semibold", textAlign = "center" }),
      ui.label({ text = tr("share.description", "Export the current filter or selected items."),
        fontSize = 10, color = "on_surface_variant", textAlign = "center" }),
    }),
    ui.button({ glyph = "file-import", text = tr("import.action", "Import file"),
      variant = "outline", controlSize = "sm", contentAlign = "start",
      enabled = not pickingImport, onClick = chooseImport }),
    fieldLabel(tr("share.format", "Export format")),
    ui.select({ key = "share-format", options = SHARE_OPTIONS, controlSize = "sm",
      selectedIndex = indexOf(SHARE_VALUES, shareFormat), onChange = function(index, _text)
        shareFormat = SHARE_VALUES[(tonumber(index) or 0) + 1] or "md"
        render()
      end }),
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("share.include-notes", "Include private notes"), fontSize = 11 }),
      ui.toggle({ checked = shareIncludeNotes, onChange = function(value)
        shareIncludeNotes = value == "true"
        render()
      end }),
    }),
    ui.label({ text = tr("share.privacy", "Notes are excluded by default."),
      fontSize = 9, color = "on_surface_variant" }),
    ui.spacer({ flexGrow = 1 }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ glyph = "copy", text = tr("share.copy", "Copy Markdown"), variant = "outline",
        flexGrow = 1, controlSize = "sm",
        onClick = function()
          if noctalia.copyToClipboard(shareMarkdown(), "text/markdown") then
            noctalia.notify(tr("share.copied-title", "Reading list copied"),
              tr("share.copied", "Markdown is ready to paste."))
          end
        end }),
      ui.button({ glyph = "file-export", text = tr("share.export", "Export file"), variant = "primary",
        flexGrow = 1, controlSize = "sm",
        onClick = function()
          send({ op = "export", ids = shareIds, format = shareFormat, includeNotes = shareIncludeNotes })
        end }),
    }),
  })
end

local function reportCutoff()
  local now = os.time()
  if reportRange == "7days" then return now - (7 * 86400) end
  if reportRange == "30days" then return now - (30 * 86400) end
  return 0
end

local function reportData()
  local result = {
    statuses = { unread = 0, reading = 0, read = 0, archived = 0 },
    completed = {}, minutes = 0, pages = 0, ratingTotal = 0, ratingCount = 0,
    topics = {}, collections = {},
  }
  local cutoff = reportCutoff()
  for _, item in ipairs(items) do
    local status = item.status or "unread"
    result.statuses[status] = (result.statuses[status] or 0) + 1
    local finishedAt = tonumber(item.finishedAt) or 0
    if finishedAt > 0 and finishedAt >= cutoff then
      table.insert(result.completed, item)
      result.minutes += math.max(0, tonumber(item.estimatedMinutes) or 0)
      if item.type == "book" then
        local totalPages = tonumber(item.totalPages) or 0
        result.pages += math.max(0, totalPages > 0 and totalPages or (tonumber(item.currentPage) or 0))
      end
      local rating = tonumber(item.rating) or 0
      if rating > 0 then
        result.ratingTotal += rating
        result.ratingCount += 1
      end
      for _, topic in ipairs(item.topics or {}) do result.topics[topic] = (result.topics[topic] or 0) + 1 end
      for _, collection in ipairs(item.collections or {}) do
        result.collections[collection] = (result.collections[collection] or 0) + 1
      end
    end
  end
  table.sort(result.completed, function(a, b) return (a.finishedAt or 0) > (b.finishedAt or 0) end)
  result.averageRating = result.ratingCount > 0 and (result.ratingTotal / result.ratingCount) or 0
  return result
end

local function metricCard(value, label, glyph)
  return ui.column({ flexGrow = 1, fill = "surface_variant", radius = 9,
    padding = 9, gap = 2, align = "stretch" }, {
    ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = glyph, size = 15, color = "primary" }),
      ui.label({ text = tostring(value), fontSize = 16, fontWeight = "bold" }),
    }),
    ui.label({ text = label, fontSize = 9, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function rankedValues(values)
  local result = {}
  for name, count in pairs(values) do table.insert(result, { name = name, count = count }) end
  table.sort(result, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name:lower() < b.name:lower()
  end)
  return result
end

local function rankingCard(title, glyph, values)
  local ranked = rankedValues(values)
  local children = {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 15, color = "primary" }),
      ui.label({ text = title, fontSize = 11, fontWeight = "semibold" }),
    }),
  }
  if #ranked == 0 then
    table.insert(children, ui.label({ text = tr("reports.no-data", "No data for this period."),
      fontSize = 9, color = "on_surface_variant" }))
  else
    local maximum = ranked[1].count
    for index, entry in ipairs(ranked) do
      if index > 3 then break end
      table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = entry.name, width = 88, maxLines = 1, fontSize = 9,
          color = "on_surface_variant" }),
        ui.progress({ progress = entry.count / maximum, flexGrow = 1, height = 4,
          fill = "primary", track = "outline/0.25", radius = 3 }),
        ui.label({ text = tostring(entry.count), width = 18, textAlign = "end", fontSize = 9 }),
      }))
    end
  end
  return ui.column({ flexGrow = 1, fill = "surface_variant", radius = 9,
    padding = 9, gap = 6, align = "stretch" }, children)
end

local function reportsView()
  local report = reportData()
  local average = report.ratingCount > 0 and string.format("%.1f", report.averageRating) or "—"
  local content = {
    ui.row({ gap = 7, align = "center" }, {
      ui.label({ text = tr("reports.period", "Report period"), flexGrow = 1,
        fontSize = 10, color = "on_surface_variant" }),
      ui.select({ key = "report-range", options = reportRangeOptions(), width = 170, controlSize = "sm",
        selectedIndex = indexOf(REPORT_RANGE_VALUES, reportRange), onChange = function(index, _text)
          reportRange = REPORT_RANGE_VALUES[(tonumber(index) or 0) + 1] or "30days"
          render()
        end }),
    }),
    ui.label({ text = tr("reports.library", "Library overview"), fontSize = 11, fontWeight = "semibold" }),
    ui.row({ gap = 6, align = "stretch" }, {
      metricCard(report.statuses.unread, tr("status.unread", "Unread"), "circle"),
      metricCard(report.statuses.reading, tr("status.reading", "Reading"), "book-open"),
      metricCard(report.statuses.read, tr("status.read", "Read"), "circle-check-filled"),
      metricCard(report.statuses.archived, tr("status.archived", "Archived"), "archive"),
    }),
    ui.label({ text = tr("reports.activity", "Completed in this period"),
      fontSize = 11, fontWeight = "semibold" }),
    ui.row({ gap = 6, align = "stretch" }, {
      metricCard(#report.completed, tr("reports.items", "Items"), "books"),
      metricCard(report.minutes, tr("reports.minutes", "Estimated minutes"), "clock"),
      metricCard(report.pages, tr("reports.pages", "Book pages"), "file-text"),
      metricCard(average, tr("reports.average-rating", "Average rating"), "star"),
    }),
    ui.row({ gap = 6, align = "stretch" }, {
      rankingCard(tr("reports.top-topics", "Top topics"), "tags", report.topics),
      rankingCard(tr("reports.top-collections", "Top collections"), "folders", report.collections),
    }),
    ui.label({ text = tr("reports.recent", "Recent completions"),
      fontSize = 11, fontWeight = "semibold" }),
  }
  if #report.completed == 0 then
    table.insert(content, ui.column({ fill = "surface_variant", radius = 9, padding = 14,
      gap = 5, align = "center" }, {
      ui.glyph({ name = "calendar-off", size = 22, color = "on_surface_variant" }),
      ui.label({ text = tr("reports.no-completions", "Nothing completed in this period yet."),
        fontSize = 9, color = "on_surface_variant", textAlign = "center" }),
    }))
  else
    for index, item in ipairs(report.completed) do
      if index > 5 then break end
      table.insert(content, ui.row({ fill = "surface_variant", radius = 8, padding = 8,
        gap = 7, align = "center" }, {
        ui.glyph({ name = typeGlyph(item.type), size = 15, color = "primary" }),
        ui.column({ flexGrow = 1, gap = 1, align = "stretch" }, {
          ui.label({ text = item.title ~= "" and item.title or item.url,
            fontSize = 10, fontWeight = "medium", maxLines = 1 }),
          ui.label({ text = formatDate(item.finishedAt), fontSize = 8, color = "on_surface_variant" }),
        }),
        (item.rating or 0) > 0 and ui.label({ text = tostring(item.rating) .. "★",
          fontSize = 9, color = "primary" }) or ui.spacer({ width = 1 }),
      }))
    end
  end
  return ui.scroll({ key = "reports-scroll-" .. reportRange, flexGrow = 1,
    gap = 8, padding = 4, align = "stretch" }, content)
end

local function unreadCount()
  local count = 0
  for _, item in ipairs(items) do if item.status == "unread" then count += 1 end end
  return count
end

function render()
  local editing = view == "edit" and draft ~= nil
  local inSubview = view ~= "list"
  local title = view == "share" and tr("share.title", "Share and export")
    or (view == "reports" and tr("reports.title", "Reports"))
    or (editing and (editingId and tr("panel.edit-item", "Edit item") or tr("panel.add-item", "Add item"))
    or tr("panel.title", "Reading List"))
  local titleChildren = {
    ui.label({ text = title, fontSize = 14, fontWeight = "bold" }),
  }
  if not inSubview then
    table.insert(titleChildren, ui.label({ text = tr("panel.count", "{count} saved · {unread} unread", {
      count = #items, unread = unreadCount(),
    }), fontSize = 9, color = "on_surface_variant" }))
  end

  local headerActions = {}
  if not inSubview then
    table.insert(headerActions, ui.button({ glyph = "clipboard-plus", variant = "ghost",
      width = 30, height = 30, glyphSize = 16,
      tooltip = clipboardUrl() ~= "" and tr("panel.quick-add", "Add clipboard URL")
        or tr("panel.quick-add-empty", "Clipboard has no URL — open add form"),
      onClick = quickAddFromClipboard }))
    table.insert(headerActions, ui.button({ glyph = "plus", variant = "primary",
      width = 32, height = 32, glyphSize = 17,
      tooltip = tr("panel.add-manually", "Add manually"), onClick = startAdd }))
    table.insert(headerActions, ui.button({ glyph = "list-check", variant = selectionMode and "outline" or "ghost",
      width = 30, height = 30, glyphSize = 16, tooltip = tr("bulk.select-mode", "Select items"),
      onClick = function()
        selectionMode = not selectionMode
        if not selectionMode then selectedIds = {}; bulkDeleteArmed = false end
        render()
      end }))
    table.insert(headerActions, ui.button({ glyph = "chart-bar", variant = "ghost", width = 30, height = 30,
      glyphSize = 16, tooltip = tr("reports.title", "Reports"), onClick = function()
        view = "reports"
        render()
      end }))
    table.insert(headerActions, ui.button({ glyph = "share", variant = "ghost", width = 30, height = 30,
      glyphSize = 16, tooltip = tr("share.title", "Share and export"),
      enabled = #filteredItems() > 0, onClick = startShare }))
  end
  table.insert(headerActions, ui.button({ glyph = "settings", variant = "ghost", width = 30, height = 30,
    glyphSize = 16, tooltip = tr("panel.settings", "Settings"),
    onClick = function() noctalia.openSettings() end }))
  table.insert(headerActions, ui.button({ glyph = "close", variant = "ghost", width = 30, height = 30,
    glyphSize = 16, tooltip = tr("panel.close", "Close"), onClick = function() panel.close() end }))

  local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      inSubview and ui.button({ glyph = "arrow-left", variant = "ghost", controlSize = "sm",
        onClick = function()
          if view == "edit" then leaveEditor() else view = "list"; render() end
        end })
        or ui.glyph({ name = "bookmarks", size = 21, color = "primary" }),
      ui.column({ gap = 0, flexGrow = 1 }, titleChildren),
    }),
    ui.row({ gap = 2, align = "center" }, headerActions),
  })

  local children = { header, ui.separator({}) }
  if serviceError ~= "" then
    table.insert(children, ui.row({ fill = "error_container", radius = 8, padding = 8, gap = 6, align = "center" }, {
      ui.glyph({ name = "alert-circle", size = 18, color = "on_error_container" }),
      ui.label({ text = serviceError, flexGrow = 1, maxLines = 2, color = "on_error_container", fontSize = 10 }),
      ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = function() send({ op = "clear_error" }) end }),
    }))
  end
  if view == "share" then
    table.insert(children, shareView())
  elseif view == "reports" then
    table.insert(children, reportsView())
  elseif editing then
    table.insert(children, editorView())
  else
    table.insert(children, listView())
  end
  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 10, align = "stretch" }, children))
end

noctalia.state.watch("reading_list.items", function(value)
  items = type(value) == "table" and value or {}
  for id, _ in pairs(selectedIds) do if findItem(id) == nil then selectedIds[id] = nil end end
  if editingId ~= nil and findItem(editingId) == nil then leaveEditor() else render() end
end)
noctalia.state.watch("reading_list.collections", function(value)
  managedCollections = type(value) == "table" and value or {}
  render()
end)
noctalia.state.watch("reading_list.ready", function(value) ready = value == true; render() end)
noctalia.state.watch("reading_list.error", function(value) serviceError = value or ""; render() end)
noctalia.state.watch("reading_list.export_path", function(value)
  local path = type(value) == "string" and value or ""
  if path ~= "" and path ~= lastExportPath then
    lastExportPath = path
    noctalia.notify(tr("share.exported-title", "Reading list exported"),
      tr("share.exported", "Saved to {path}", { path = path }))
  end
end)
noctalia.state.watch("reading_list.import_result", function(value)
  if type(value) ~= "table" then return end
  local summary = tostring(value.added or 0) .. ":" .. tostring(value.skipped or 0)
  if summary ~= lastImportSummary then
    lastImportSummary = summary
    noctalia.notify(tr("import.done-title", "Import complete"),
      tr("import.done", "Added {added}; skipped {skipped} duplicates.", {
        added = value.added or 0, skipped = value.skipped or 0,
      }))
  end
end)

function onOpen(_context)
  if panelClosedForPicker and draft ~= nil then
    panelClosedForPicker = false
    view = "edit"
    render()
    return
  end
  panelClosedForPicker = false
  view = "list"; editingId = nil; draft = nil; pendingDelete = false; pendingCardDeleteId = nil
  send({ op = "sync" })
  render()
end

function onClose()
  if pickingImage or pickingImport then
    panelClosedForPicker = true
    return
  end
  view = "list"; editingId = nil; draft = nil; pendingDelete = false
  pendingCardDeleteId = nil; showAdvanced = false; panelClosedForPicker = false
  selectionMode = false; selectedIds = {}; bulkDeleteArmed = false
end

render()
