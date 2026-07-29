--!nonstrict

local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true, jxl = true, bmp = true }
local VIDEO_EXTENSIONS = { mp4 = true, mkv = true, webm = true, mov = true, avi = true, m4v = true, gif = true }
local GRID_BATCH_SIZE = 12
local PAGE_SIZE = 24

local filter = "all"
local search = ""
local page = 1
local currentRoot = nil
local currentDirectory = nil
local entries = {}
local scanError = nil
local library = noctalia.state.get("library") or {}
local libraryStatus = noctalia.state.get("library_status") or { phase = "scanning" }
local scanning = libraryStatus.phase == "scanning"
local assignments = noctalia.state.get("assignments") or {}
local runtime = noctalia.state.get("runtime") or {}
local capabilities = noctalia.state.get("capabilities") or { video = false, checking = true }
local outputs = noctalia.state.get("outputs") or {}
local commandResult = noctalia.state.get("command_result")
local selectedOutput = "*"
local nonceCounter = 0
local outputOptions = {}
local folderEntries = {}
local gridRows = nil
local gridBuilding = false
local gridGeneration = 0
local gridProgress = 0
local indexBuilding = false
local indexGeneration = 0
local indexProgress = 0
local loadedLibraryVersion = nil
local viewMedia = {}
local viewDirectories = {}
local viewBuilding = false
local viewDirty = true
local viewGeneration = 0
local viewProgress = 0
local loadingPulse = 0
local loadingElapsed = 0
local render

local function tr(key, substitutions)
    return noctalia.tr(key, substitutions)
end

local function trimTrailingSlash(path)
    if type(path) ~= "string" then
        return nil
    end
    path = path:gsub("/+$", "")
    return path == "" and "/" or path
end

local function classifyName(name)
    if type(name) ~= "string" then
        return nil
    end
    local extension = name:match("%.([^./]+)$")
    extension = extension and extension:lower() or nil
    if extension == "gif" then
        return "video"
    elseif extension and IMAGE_EXTENSIONS[extension] then
        return "image"
    elseif extension and VIDEO_EXTENSIONS[extension] then
        return "video"
    end
    return nil
end

local function safeChild(root, directory, name)
    root = trimTrailingSlash(root)
    directory = trimTrailingSlash(directory)
    if not root or not directory or type(name) ~= "string" or name == "" or name == "." or name == ".."
        or name:find("/", 1, true) or name:find("[\n\r%z]") then
        return nil
    end
    if directory ~= root and directory:sub(1, #root + 1) ~= root .. "/" then
        return nil
    end
    return (directory == "/" and "" or directory) .. "/" .. name
end

local function sortEntries(values)
    table.sort(values, function(left, right)
        if left.kind == "directory" and right.kind ~= "directory" then
            return true
        elseif left.kind ~= "directory" and right.kind == "directory" then
            return false
        end
        local leftName = left.name:lower()
        local rightName = right.name:lower()
        return leftName == rightName and left.name < right.name or leftName < rightName
    end)
end

local function assignmentMatchCount(values, connectors, path)
    local count = 0
    for _, connector in ipairs(connectors or {}) do
        if values[connector] and values[connector].path == path then
            count = count + 1
        end
    end
    return count
end

local function mixedCounts(values, connectors)
    local counts = { video = 0, image = 0, unassigned = 0 }
    for _, connector in ipairs(connectors or {}) do
        local assignment = values[connector]
        if assignment and assignment.kind == "video" then
            counts.video = counts.video + 1
        elseif assignment and assignment.kind == "image" then
            counts.image = counts.image + 1
        else
            counts.unassigned = counts.unassigned + 1
        end
    end
    return counts
end

local function videoPlaybackAction(values, liveState, connectors)
    local videoCount = 0
    for _, connector in ipairs(connectors or {}) do
        if values[connector] and values[connector].kind == "video" then
            videoCount = videoCount + 1
            if not liveState[connector] or liveState[connector].status ~= "paused" then
                return "pause"
            end
        end
    end
    return videoCount > 0 and "resume" or "pause"
end

local function fnv1a32(value)
    -- ponytail: this mirrors the service cache key; use a wider digest if a real collision appears.
    local hash = 2166136261
    for index = 1, #value do
        hash = bit32.bxor(hash, value:byte(index))
        local low = (hash % 65536) * 16777619
        local high = (math.floor(hash / 65536) * 16777619) % 65536
        hash = (low + high * 65536) % 4294967296
    end
    return string.format("%08x", hash)
end

local function thumbnailPath(path, size, mtime)
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    return directory .. "/thumb-" .. fnv1a32("v3:" .. path .. ":" .. tostring(size) .. ":" .. tostring(mtime)) .. ".jpg"
end

local function invalidateGrid()
    gridGeneration = gridGeneration + 1
    gridRows = nil
    gridBuilding = false
    gridProgress = 0
end

local function invalidateView()
    viewGeneration = viewGeneration + 1
    viewMedia = {}
    viewDirectories = {}
    viewBuilding = false
    viewDirty = true
    viewProgress = 0
    invalidateGrid()
end

local function nextNulField(raw, offset)
    local boundary = raw:find("\0", offset, true)
    if not boundary then
        return nil, offset
    end
    return raw:sub(offset, boundary - 1), boundary + 1
end

local function acceptsMedia(rootKind, kind, name)
    if rootKind == "mixed" or rootKind == "video" then
        return rootKind == "mixed" or kind == "video"
    end
    return kind == "image" or name:lower():match("%.gif$") ~= nil
end

local function finishIndexBuild(generation, value)
    if generation ~= indexGeneration then
        return
    end
    library = value
    loadedLibraryVersion = value.version
    indexBuilding = false
    indexProgress = 1
    invalidateView()
    local started = noctalia.runAsync(":", render, 2000)
    if not started then
        render()
    end
end

local function loadLibrary(value)
    if type(value) ~= "table" then
        return false
    end
    if value.version == loadedLibraryVersion and not indexBuilding then
        return true
    end
    if type(value.entries) == "table" then
        library = value
        entries = value.entries
        sortEntries(entries)
        loadedLibraryVersion = value.version
        indexBuilding = false
        invalidateView()
        return true
    end
    if type(value.sources) ~= "table" then
        return false
    end

    indexGeneration = indexGeneration + 1
    local generation = indexGeneration
    local tasks = {}
    local totalBytes = 0
    local consumedBytes = 0
    entries = {}
    indexBuilding = true
    indexProgress = 0
    for _, source in ipairs(value.sources) do
        local raw = noctalia.readFile(source.path)
        if type(raw) == "string" then
            totalBytes = totalBytes + #raw
            table.insert(tasks, {
                raw = raw,
                offset = 1,
                root = source.root,
                rootKind = source.rootKind,
            })
        else
            scanError = "Wallpaper index is unavailable"
        end
    end

    local processBatch
    processBatch = function()
        if generation ~= indexGeneration then
            return
        end
        local remaining = GRID_BATCH_SIZE
        while remaining > 0 and #tasks > 0 do
            local task = tasks[1]
            local previousOffset = task.offset
            local fileType
            fileType, task.offset = nextNulField(task.raw, task.offset)
            if not fileType then
                table.remove(tasks, 1)
            else
                local size
                local mtime
                local path
                size, task.offset = nextNulField(task.raw, task.offset)
                mtime, task.offset = nextNulField(task.raw, task.offset)
                path, task.offset = nextNulField(task.raw, task.offset)
                consumedBytes = consumedBytes + task.offset - previousOffset
                remaining = remaining - 1
                if path and utf8.len(path) ~= nil then
                    local name = path:match("([^/]+)$")
                    local parent = path:match("^(.*)/[^/]+$")
                    if fileType == "d" then
                        table.insert(entries, {
                            name = name,
                            path = path,
                            parent = parent,
                            kind = "directory",
                            root = task.root,
                            rootKind = task.rootKind,
                        })
                    elseif fileType == "f" then
                        local kind = classifyName(name)
                        if kind and acceptsMedia(task.rootKind, kind, name) then
                            local numericSize = tonumber(size) or 0
                            local numericMtime = tonumber(mtime) or 0
                            table.insert(entries, {
                                name = name,
                                path = path,
                                parent = parent,
                                kind = kind,
                                root = task.root,
                                rootKind = task.rootKind,
                                thumbnail = thumbnailPath(path, numericSize, numericMtime),
                            })
                        end
                    end
                end
            end
        end
        indexProgress = totalBytes > 0 and math.min(1, consumedBytes / totalBytes) or 1
        if #tasks == 0 then
            finishIndexBuild(generation, value)
            return
        end
        local started = noctalia.runAsync(":", processBatch, 2000)
        if not started then
            indexBuilding = false
            scanError = "Noctalia command capacity is busy"
            render()
        end
    end

    processBatch()
    return true
end

local function partitionEntries(values, needle)
    local directories = {}
    local media = {}
    needle = tostring(needle or ""):lower()
    for _, entry in ipairs(values or {}) do
        local inDirectory = currentDirectory and entry.parent == currentDirectory or not currentDirectory and entry.parent == entry.root
        if inDirectory and entry.kind == "directory" then
            table.insert(directories, entry)
        elseif inDirectory
            and (filter == "all" or filter == "images" and entry.kind == "image" or filter == "videos" and entry.kind == "video")
            and (needle == "" or entry.name:lower():find(needle, 1, true)) then
            table.insert(media, entry)
        end
    end
    return directories, media
end

local function beginViewBuild()
    viewGeneration = viewGeneration + 1
    local generation = viewGeneration
    local index = 1
    local needle = search:lower()
    viewMedia = {}
    viewDirectories = {}
    viewBuilding = true
    viewDirty = false
    viewProgress = 0

    local processBatch
    processBatch = function()
        if generation ~= viewGeneration then
            return
        end
        local last = math.min(#entries, index + GRID_BATCH_SIZE - 1)
        while index <= last do
            local entry = entries[index]
            local inDirectory = currentDirectory and entry.parent == currentDirectory
                or not currentDirectory and entry.parent == entry.root
            if inDirectory and entry.kind == "directory" then
                table.insert(viewDirectories, entry)
            elseif inDirectory
                and (filter == "all" or filter == "images" and entry.kind == "image"
                    or filter == "videos" and entry.kind == "video")
                and (needle == "" or entry.name:lower():find(needle, 1, true)) then
                table.insert(viewMedia, entry)
            end
            index = index + 1
        end
        viewProgress = #entries == 0 and 1 or math.min(1, (index - 1) / #entries)
        if index > #entries then
            sortEntries(viewDirectories)
            sortEntries(viewMedia)
            viewBuilding = false
            invalidateGrid()
            render()
            return
        end
        local started = noctalia.runAsync(":", processBatch, 2000)
        if not started then
            viewBuilding = false
            scanError = "Noctalia command capacity is busy"
            render()
        end
    end

    processBatch()
end

local function paginate(values, requestedPage)
    local pages = math.max(1, math.ceil(#values / PAGE_SIZE))
    local currentPage = math.max(1, math.min(requestedPage, pages))
    local first = (currentPage - 1) * PAGE_SIZE + 1
    local visible = {}
    for index = first, math.min(#values, first + PAGE_SIZE - 1) do
        table.insert(visible, values[index])
    end
    return visible, currentPage, pages
end

local function visibleEntries()
    local visible, currentPage, pages = paginate(viewMedia, page)
    page = currentPage
    return visible, #viewMedia, pages, viewDirectories
end

local function connectorNames()
    local names = {}
    for _, output in ipairs(outputs or {}) do
        local name = type(output) == "table" and output.name or output
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local function nextNonce()
    nonceCounter = nonceCounter + 1
    return noctalia.nowMs() * 1000 + nonceCounter
end

local function sendCommand(action, entry)
    local command = {
        nonce = nextNonce(),
        action = action,
        target = action == "restore-all" and "*" or selectedOutput,
    }
    if entry then
        command.path = entry.path
        command.preview_path = entry.thumbnail and noctalia.fileExists(entry.thumbnail) and entry.thumbnail or nil
    end
    noctalia.state.set("command", command)
end

local function selectedConnectors()
    return selectedOutput == "*" and connectorNames() or { selectedOutput }
end

local function selectionBusy()
    for _, connector in ipairs(selectedConnectors()) do
        if runtime[connector] and runtime[connector].status == "starting" then
            return true
        end
    end
    return false
end

local function navigateDirectory(entry)
    if type(entry) ~= "table" or entry.kind ~= "directory"
        or type(entry.root) ~= "string" or type(entry.path) ~= "string"
        or (entry.path ~= entry.root and entry.path:sub(1, #entry.root + 1) ~= entry.root .. "/") then
        scanError = tr("panel.navigation_blocked")
        render()
        return
    end
    currentRoot = { kind = entry.rootKind, path = entry.root }
    currentDirectory = entry.path
    search = ""
    page = 1
    scanError = libraryStatus.error
    invalidateView()
    render()
end

local function navigateUp()
    if not currentDirectory or not currentRoot then
        return
    end
    if currentDirectory == currentRoot.path then
        currentDirectory = nil
        currentRoot = nil
    else
        local parent = currentDirectory:match("^(.*)/[^/]+$")
        if not parent or parent == currentRoot.path then
            currentDirectory = nil
            currentRoot = nil
        else
            currentDirectory = parent
        end
    end
    search = ""
    page = 1
    invalidateView()
    render()
end

local function tileFor(entry, connectors)
    local matches = assignmentMatchCount(assignments, connectors, entry.path)
    local selected = #connectors > 0 and matches == #connectors
    local videoDisabled = entry.kind == "video" and not capabilities.video
    local busy = selectionBusy()
    local choose
    if not videoDisabled and not busy then
        choose = function()
            sendCommand(entry.kind == "image" and "assign-image" or "assign-video", entry)
        end
    end
    local preview
    if entry.thumbnail and noctalia.fileExists(entry.thumbnail) then
        preview = ui.image({
            path = entry.thumbnail,
            height = 96,
            fit = "cover",
            radius = 8,
            border = selected and "primary" or "outline/0.45",
            borderWidth = selected and 2 or 1,
            onClick = choose,
        })
    else
        preview = ui.button({
            height = 96,
            glyph = entry.kind == "image" and "photo" or "player-play",
            glyphSize = 36,
            variant = "ghost",
            enabled = choose ~= nil,
            selected = selected,
            onClick = choose,
        })
    end

    local detail = entry.name
    if entry.kind == "video" then
        detail = tr("panel.video_badge") .. " · " .. detail
    end
    if selectedOutput == "*" and matches > 0 and matches < #connectors then
        detail = detail .. " · " .. tr("panel.partial_badge", { count = matches, total = #connectors })
    end

    return ui.column({
        key = entry.path,
        width = 210,
        gap = 5,
        opacity = videoDisabled and 0.55 or 1,
    }, {
        preview,
        ui.label({
            text = detail,
            maxLines = 1,
            fontSize = 11,
            color = entry.kind == "video" and "secondary" or "on_surface",
        }),
    })
end

local function beginGridBuild(values, connectors)
    gridGeneration = gridGeneration + 1
    local generation = gridGeneration
    gridRows = {}
    gridBuilding = true
    gridProgress = 0
    local index = 1
    local row = {}

    local processBatch
    processBatch = function()
        if generation ~= gridGeneration then
            return
        end
        local last = math.min(#values, index + GRID_BATCH_SIZE - 1)
        while index <= last do
            table.insert(row, tileFor(values[index], connectors))
            if #row == 4 then
                table.insert(gridRows, ui.row({ gap = 10, align = "start" }, row))
                row = {}
            end
            index = index + 1
        end
        gridProgress = #values == 0 and 1 or math.min(1, (index - 1) / #values)
        if index > #values then
            if #row > 0 then
                table.insert(gridRows, ui.row({ gap = 10, align = "start" }, row))
            end
            gridBuilding = false
            render()
            return
        end
        local started = noctalia.runAsync(":", function()
            processBatch()
        end, 2000)
        if not started then
            gridBuilding = false
            scanError = "Noctalia command capacity is busy"
            render()
        end
    end

    processBatch()
end

local function loadingState(label, progress)
    local rows = {}
    for rowIndex = 1, 2 do
        local cards = {}
        for cardIndex = 1, 4 do
            local offset = ((rowIndex - 1) * 4 + cardIndex - 1) * 0.08
            local opacity = 0.22 + 0.28 * math.abs(math.sin((loadingPulse + offset) * math.pi))
            table.insert(cards, ui.column({
                width = 210,
                height = 128,
                radius = 10,
                fill = "surface_variant",
                opacity = opacity,
            }))
        end
        table.insert(rows, ui.row({ gap = 10 }, cards))
    end
    return ui.column({ flexGrow = 1, gap = 10, justify = "center" }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = label, color = "on_surface_variant", flexGrow = 1 }),
            ui.label({ text = tostring(math.floor(progress * 100)) .. "%", color = "on_surface_variant", fontSize = 11 }),
        }),
        ui.progress({ height = 4, progress = progress, fill = "primary", track = "surface_variant", radius = 2 }),
        ui.column({ gap = 10 }, rows),
    })
end

local function folderStrip(directories)
    if #directories == 0 then
        folderEntries = {}
        return nil
    end
    folderEntries = directories
    local options = { tr("panel.folders") }
    for _, entry in ipairs(directories) do
        table.insert(options, entry.name)
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "folder", color = "on_surface_variant", size = 18 }),
        ui.select({
            options = options,
            selectedIndex = 0,
            flexGrow = 1,
            onChange = "onFolderChanged",
        }),
    })
end

local function activeStrip(connectors)
    if selectedOutput == "*" then
        local counts = mixedCounts(assignments, connectors)
        local playbackAction = videoPlaybackAction(assignments, runtime, connectors)
        return ui.row({ align = "center", gap = 8, padding = 9, radius = 9, fill = "surface_variant/0.40" }, {
            ui.glyph({ name = "devices", color = "primary", size = 18 }),
            ui.label({
                text = tr("panel.mixed_summary", {
                    outputs = #connectors,
                    videos = counts.video,
                    images = counts.image,
                }),
                flexGrow = 1,
                maxLines = 1,
            }),
            ui.button({
                text = tr(playbackAction == "resume" and "panel.resume_videos" or "panel.pause_videos"),
                variant = "ghost",
                enabled = counts.video > 0 and not selectionBusy(),
                onClick = function() sendCommand(playbackAction) end,
            }),
            ui.button({
                text = tr("panel.restore_all"),
                variant = "ghost",
                enabled = #connectors > 0 and not selectionBusy(),
                onClick = function() sendCommand("restore-all") end,
            }),
        })
    end

    local assignment = assignments[selectedOutput]
    local live = runtime[selectedOutput]
    if not assignment then
        return nil
    end
    local isVideo = assignment.kind == "video"
    local paused = live and live.status == "paused"
    return ui.row({ align = "center", gap = 8, padding = 9, radius = 9, fill = "surface_variant/0.40" }, {
        ui.glyph({ name = isVideo and "movie" or "photo", color = isVideo and "secondary" or "primary", size = 18 }),
        ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({ text = assignment.path:match("([^/]+)$") or assignment.path, fontWeight = "bold", maxLines = 1 }),
            ui.label({
                text = live and tr("panel.status_" .. tostring(live.status)) or tr("panel.status_static"),
                fontSize = 10,
                color = live and live.error and "error" or "on_surface_variant",
            }),
        }),
        ui.button({
            text = tr(paused and "panel.resume" or "panel.pause"),
            variant = "ghost",
            visible = isVideo,
            enabled = live ~= nil and not selectionBusy(),
            onClick = function() sendCommand(paused and "resume" or "pause") end,
        }),
        ui.button({
            text = tr("panel.restore"),
            variant = "ghost",
            enabled = not selectionBusy(),
            onClick = function() sendCommand("restore") end,
        }),
    })
end

local function resultBanner()
    if not commandResult or type(commandResult.summary) ~= "table" then
        return nil
    end
    local summary = commandResult.summary
    if (summary.pending or 0) > 0 then
        return ui.label({ text = tr("panel.applying"), color = "on_surface_variant" })
    end
    local errors = {}
    for connector, result in pairs(commandResult.results or {}) do
        if result.ok == false then
            table.insert(errors, connector .. ": " .. tostring(result.error))
        end
    end
    table.sort(errors)
    if #errors > 0 then
        return ui.label({ text = table.concat(errors, "  ·  "), color = "error", maxLines = 2 })
    end
    return nil
end

render = function()
    if not scanning and not indexBuilding and viewDirty and not viewBuilding then
        beginViewBuild()
    end
    local visible, total, pages, directories = visibleEntries()
    local connectors = connectorNames()
    if not indexBuilding and not viewBuilding and total > 0 and gridRows == nil and not gridBuilding then
        beginGridBuild(visible, selectedConnectors())
    end
    local loading = scanning or indexBuilding or viewBuilding or gridBuilding
    panel.setNeedsFrameTick(loading)
    outputOptions = { tr("panel.all_outputs") }
    local selectedIndex = 0
    for index, connector in ipairs(connectors) do
        table.insert(outputOptions, connector)
        if selectedOutput == connector then
            selectedIndex = index
        end
    end
    if selectedOutput ~= "*" and selectedIndex == 0 then
        selectedOutput = "*"
    end

    local children = {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("panel.settings"), onClick = "onOpenSettings" }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = "onCloseClicked" }),
        }),
        ui.row({ align = "center", gap = 8 }, {
            ui.input({
                key = "search-" .. filter .. "-" .. selectedOutput,
                value = search,
                placeholder = tr("panel.search"),
                focus = true,
                flexGrow = 1,
                onChange = "onSearchChanged",
            }),
            ui.select({
                options = outputOptions,
                selectedIndex = selectedIndex,
                width = 170,
                onChange = "onOutputChanged",
            }),
        }),
        ui.row({ align = "center", gap = 6 }, {
            ui.button({ text = tr("panel.filter_all"), selected = filter == "all", variant = "ghost", onClick = "onFilterAll" }),
            ui.button({ text = tr("panel.filter_images"), selected = filter == "images", variant = "ghost", onClick = "onFilterImages" }),
            ui.button({ text = tr("panel.filter_videos"), selected = filter == "videos", variant = "ghost", onClick = "onFilterVideos" }),
            ui.spacer({ flexGrow = 1 }),
            ui.button({
                glyph = "arrow-up",
                text = tr("panel.up"),
                variant = "ghost",
                visible = currentDirectory ~= nil,
                onClick = "onNavigateUp",
            }),
        }),
    }

    local folders = folderStrip(directories)
    if folders then table.insert(children, folders) end

    if capabilities.checking then
        table.insert(children, ui.label({ text = tr("panel.checking_dependencies"), color = "on_surface_variant" }))
    elseif not capabilities.video then
        table.insert(children, ui.column({
            gap = 3,
            padding = 9,
            radius = 8,
            fill = "error/0.10",
            border = "error/0.45",
            borderWidth = 1,
        }, {
            ui.label({ text = tr("panel.video_unavailable"), color = "error", fontWeight = "bold" }),
            ui.label({ text = tostring(capabilities.error or ""), fontSize = 11, color = "on_surface_variant" }),
        }))
    end

    if scanError and total > 0 then
        table.insert(children, ui.label({
            text = tr("panel.directory_unreadable") .. ": " .. scanError,
            color = "error",
            maxLines = 2,
        }))
    end
    local active = activeStrip(connectors)
    if active then table.insert(children, active) end
    local result = resultBanner()
    if result then table.insert(children, result) end

    if scanning then
        local consumed = tonumber(libraryStatus.consumed_bytes) or 0
        local bytes = tonumber(libraryStatus.bytes) or 0
        table.insert(children, loadingState(tr("panel.scanning"), bytes > 0 and math.min(1, consumed / bytes) or 0))
    elseif scanError and total == 0 then
        table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "alert-circle", size = 32, color = "error" }),
            ui.label({ text = tr("panel.directory_unreadable"), color = "error", fontWeight = "bold" }),
            ui.label({ text = scanError, color = "on_surface_variant", maxLines = 2 }),
        }))
    elseif indexBuilding then
        table.insert(children, loadingState(tr("panel.preparing_library"), indexProgress))
    elseif viewBuilding then
        table.insert(children, loadingState(tr("panel.preparing_library"), viewProgress))
    elseif gridBuilding then
        table.insert(children, loadingState(tr("panel.preparing_library"), gridProgress))
    elseif total == 0 then
        table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
            ui.glyph({ name = "photo-off", size = 36, color = "outline" }),
            ui.label({
                text = search ~= "" and tr("panel.no_search_results") or tr("panel.directory_empty"),
                color = "on_surface_variant",
            }),
        }))
    else
        table.insert(children, ui.scroll({
            key = "media:" .. filter .. ":" .. tostring(currentDirectory or "") .. ":" .. tostring(page) .. ":" .. search,
            gap = 10,
            flexGrow = 1,
            align = "stretch",
        }, gridRows or {}))
    end

    if libraryStatus.phase == "thumbnails" and (libraryStatus.thumbnails_total or 0) > 0 then
        local done = tonumber(libraryStatus.thumbnails_done) or 0
        local thumbnails = tonumber(libraryStatus.thumbnails_total) or 0
        table.insert(children, ui.column({ gap = 4 }, {
            ui.label({
                text = tr("panel.generating_previews", { count = done, total = thumbnails }),
                color = "on_surface_variant",
                fontSize = 11,
            }),
            ui.progress({
                height = 3,
                progress = thumbnails > 0 and math.min(1, done / thumbnails) or 0,
                fill = "primary",
                track = "surface_variant",
                radius = 2,
            }),
        }))
    end

    table.insert(children, ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.media_count", { count = total }), color = "on_surface_variant", fontSize = 11, flexGrow = 1 }),
        ui.button({ glyph = "chevron-left", variant = "ghost", enabled = page > 1, onClick = "onPreviousPage" }),
        ui.label({ text = tr("panel.page", { page = page, pages = pages }), fontSize = 11 }),
        ui.button({ glyph = "chevron-right", variant = "ghost", enabled = page < pages, onClick = "onNextPage" }),
    }))
    panel.render(ui.column({ padding = 16, gap = 10, flexGrow = 1 }, children))
end

function onOpen(_context)
    outputs = noctalia.state.get("outputs") or noctalia.outputs() or {}
    assignments = noctalia.state.get("assignments") or {}
    runtime = noctalia.state.get("runtime") or {}
    capabilities = noctalia.state.get("capabilities") or capabilities
    libraryStatus = noctalia.state.get("library_status") or libraryStatus
    scanError = libraryStatus.error
    scanning = libraryStatus.phase == "scanning"
    loadLibrary(noctalia.state.get("library") or library)
    render()
end

function onCloseClicked()
    panel.close()
end

function onOpenSettings()
    noctalia.openSettings()
end

function onSearchChanged(value)
    search = tostring(value or "")
    page = 1
    invalidateView()
    render()
end

local function setFilter(value)
    filter = value
    currentDirectory = nil
    currentRoot = nil
    page = 1
    invalidateView()
    render()
end

function onFilterAll() setFilter("all") end
function onFilterImages() setFilter("images") end
function onFilterVideos() setFilter("videos") end

function onOutputChanged(index, _label)
    selectedOutput = index == 0 and "*" or outputOptions[index + 1] or "*"
    invalidateGrid()
    render()
end

function onNavigateUp() navigateUp() end

function onPreviousPage()
    page = math.max(1, page - 1)
    invalidateGrid()
    render()
end

function onNextPage()
    page = page + 1
    invalidateGrid()
    render()
end

function onFolderChanged(index, _label)
    if index > 0 and folderEntries[index] then
        navigateDirectory(folderEntries[index])
    end
end

function onFrameTick(deltaMs)
    if not scanning and not indexBuilding and not viewBuilding and not gridBuilding then
        panel.setNeedsFrameTick(false)
        return
    end
    loadingElapsed = loadingElapsed + (tonumber(deltaMs) or 0)
    if loadingElapsed >= 100 then
        loadingElapsed = loadingElapsed - 100
        loadingPulse = (loadingPulse + 0.08) % 1
        render()
    end
end

noctalia.state.watch("assignments", function(value)
    assignments = type(value) == "table" and value or {}
    invalidateGrid()
    render()
end)
noctalia.state.watch("runtime", function(value)
    runtime = type(value) == "table" and value or {}
    render()
end)
noctalia.state.watch("capabilities", function(value)
    capabilities = type(value) == "table" and value or capabilities
    invalidateGrid()
    render()
end)
noctalia.state.watch("outputs", function(value)
    outputs = type(value) == "table" and value or {}
    invalidateGrid()
    render()
end)
noctalia.state.watch("command_result", function(value)
    commandResult = value
    invalidateGrid()
    render()
end)
noctalia.state.watch("library", function(value)
    if loadLibrary(value) then
        scanError = libraryStatus.error
        render()
    end
end)
noctalia.state.watch("library_status", function(value)
    local previousPhase = libraryStatus.phase
    libraryStatus = type(value) == "table" and value or libraryStatus
    scanError = libraryStatus.error
    scanning = libraryStatus.phase == "scanning"
    if libraryStatus.phase == "ready" and previousPhase ~= "ready" then
        invalidateGrid()
    end
    render()
end)

return {
    classifyName = classifyName,
    safeChild = safeChild,
    sortEntries = sortEntries,
    fnv1a32 = fnv1a32,
    assignmentMatchCount = assignmentMatchCount,
    mixedCounts = mixedCounts,
    videoPlaybackAction = videoPlaybackAction,
    partitionEntries = partitionEntries,
    paginate = paginate,
    pageSize = PAGE_SIZE,
}
