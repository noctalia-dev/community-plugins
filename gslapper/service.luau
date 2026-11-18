--!nonstrict

local assignments = {}
local runtime = {}
local generations = {}
local pending = {}
local capabilities = { video = false, checking = true }
local previousConnectors = {}
local lastHandledNonce = 0
local commandBatches = {}
local activeRequests = {}
local restartSettingsSignature = ""
local NOTIFICATION_TITLE = "gSlapper"
local IMAGE_EXTENSIONS = { jpg = true, jpeg = true, png = true, webp = true, jxl = true, bmp = true }
local VIDEO_EXTENSIONS = { mp4 = true, mkv = true, webm = true, mov = true, avi = true, m4v = true, gif = true }
local LIBRARY_BATCH_SIZE = 6
local THUMBNAIL_LIMIT = 2
local libraryGeneration = 0
local libraryVersion = 0
local libraryTasks = {}
local librarySources = {}
local libraryErrors = {}
local libraryProcessed = 0
local libraryBytes = 0
local libraryConsumedBytes = 0
local libraryInvalidUtf8 = 0
local thumbnailQueue = {}
local thumbnailActive = 0
local thumbnailReady = 0
local thumbnailDone = 0
local thumbnailTotal = 0
local thumbnailsAvailable = false
local libraryRootSignature = ""

local REQUIRED_FLAGS = {
    "--fork",
    "--ipc-socket",
    "--no-save-state",
    "--auto-pause",
    "--auto-stop",
    "--fps-cap",
    "--gst-options",
    "--transition-type",
    "--transition-duration",
}

local VIDEO_CHANGE_RESTART_ERROR = "ERROR: cannot update path (use --auto-stop for video changes)"

local function copyTable(value)
    local result = {}
    for key, item in pairs(value or {}) do
        result[key] = item
    end
    return result
end

local function copyList(values)
    local result = {}
    for index, value in ipairs(values or {}) do
        result[index] = value
    end
    return result
end

local function validateShellValue(value)
    if type(value) ~= "string" or value:find("[\n\r%z]") then
        return nil, "value contains a forbidden control character"
    end
    return value
end

local function shellQuote(value)
    local valid, message = validateShellValue(value)
    if not valid then
        return nil, message
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function trimTrailingSlash(path)
    if type(path) ~= "string" then
        return nil
    end
    path = path:gsub("/+$", "")
    return path == "" and "/" or path
end

local function mediaRoots()
    local image = trimTrailingSlash(noctalia.wallpaperDirectory())
    local configured = noctalia.getConfig("video_directory")
    local video = trimTrailingSlash(type(configured) == "string" and noctalia.expandPath(configured) or nil)
    return image, video
end

local function validMediaRoot(path)
    return type(path) == "string" and path:sub(1, 1) == "/" and validateShellValue(path)
end

local function classifyMedia(name)
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

local function fnv1a32(value)
    -- ponytail: 32-bit FNV keeps cache names short; use a wider digest if a real collision appears.
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

local function publishLibraryStatus(phase, errorMessage)
    noctalia.state.set("library_status", {
        phase = phase,
        generation = libraryGeneration,
        version = libraryVersion,
        processed = libraryProcessed,
        bytes = libraryBytes,
        consumed_bytes = libraryConsumedBytes,
        skipped_invalid_utf8 = libraryInvalidUtf8,
        thumbnails_ready = thumbnailReady,
        thumbnails_done = thumbnailDone,
        thumbnails_total = thumbnailTotal,
        error = errorMessage,
    })
end

local function nextNulField(raw, offset)
    local boundary = raw:find("\0", offset, true)
    if not boundary then
        return nil, offset
    end
    return raw:sub(offset, boundary - 1), boundary + 1
end

local function isWithinRoot(path, root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function acceptsMedia(rootKind, kind, name)
    if rootKind == "mixed" or rootKind == "video" then
        return rootKind == "mixed" or kind == "video"
    end
    return kind == "image" or name:lower():match("%.gif$") ~= nil
end

local startThumbnailJobs
local function finishLibraryIndex(generation)
    if generation ~= libraryGeneration then
        return
    end
    libraryVersion = libraryVersion + 1
    local imageRoot, videoRoot = mediaRoots()
    noctalia.state.set("library", {
        version = libraryVersion,
        roots = { image = imageRoot, video = videoRoot },
        sources = librarySources,
    })
    thumbnailTotal = thumbnailReady + #thumbnailQueue
    thumbnailDone = thumbnailReady
    if thumbnailTotal == thumbnailReady then
        publishLibraryStatus("ready", #libraryErrors > 0 and table.concat(libraryErrors, "; ") or nil)
    else
        publishLibraryStatus("thumbnails", #libraryErrors > 0 and table.concat(libraryErrors, "; ") or nil)
        startThumbnailJobs(generation)
    end
end

local scheduleLibraryBatch
local function processLibraryBatch(generation)
    if generation ~= libraryGeneration then
        return
    end
    local remaining = LIBRARY_BATCH_SIZE
    while remaining > 0 and #libraryTasks > 0 do
        local task = libraryTasks[1]
        local previousOffset = task.offset
        local fileType
        fileType, task.offset = nextNulField(task.raw, task.offset)
        if not fileType then
            table.remove(libraryTasks, 1)
        else
            local size
            local mtime
            local path
            size, task.offset = nextNulField(task.raw, task.offset)
            mtime, task.offset = nextNulField(task.raw, task.offset)
            path, task.offset = nextNulField(task.raw, task.offset)
            libraryConsumedBytes = libraryConsumedBytes + task.offset - previousOffset
            remaining = remaining - 1
            libraryProcessed = libraryProcessed + 1
            if path and utf8.len(path) == nil then
                libraryInvalidUtf8 = libraryInvalidUtf8 + 1
            elseif path and validateShellValue(path) and isWithinRoot(path, task.root) then
                local name = path:match("([^/]+)$")
                if fileType == "f" then
                    local kind = classifyMedia(name)
                    if kind and acceptsMedia(task.rootKind, kind, name) then
                        local numericSize = tonumber(size) or 0
                        local numericMtime = tonumber(mtime) or 0
                        local thumbnail = thumbnailPath(path, numericSize, numericMtime)
                        local entry = { path = path, thumbnail = thumbnail }
                        if thumbnail and noctalia.fileExists(thumbnail) then
                            thumbnailReady = thumbnailReady + 1
                        elseif thumbnail and thumbnailsAvailable then
                            table.insert(thumbnailQueue, entry)
                        end
                    end
                end
            end
        end
    end
    if #libraryTasks == 0 then
        finishLibraryIndex(generation)
    else
        publishLibraryStatus("scanning")
        scheduleLibraryBatch(generation)
    end
end

scheduleLibraryBatch = function(generation)
    local started = noctalia.runAsync(":", function()
        processLibraryBatch(generation)
    end, 2000)
    if not started and generation == libraryGeneration then
        publishLibraryStatus("error", "Noctalia command capacity is busy")
    end
end

startThumbnailJobs = function(generation)
    while generation == libraryGeneration and thumbnailActive < THUMBNAIL_LIMIT and #thumbnailQueue > 0 do
        local entry = table.remove(thumbnailQueue, 1)
        thumbnailActive = thumbnailActive + 1
        local temporary = entry.thumbnail .. ".tmp-" .. tostring(generation)
        local command = "gst-launch-1.0 -q filesrc location=" .. shellQuote(entry.path)
            .. " ! decodebin ! videoconvert ! videoscale"
            .. " ! video/x-raw,width=224,height=126,pixel-aspect-ratio=1/1"
            .. " ! jpegenc quality=80 snapshot=true ! filesink location=" .. shellQuote(temporary)
        local started = noctalia.runAsync(command, function(result)
            if generation ~= libraryGeneration then
                noctalia.removeFile(temporary)
                return
            end
            thumbnailActive = thumbnailActive - 1
            if result.exitCode == 0 and noctalia.fileExists(temporary)
                and noctalia.renameFile(temporary, entry.thumbnail) then
                thumbnailReady = thumbnailReady + 1
            else
                noctalia.removeFile(temporary)
            end
            thumbnailDone = thumbnailDone + 1
            if #thumbnailQueue == 0 and thumbnailActive == 0 then
                publishLibraryStatus("ready", #libraryErrors > 0 and table.concat(libraryErrors, "; ") or nil)
            elseif thumbnailDone % 8 == 0 then
                publishLibraryStatus("thumbnails", #libraryErrors > 0 and table.concat(libraryErrors, "; ") or nil)
            end
            startThumbnailJobs(generation)
        end, 15000)
        if not started then
            thumbnailActive = thumbnailActive - 1
            thumbnailDone = thumbnailDone + 1
            if #thumbnailQueue == 0 and thumbnailActive == 0 then
                publishLibraryStatus("ready", "could not start thumbnail generation")
            end
        end
    end
end

local function startLibraryIndex()
    local imageRoot, videoRoot = mediaRoots()
    local signature = tostring(imageRoot or "") .. "\0" .. tostring(videoRoot or "")
    libraryRootSignature = signature
    libraryGeneration = libraryGeneration + 1
    local generation = libraryGeneration
    libraryTasks = {}
    librarySources = {}
    libraryErrors = {}
    libraryProcessed = 0
    libraryBytes = 0
    libraryConsumedBytes = 0
    libraryInvalidUtf8 = 0
    thumbnailQueue = {}
    thumbnailActive = 0
    thumbnailReady = 0
    thumbnailDone = 0
    thumbnailTotal = 0
    thumbnailsAvailable = noctalia.commandExists("gst-launch-1.0")
    publishLibraryStatus("scanning")

    local roots = {}
    if imageRoot and videoRoot == imageRoot then
        if validMediaRoot(imageRoot) then
            table.insert(roots, { root = imageRoot, rootKind = "mixed" })
        else
            table.insert(libraryErrors, "Wallpaper directory must be an absolute path without control characters")
        end
    else
        if imageRoot then
            if validMediaRoot(imageRoot) then
                table.insert(roots, { root = imageRoot, rootKind = "image" })
            else
                table.insert(libraryErrors, "Wallpaper directory must be an absolute path without control characters")
            end
        end
        if videoRoot then
            if validMediaRoot(videoRoot) then
                table.insert(roots, { root = videoRoot, rootKind = "video" })
            else
                table.insert(libraryErrors, "Video directory must be an absolute path without control characters")
            end
        end
    end
    if #roots == 0 then
        publishLibraryStatus("error", #libraryErrors > 0 and table.concat(libraryErrors, "; ")
            or "No wallpaper directories are configured")
        return
    end

    local pendingRoots = #roots
    for _, root in ipairs(roots) do
        local quoted = shellQuote(root.root)
        local command = "find -P " .. quoted .. " -mindepth 1 -printf '%y\\0%s\\0%T@\\0%p\\0'"
        local started = noctalia.runAsync(command, function(result)
            if generation ~= libraryGeneration then
                return
            end
            pendingRoots = pendingRoots - 1
            if result.exitCode == 0 then
                local raw = result.stdout or ""
                local indexPath = noctalia.pluginDataDir() .. "/library-" .. root.rootKind .. ".index"
                noctalia.writeFile(indexPath, raw)
                libraryBytes = libraryBytes + #raw
                table.insert(librarySources, {
                    root = root.root,
                    rootKind = root.rootKind,
                    path = indexPath,
                })
                table.insert(libraryTasks, {
                    root = root.root,
                    rootKind = root.rootKind,
                    raw = raw,
                    offset = 1,
                })
            else
                table.insert(libraryErrors, result.stderr ~= "" and result.stderr or (root.root .. " is unreadable"))
            end
            if pendingRoots == 0 then
                scheduleLibraryBatch(generation)
            end
        end, 30000)
        if not started then
            pendingRoots = pendingRoots - 1
            table.insert(libraryErrors, "could not scan " .. root.root)
        end
    end
    if pendingRoots == 0 then
        scheduleLibraryBatch(generation)
    end
end

local function runtimeDirectory()
    local base = noctalia.getenv("XDG_RUNTIME_DIR")
    if not validateShellValue(base) or base == "" or base:sub(1, 1) ~= "/" then
        return nil, "XDG_RUNTIME_DIR is unavailable"
    end
    return base .. "/noctalia-gslapper"
end

local function socketPathFor(connector, directory)
    if type(connector) ~= "string" or connector == "" or type(directory) ~= "string" then
        return nil
    end
    local safeConnector = connector:gsub("[^A-Za-z0-9_.-]", "_")
    return directory .. "/" .. safeConnector .. ".sock"
end

local function isOwnedSocket(path, directory)
    if type(path) ~= "string" or type(directory) ~= "string" then
        return false
    end
    local prefix = directory .. "/"
    if path:sub(1, #prefix) ~= prefix then
        return false
    end
    local filename = path:sub(#prefix + 1)
    return filename ~= "" and not filename:find("/", 1, true) and filename:match("^[A-Za-z0-9_.-]+%.sock$") ~= nil
end

local function processMatchNeedles(socketPath)
    return { "gslapper", "--ipc-socket", socketPath }
end

local function hiddenFlags(behavior)
    if behavior == "auto-pause" then
        return { "--auto-pause" }
    elseif behavior == "auto-stop" then
        return { "--auto-stop" }
    end
    return {}
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parseIpcResponse(command, raw)
    raw = trim(raw or "")
    if command == "query" then
        local status, kind, path = raw:match("^STATUS: (%S+) (%S+) (.+)$")
        if (status == "playing" or status == "paused") and (kind == "image" or kind == "video") then
            return { ok = true, status = status, kind = kind, path = path, raw = raw }
        end
    elseif raw == "OK" or raw:sub(1, 4) == "OK: " then
        return { ok = true, raw = raw }
    elseif command == "change" and raw == VIDEO_CHANGE_RESTART_ERROR then
        return { ok = false, restart = true, error = raw, raw = raw }
    end

    return { ok = false, error = raw ~= "" and raw or "gSlapper returned no response", raw = raw }
end

local COMMAND_ACTIONS = {
    ["assign-image"] = true,
    ["assign-video"] = true,
    ["pause"] = true,
    ["resume"] = true,
    ["restore"] = true,
    ["restore-all"] = true,
    ["self-test"] = true,
}

local function validateCommand(command)
    if type(command) ~= "table" or type(command.nonce) ~= "number" or command.nonce % 1 ~= 0 then
        return false, "command nonce must be an integer"
    end
    if not COMMAND_ACTIONS[command.action] then
        return false, "unknown command action"
    end
    if type(command.target) ~= "string" or command.target == "" then
        return false, "command target is required"
    end
    if command.action == "assign-image" or command.action == "assign-video" then
        if type(command.path) ~= "string" or command.path:sub(1, 1) ~= "/" or command.path == "/"
            or not validateShellValue(command.path) then
            return false, "assignment path must be absolute"
        end
    end
    return true
end

local function summarizeResults(results)
    local summary = { total = 0, successful = 0, failed = 0, pending = 0 }
    for _, result in pairs(results or {}) do
        summary.total = summary.total + 1
        if result.pending then
            summary.pending = summary.pending + 1
        elseif result.ok then
            summary.successful = summary.successful + 1
        else
            summary.failed = summary.failed + 1
        end
    end
    return summary
end

local function targetsFor(target, connectors)
    if target ~= "*" then
        return { target }
    end

    local targets = copyList(connectors)
    table.sort(targets)
    return targets
end

local function commandTargets(action, target, connectors, durable)
    local targets = targetsFor(target, connectors)
    if (action ~= "pause" and action ~= "resume") or target ~= "*" then
        return targets
    end
    local videos = {}
    for _, connector in ipairs(targets) do
        if durable[connector] and durable[connector].kind == "video" then
            table.insert(videos, connector)
        end
    end
    return videos
end

local function detectedConnectors()
    local connectors = {}
    for _, output in ipairs(noctalia.outputs()) do
        if type(output.name) == "string" and output.name ~= "" then
            table.insert(connectors, output.name)
        end
    end
    table.sort(connectors)
    return connectors
end

local function connectorDetected(connector)
    if type(connector) ~= "string" or connector == "" then
        return false
    end
    for _, detected in ipairs(detectedConnectors()) do
        if connector == detected then
            return true
        end
    end
    return false
end

local function connectorBusy(connector)
    return pending[connector] ~= nil or (runtime[connector] and runtime[connector].status == "starting")
end

local function nextGeneration(connector, store)
    store = store or generations
    store[connector] = (store[connector] or 0) + 1
    return store[connector]
end

local function isCurrent(connector, generation, store)
    store = store or generations
    return store[connector] == generation
end

local function generationGuardedSet(store, generationStore, connector, generation, value)
    if not isCurrent(connector, generation, generationStore) then
        return false
    end
    store[connector] = value
    return true
end

local function connectorSet(connectors)
    local result = {}
    for _, connector in ipairs(connectors) do
        result[connector] = true
    end
    return result
end

local function ownedConnectors(durable, liveState)
    local seen = {}
    local connectors = {}
    for connector in pairs(durable or {}) do
        seen[connector] = true
        table.insert(connectors, connector)
    end
    for connector in pairs(liveState or {}) do
        if not seen[connector] then
            table.insert(connectors, connector)
        end
    end
    table.sort(connectors)
    return connectors
end

local function reconcileOutputs(previousConnectors, currentConnectors, durable, live)
    local previous = connectorSet(previousConnectors)
    local current = connectorSet(currentConnectors)
    local stops = {}
    local restores = {}

    for connector in pairs(previous) do
        if not current[connector] then
            live[connector] = nil
            table.insert(stops, connector)
        end
    end

    for connector in pairs(current) do
        local assignment = durable[connector]
        if not previous[connector] and assignment and assignment.kind == "video" then
            table.insert(restores, connector)
        end
    end

    table.sort(stops)
    table.sort(restores)
    return stops, restores
end

local function applyAssignmentBatch(target, connectors, assignment, durable, apply)
    local results = {}
    for _, connector in ipairs(targetsFor(target, connectors)) do
        local ok, message = apply(connector, assignment)
        results[connector] = { ok = ok, error = ok and nil or message }
        if ok then
            durable[connector] = copyTable(assignment)
        end
    end
    return results
end

local function validAbsolutePath(path)
    return type(path) == "string" and path:sub(1, 1) == "/" and path ~= "/"
end

local function validateAssignment(connector, record)
    if type(connector) ~= "string" or connector == "" or type(record) ~= "table" then
        return nil
    end
    if record.kind ~= "image" and record.kind ~= "video" then
        return nil
    end
    if not validAbsolutePath(record.path) then
        return nil
    end
    if record.desired_playback ~= "playing" and record.desired_playback ~= "paused" then
        return nil
    end
    if record.preview_path ~= nil and not validAbsolutePath(record.preview_path) then
        return nil
    end

    return {
        kind = record.kind,
        path = record.path,
        preview_path = record.preview_path,
        desired_playback = record.desired_playback,
    }
end

local function assignmentsPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    return directory .. "/assignments.json"
end

local function loadAssignments()
    local path = assignmentsPath()
    if not path then
        return {}
    end

    local contents = noctalia.readFile(path)
    if not contents then
        return {}
    end

    local decoded, decodeError = noctalia.json.decode(contents)
    if type(decoded) ~= "table" or type(decoded.assignments) ~= "table" then
        noctalia.log("Ignoring invalid assignments file: " .. tostring(decodeError or "invalid shape"))
        return {}
    end

    local loaded = {}
    for connector, record in pairs(decoded.assignments) do
        local valid = validateAssignment(connector, record)
        if valid then
            loaded[connector] = valid
        end
    end
    return loaded
end

local function saveAssignments()
    local path = assignmentsPath()
    if not path then
        return false, "plugin data directory is unavailable"
    end

    -- ponytail: assignments are rewritten as one small JSON object; split storage
    -- only if real configurations make write size measurable.
    local encoded, encodeError = noctalia.json.encode({ version = 1, assignments = assignments }, true)
    if not encoded then
        return false, encodeError or "could not encode assignments"
    end

    local temporaryPath = path .. ".tmp"
    local written, writeError = noctalia.writeFile(temporaryPath, encoded)
    if not written then
        return false, writeError or "could not write assignments"
    end

    local renamed, renameError = noctalia.renameFile(temporaryPath, path)
    if not renamed then
        noctalia.removeFile(temporaryPath)
        return false, renameError or "could not replace assignments"
    end
    return true
end

local function publishRuntime()
    noctalia.state.set("runtime", runtime)
end

local function publishAssignments()
    noctalia.state.set("assignments", assignments)
end

local function publishBatch(batch)
    local record = {
        nonce = batch.nonce,
        action = batch.action,
        results = batch.results,
        summary = summarizeResults(batch.results),
    }
    noctalia.state.set("command_result", record)
end

local function completeRequest(connector, ok, message)
    local request = activeRequests[connector]
    if not request then
        return
    end
    activeRequests[connector] = nil
    local batch = commandBatches[request.nonce]
    if not batch then
        return
    end
    batch.results[connector] = { ok = ok, error = ok and nil or message }
    publishBatch(batch)
    if summarizeResults(batch.results).pending == 0 then
        commandBatches[request.nonce] = nil
    end
end

local function setPending(connector, operation)
    pending[connector] = operation
    noctalia.setUpdateInterval(100)
end

local function clearPending(connector, operation)
    if operation == nil or pending[connector] == operation then
        pending[connector] = nil
    end
    if next(pending) == nil then
        noctalia.setUpdateInterval(1000)
    end
end

local function validateMediaPath(path)
    local valid, message = validateShellValue(path)
    if not valid or path:sub(1, 1) ~= "/" or path == "/" then
        return nil, message or "media path must be absolute"
    end
    local info, infoError = noctalia.fileInfo(path)
    if not info or info.isDir then
        return nil, infoError or "media path is not a file"
    end
    return path
end

local function ipcCommand(socketPath, command, callback)
    if not isOwnedSocket(socketPath, runtimeDirectory()) then
        callback({ ok = false, error = "refusing IPC outside the plugin runtime directory" })
        return false
    end
    if not validateShellValue(command) then
        callback({ ok = false, error = "IPC command contains a forbidden control character" })
        return false
    end

    local quotedCommand = shellQuote(command)
    local quotedSocket = shellQuote(socketPath)
    local shellCommand = "printf '%s\\n' " .. quotedCommand .. " | socat -T 2 - UNIX-CONNECT:" .. quotedSocket
    local started = noctalia.runAsync(shellCommand, function(result)
        if result.exitCode ~= 0 then
            callback({
                ok = false,
                error = trim(result.stderr ~= "" and result.stderr or "gSlapper IPC failed"),
                notConnectable = not result.timedOut,
                raw = result.stdout,
            })
            return
        end
        callback(parseIpcResponse(command:match("^(%S+)") or command, result.stdout))
    end, 2000)
    if not started then
        callback({ ok = false, retryable = true, error = "Noctalia command capacity is busy" })
    end
    return started
end

local function normalizedSettings()
    local scale = noctalia.getConfig("scale")
    if scale ~= "fill" and scale ~= "stretch" and scale ~= "original" and scale ~= "panscan" then
        scale = "fill"
    end
    if scale == "panscan" then
        scale = "panscan=1.0"
    end

    local hidden = noctalia.getConfig("hidden_behavior")
    if hidden ~= "none" and hidden ~= "auto-pause" and hidden ~= "auto-stop" then
        hidden = "none"
    end

    local fps = tostring(noctalia.getConfig("fps_cap") or "30")
    if fps ~= "30" and fps ~= "60" and fps ~= "100" then
        fps = "30"
    end

    local duration = tonumber(noctalia.getConfig("fade_duration")) or 0.5
    duration = math.max(0.1, math.min(5.0, duration))

    return {
        scale = scale,
        hidden = hidden,
        loop = noctalia.getConfig("loop") ~= false,
        fps = fps,
        fade = noctalia.getConfig("fade") == true,
        fadeDuration = duration,
        gstOptions = tostring(noctalia.getConfig("gst_options") or ""),
    }
end

local function buildLaunchCommand(connector, path, socketPath)
    local directory = runtimeDirectory()
    if not directory or not isOwnedSocket(socketPath, directory) then
        return nil, "invalid plugin socket path"
    end

    local settings = normalizedSettings()
    if not validateShellValue(settings.gstOptions) then
        return nil, "GStreamer options contain a forbidden control character"
    end

    local gst = settings.scale .. " no-audio"
    if settings.loop then
        gst = gst .. " loop"
    end
    if settings.gstOptions ~= "" then
        gst = gst .. " " .. settings.gstOptions
    end

    local arguments = {
        "gslapper",
        "--fork",
        "--ipc-socket",
        socketPath,
        "--no-save-state",
    }
    for _, flag in ipairs(hiddenFlags(settings.hidden)) do
        table.insert(arguments, flag)
    end
    table.insert(arguments, "--gst-options")
    table.insert(arguments, gst)
    table.insert(arguments, "--fps-cap")
    table.insert(arguments, settings.fps)
    table.insert(arguments, "--transition-type")
    table.insert(arguments, settings.fade and "fade" or "none")
    table.insert(arguments, "--transition-duration")
    table.insert(arguments, tostring(settings.fadeDuration))
    table.insert(arguments, connector)
    table.insert(arguments, path)

    local quoted = {}
    for index, argument in ipairs(arguments) do
        local value, message = shellQuote(argument)
        if not value then
            return nil, message
        end
        quoted[index] = value
    end
    return table.concat(quoted, " ")
end

local function setConnectorError(connector, generation, message)
    if not isCurrent(connector, generation) then
        return
    end
    clearPending(connector)
    runtime[connector] = { status = "error", error = message }
    noctalia.setWallpaperEnabled(connector, true)
    publishRuntime()
    completeRequest(connector, false, message)
end

local function setLiveError(connector, generation, message)
    if not isCurrent(connector, generation) then
        return
    end
    clearPending(connector)
    local live = runtime[connector] or {}
    runtime[connector] = {
        status = "error",
        error = message,
        socket_path = live.socket_path,
    }
    publishRuntime()
    completeRequest(connector, false, message)
end

local stopOwned

local function commitVideo(connector, generation, assignment, query)
    if not isCurrent(connector, generation) then
        return
    end
    if not query.ok or query.kind ~= "video" or query.path ~= assignment.path then
        setConnectorError(connector, generation, query.error or "gSlapper reported unexpected media")
        return
    end
    if assignment.desired_playback == "paused" and query.status ~= "paused" then
        local live = runtime[connector]
        ipcCommand(live.socket_path, "pause", function(paused)
            if not isCurrent(connector, generation) then
                return
            end
            if not paused.ok then
                setConnectorError(connector, generation, paused.error)
                return
            end
            ipcCommand(live.socket_path, "query", function(pausedQuery)
                commitVideo(connector, generation, assignment, pausedQuery)
            end)
        end)
        return
    end

    local previous = assignments[connector]
    assignments[connector] = copyTable(assignment)
    local saved, saveError = saveAssignments()
    if not saved then
        assignments[connector] = previous
        setConnectorError(connector, generation, saveError)
        stopOwned(connector, generation)
        return
    end

    clearPending(connector)
    noctalia.setWallpaperEnabled(connector, false)
    runtime[connector] = {
        status = query.status,
        error = nil,
        socket_path = runtime[connector] and runtime[connector].socket_path,
    }
    publishAssignments()
    publishRuntime()
    completeRequest(connector, true)
end

local function awaitVideo(connector, generation, assignment, socketPath)
    local operation = {
        kind = "ready",
        generation = generation,
        assignment = assignment,
        socketPath = socketPath,
        deadline = noctalia.nowMs() + 5000,
        inFlight = false,
    }
    setPending(connector, operation)
end

local function launchVideo(connector, generation, assignment)
    if not isCurrent(connector, generation) then
        return
    end

    local directory, directoryError = runtimeDirectory()
    if not directory then
        setConnectorError(connector, generation, directoryError)
        return
    end
    local made, makeError = noctalia.mkdirAll(directory)
    if not made then
        setConnectorError(connector, generation, makeError or "could not create runtime directory")
        return
    end

    local socketPath = socketPathFor(connector, directory)
    local command, commandError = buildLaunchCommand(connector, assignment.path, socketPath)
    if not command then
        setConnectorError(connector, generation, commandError)
        return
    end

    runtime[connector] = { status = "starting", socket_path = socketPath }
    publishRuntime()
    local started = noctalia.runAsync(command, function(result)
        if not isCurrent(connector, generation) then
            return
        end
        if result.exitCode ~= 0 then
            setConnectorError(connector, generation, trim(result.stderr ~= "" and result.stderr or "gSlapper failed to start"))
            return
        end
        awaitVideo(connector, generation, assignment, socketPath)
    end, 5000)
    if not started then
        setConnectorError(connector, generation, "Noctalia command capacity is busy")
    end
end

local function regexEscape(value)
    return (value:gsub("([^%w])", "%%%1"))
end

local function processFallback(connector, generation, socketPath, after)
    local directory = runtimeDirectory()
    if not directory or not isOwnedSocket(socketPath, directory) then
        setConnectorError(connector, generation, "refusing process fallback for an unowned socket")
        return
    end
    local needles = processMatchNeedles(socketPath)
    local started = noctalia.processMatches(function(matched)
        if not isCurrent(connector, generation) then
            return
        end
        if not matched then
            if after then
                after()
            end
            return
        end

        local pattern = "[g]slapper.*--ipc-socket[ =]" .. regexEscape(socketPath)
        local command = "pkill -TERM -f -- " .. shellQuote(pattern)
        local killStarted = noctalia.runAsync(command, function()
            if isCurrent(connector, generation) and after then
                after()
            end
        end, 2000)
        if not killStarted and after then
            after()
        end
    end, needles[1], needles[2], needles[3])
    if not started and after then
        after()
    end
end

stopOwned = function(connector, generation, after)
    if not isCurrent(connector, generation) then
        return
    end

    local directory = runtimeDirectory()
    local socketPath = directory and socketPathFor(connector, directory)
    if not socketPath or not noctalia.fileExists(socketPath) then
        if socketPath then
            processFallback(connector, generation, socketPath, after)
        elseif after then
            after()
        end
        return
    end

    ipcCommand(socketPath, "stop", function()
        if not isCurrent(connector, generation) then
            return
        end
        setPending(connector, {
            kind = "stop",
            generation = generation,
            socketPath = socketPath,
            deadline = noctalia.nowMs() + 2000,
            after = after,
            inFlight = false,
        })
    end)
end

local function changeVideo(connector, generation, assignment, socketPath)
    ipcCommand(socketPath, "change " .. assignment.path, function(change)
        if not isCurrent(connector, generation) then
            return
        end
        if change.ok then
            awaitVideo(connector, generation, assignment, socketPath)
        elseif change.restart then
            stopOwned(connector, generation, function()
                launchVideo(connector, generation, assignment)
            end)
        else
            setLiveError(connector, generation, change.error)
        end
    end)
end

local function assignVideo(connector, path, previewPath, desiredPlayback)
    if not connectorDetected(connector) then
        return false, "output is not connected"
    end
    if connectorBusy(connector) then
        return false, "output switch is already in progress"
    end
    local validPath, pathError = validateMediaPath(path)
    if not validPath then
        return false, pathError
    end
    if previewPath ~= nil and not validateMediaPath(previewPath) then
        previewPath = nil
    end
    if not capabilities.video then
        return false, capabilities.error or "video support is unavailable"
    end

    local generation = nextGeneration(connector)
    local assignment = {
        kind = "video",
        path = validPath,
        preview_path = previewPath,
        desired_playback = desiredPlayback == "paused" and "paused" or "playing",
    }
    if previewPath then
        noctalia.setWallpaper(connector, previewPath)
    end

    local directory = runtimeDirectory()
    local socketPath = directory and socketPathFor(connector, directory)
    if socketPath and noctalia.fileExists(socketPath) then
        runtime[connector] = { status = "starting", socket_path = socketPath }
        publishRuntime()
        ipcCommand(socketPath, "query", function(query)
            if not isCurrent(connector, generation) then
                return
            end
            if query.ok and query.kind == "video" and query.path == assignment.path then
                commitVideo(connector, generation, assignment, query)
            elseif query.ok then
                changeVideo(connector, generation, assignment, socketPath)
            elseif query.notConnectable then
                if isOwnedSocket(socketPath, directory) then
                    noctalia.removeFile(socketPath)
                end
                processFallback(connector, generation, socketPath, function()
                    launchVideo(connector, generation, assignment)
                end)
            else
                setLiveError(connector, generation, query.error)
            end
        end)
    else
        if socketPath then
            processFallback(connector, generation, socketPath, function()
                launchVideo(connector, generation, assignment)
            end)
        else
            launchVideo(connector, generation, assignment)
        end
    end
    return true
end

local function assignImage(connector, path)
    if not connectorDetected(connector) then
        return false, "output is not connected"
    end
    if connectorBusy(connector) then
        return false, "output switch is already in progress"
    end
    local validPath, pathError = validateMediaPath(path)
    if not validPath then
        return false, pathError
    end

    local generation = nextGeneration(connector)
    local previous = assignments[connector]
    noctalia.setWallpaper(connector, validPath)
    assignments[connector] = {
        kind = "image",
        path = validPath,
        desired_playback = "playing",
    }
    local saved, saveError = saveAssignments()
    if not saved then
        assignments[connector] = previous
        return false, saveError
    end

    noctalia.setWallpaperEnabled(connector, true)
    runtime[connector] = { status = "static" }
    publishAssignments()
    publishRuntime()
    stopOwned(connector, generation)
    completeRequest(connector, true)
    return true
end

local function setPlayback(connector, desired)
    local assignment = assignments[connector]
    local live = runtime[connector]
    if not assignment or assignment.kind ~= "video" or not live or not live.socket_path then
        return false, "output has no active video"
    end
    if connectorBusy(connector) then
        return false, "output switch is already in progress"
    end

    local generation = nextGeneration(connector)
    local previousDesired = assignment.desired_playback
    live.status = "starting"
    live.error = nil
    publishRuntime()
    ipcCommand(live.socket_path, desired == "paused" and "pause" or "resume", function(result)
        if not isCurrent(connector, generation) or not result.ok then
            if isCurrent(connector, generation) and not result.ok then
                setLiveError(connector, generation, result.error)
            end
            return
        end
        ipcCommand(live.socket_path, "query", function(query)
            if not isCurrent(connector, generation) then
                return
            end
            if not query.ok or query.status ~= desired then
                setLiveError(connector, generation, query.error or "playback state did not change")
                return
            end
            assignment.desired_playback = desired
            local saved, saveError = saveAssignments()
            if not saved then
                assignment.desired_playback = previousDesired
                setLiveError(connector, generation, saveError)
                return
            end
            runtime[connector].status = query.status
            publishAssignments()
            publishRuntime()
            completeRequest(connector, true)
        end)
    end)
    return true
end

local function restoreConnector(connector)
    if not connectorDetected(connector) then
        return false, "output is not connected"
    end
    if connectorBusy(connector) then
        return false, "output switch is already in progress"
    end

    local generation = nextGeneration(connector)
    local previous = assignments[connector]
    assignments[connector] = nil
    local saved, saveError = saveAssignments()
    if not saved then
        assignments[connector] = previous
        return false, saveError
    end

    noctalia.setWallpaperEnabled(connector, true)
    runtime[connector] = { status = "static" }
    publishAssignments()
    publishRuntime()
    stopOwned(connector, generation, function()
        completeRequest(connector, true)
    end)
    return true
end

local function restoreAssignment(connector)
    local assignment = assignments[connector]
    if not assignment then
        return
    end
    if assignment.kind == "image" then
        runtime[connector] = { status = "static" }
        noctalia.setWallpaperEnabled(connector, true)
        publishRuntime()
    elseif capabilities.video then
        assignVideo(connector, assignment.path, assignment.preview_path, assignment.desired_playback)
    else
        runtime[connector] = { status = "error", error = capabilities.error or "video support is unavailable" }
        noctalia.setWallpaperEnabled(connector, true)
        publishRuntime()
    end
end

local function restoreConnectedAssignments()
    previousConnectors = detectedConnectors()
    noctalia.state.set("outputs", previousConnectors)
    for _, connector in ipairs(previousConnectors) do
        restoreAssignment(connector)
    end
end

local function settingsSignature()
    local settings = normalizedSettings()
    return table.concat({
        settings.scale,
        settings.hidden,
        tostring(settings.loop),
        settings.fps,
        tostring(settings.fade),
        tostring(settings.fadeDuration),
        settings.gstOptions,
    }, "\0")
end

local function restartActiveVideos()
    for _, connector in ipairs(detectedConnectors()) do
        local assignment = assignments[connector]
        local live = runtime[connector]
        if assignment and assignment.kind == "video" and live and not connectorBusy(connector) then
            local generation = nextGeneration(connector)
            live.status = "starting"
            live.error = nil
            publishRuntime()
            stopOwned(connector, generation, function()
                launchVideo(connector, generation, copyTable(assignment))
            end)
        end
    end
end

local function reconcileDetectedOutputs()
    local current = detectedConnectors()
    local stops, restores = reconcileOutputs(previousConnectors, current, assignments, runtime)
    previousConnectors = current
    noctalia.state.set("outputs", current)

    for _, connector in ipairs(stops) do
        completeRequest(connector, false, "output disconnected")
        local generation = nextGeneration(connector)
        noctalia.setWallpaperEnabled(connector, true)
        stopOwned(connector, generation)
    end
    for _, connector in ipairs(restores) do
        restoreAssignment(connector)
    end
    publishRuntime()
end

local capabilitiesReady
local function probeCapabilities()
    if not noctalia.commandExists("gslapper") then
        capabilities = { video = false, checking = false, error = "gSlapper is not installed" }
        noctalia.state.set("capabilities", capabilities)
        if capabilitiesReady then
            capabilitiesReady()
        end
        return
    end
    if not noctalia.commandExists("socat") then
        capabilities = { video = false, checking = false, error = "socat is not installed" }
        noctalia.state.set("capabilities", capabilities)
        if capabilitiesReady then
            capabilitiesReady()
        end
        return
    end

    noctalia.state.set("capabilities", capabilities)
    local started = noctalia.runAsync("gslapper --help", function(result)
        local missing = {}
        local help = result.stdout .. result.stderr
        for _, flag in ipairs(REQUIRED_FLAGS) do
            if not help:find(flag, 1, true) then
                table.insert(missing, flag)
            end
        end
        if result.exitCode == 0 and #missing == 0 then
            capabilities = { video = true, checking = false, tested_version = "1.5.2" }
        else
            capabilities = {
                video = false,
                checking = false,
                error = "gSlapper is missing required IPC options: " .. table.concat(missing, ", "),
            }
        end
        noctalia.state.set("capabilities", capabilities)
        if capabilitiesReady then
            capabilitiesReady()
        end
    end, 2000)
    if not started then
        capabilities = { video = false, checking = false, error = "could not run the gSlapper compatibility check" }
        noctalia.state.set("capabilities", capabilities)
        if capabilitiesReady then
            capabilitiesReady()
        end
    end
end

local function runModelChecks()
    local connectors = { "eDP-1", "DP-1", "DP-3" }

    local durable = {
        ["eDP-1"] = { kind = "image", path = "/wallpapers/still.jpg", desired_playback = "playing" },
        ["DP-1"] = { kind = "video", path = "/wallpapers/motion.mp4", desired_playback = "paused" },
    }
    assert(durable["eDP-1"].path ~= durable["DP-1"].path, "outputs lost independent assignments")

    local targets = targetsFor("*", connectors)
    assert(table.concat(targets, ",") == "DP-1,DP-3,eDP-1", "All target was not sorted")

    local testGenerations = {}
    local testRuntime = {}
    local stale = nextGeneration("DP-1", testGenerations)
    local current = nextGeneration("DP-1", testGenerations)
    assert(not generationGuardedSet(testRuntime, testGenerations, "DP-1", stale, "stale"), "stale generation mutated state")
    assert(generationGuardedSet(testRuntime, testGenerations, "DP-1", current, "ready"), "current generation did not mutate state")

    local live = { ["DP-1"] = { status = "playing" } }
    local stops = reconcileOutputs(connectors, { "eDP-1", "DP-3" }, durable, live)
    assert(durable["DP-1"] ~= nil and live["DP-1"] == nil and stops[1] == "DP-1", "disconnect did not retain durable state")

    local _, restores = reconcileOutputs({ "eDP-1", "DP-3" }, connectors, durable, live)
    assert(restores[1] == "DP-1", "reconnect did not schedule retained video")

    local batchDurable = {}
    local results = applyAssignmentBatch("*", connectors, durable["DP-1"], batchDurable, function(connector)
        if connector == "DP-1" then
            return false, "fixture failure"
        end
        return true
    end)
    assert(not results["DP-1"].ok, "fixture failure was not reported")
    assert(batchDurable["eDP-1"] ~= nil and batchDurable["DP-3"] ~= nil, "partial failure erased successful targets")

    assert(shellQuote("/tmp/a b's.mp4") == "'/tmp/a b'\\''s.mp4'", "apostrophe quoting failed")
    assert(validateShellValue("line\nbreak") == nil and validateShellValue("nul\0byte") == nil, "control character accepted")
    assert(validMediaRoot("/wallpapers") and not validMediaRoot("wallpapers")
        and not validMediaRoot("/wall\npapers"), "media root validation failed")

    local testDirectory = "/run/user/1000/noctalia-gslapper"
    local socketPath = socketPathFor("../DP/1", testDirectory)
    assert(socketPath == testDirectory .. "/.._DP_1.sock", "connector escaped runtime directory")
    assert(isOwnedSocket(socketPath, testDirectory) and not isOwnedSocket("/tmp/DP-1.sock", testDirectory), "socket ownership failed")

    local needles = processMatchNeedles(socketPath)
    assert(needles[1] == "gslapper" and needles[3] == socketPath, "process match omitted exact socket")
    assert(#hiddenFlags("none") == 0 and #hiddenFlags("auto-pause") == 1 and #hiddenFlags("auto-stop") == 1, "hidden flags conflict")

    local query = parseIpcResponse("query", "STATUS: paused video /tmp/a b.mp4\n")
    assert(query.ok and query.status == "paused" and query.path == "/tmp/a b.mp4", "query response parsing failed")
    assert(parseIpcResponse("pause", "OK\n").ok, "success response parsing failed")
    assert(parseIpcResponse("change", VIDEO_CHANGE_RESTART_ERROR .. "\n").restart, "video-change recovery parsing failed")

    assert(validateCommand({ nonce = 1, action = "assign-video", target = "*", path = "/tmp/a.mp4" }), "valid command rejected")
    assert(not validateCommand({ nonce = 1, action = "unknown", target = "*" }), "unknown command accepted")
    assert(not validateCommand({ nonce = 1, action = "assign-video", target = "*", path = "relative.mp4" }), "relative path accepted")

    local summary = summarizeResults({
        ["DP-1"] = { ok = true },
        ["DP-3"] = { ok = false, error = "fixture" },
        ["eDP-1"] = { pending = true },
    })
    assert(summary.total == 3 and summary.successful == 1 and summary.failed == 1 and summary.pending == 1, "batch summary failed")

    local newOutputDurable = { ["DP-1"] = durable["DP-1"] }
    local _, newOutputRestores = reconcileOutputs({ "DP-1" }, { "DP-1", "DP-3" }, newOutputDurable, {})
    assert(#newOutputRestores == 0, "unassigned new output received a video")

    local allThenOne = {}
    applyAssignmentBatch("*", connectors, durable["DP-1"], allThenOne, function()
        return true
    end)
    allThenOne["DP-1"] = copyTable(durable["eDP-1"])
    assert(allThenOne["DP-3"].kind == "video" and allThenOne["eDP-1"].kind == "video", "individual override changed other outputs")

    local pauseTargets = commandTargets("pause", "*", connectors, {
        ["DP-1"] = { kind = "video" },
        ["DP-3"] = { kind = "image" },
        ["eDP-1"] = { kind = "video" },
    })
    assert(table.concat(pauseTargets, ",") == "DP-1,eDP-1", "All pause targeted non-video outputs")
    assert(table.concat(ownedConnectors({ ["DP-1"] = {} }, { ["DP-3"] = {} }), ",") == "DP-1,DP-3", "teardown omitted durable output")
end

local function publishSelfTest(report)
    local directory = noctalia.pluginDataDir()
    if directory then
        local encoded = noctalia.json.encode(report, true)
        if encoded then
            noctalia.writeFile(directory .. "/selftest.json", encoded)
        end
    end
    noctalia.state.set("self_test", report)
end

local function runSelfTest(quiet)
    local ok, message = pcall(runModelChecks)
    local report = {
        passed = ok,
        checks = 22,
        error = not ok and tostring(message) or nil,
    }

    if not quiet then
        publishSelfTest(report)
        if ok then
            noctalia.notify(NOTIFICATION_TITLE, "Self-test passed.")
        else
            noctalia.notifyError(NOTIFICATION_TITLE, report.error)
            error(report.error)
        end
    end
    return report
end

local function handleCommand(command)
    local valid, validationError = validateCommand(command)
    if not valid or command.nonce <= lastHandledNonce then
        return false, validationError or "command nonce was already handled"
    end
    lastHandledNonce = command.nonce

    if command.action == "self-test" then
        local report = runSelfTest(true)
        noctalia.state.set("command_result", {
            nonce = command.nonce,
            action = command.action,
            results = { self_test = { ok = report.passed, error = report.error } },
            summary = { total = 1, successful = report.passed and 1 or 0, failed = report.passed and 0 or 1, pending = 0 },
        })
        publishSelfTest(report)
        return report.passed, report.error
    end

    local connectors = detectedConnectors()
    local target = command.action == "restore-all" and "*" or command.target
    local targets = commandTargets(command.action, target, connectors, assignments)
    local batch = { nonce = command.nonce, action = command.action, results = {} }
    commandBatches[command.nonce] = batch

    for _, connector in ipairs(targets) do
        if activeRequests[connector] or connectorBusy(connector) then
            batch.results[connector] = { ok = false, error = "output switch is already in progress" }
        else
            batch.results[connector] = { pending = true }
            activeRequests[connector] = { nonce = command.nonce, action = command.action }

            local ok, message
            if command.action == "assign-image" then
                ok, message = assignImage(connector, command.path)
            elseif command.action == "assign-video" then
                ok, message = assignVideo(connector, command.path, command.preview_path)
            elseif command.action == "pause" then
                ok, message = setPlayback(connector, "paused")
            elseif command.action == "resume" then
                ok, message = setPlayback(connector, "playing")
            else
                ok, message = restoreConnector(connector)
            end

            if not ok then
                activeRequests[connector] = nil
                batch.results[connector] = { ok = false, error = message }
            end
        end
    end

    publishBatch(batch)
    if summarizeResults(batch.results).pending == 0 then
        commandBatches[command.nonce] = nil
    end
    return true
end

function onIpc(event, _payload)
    if event == "self-test" then
        runSelfTest(false)
    end
end

function onOutputsChanged()
    reconcileDetectedOutputs()
end

function onConfigChanged()
    local currentSignature = settingsSignature()
    if restartSettingsSignature ~= "" and currentSignature ~= restartSettingsSignature then
        restartActiveVideos()
    end
    restartSettingsSignature = currentSignature
    local imageRoot, videoRoot = mediaRoots()
    local rootsSignature = tostring(imageRoot or "") .. "\0" .. tostring(videoRoot or "")
    if noctalia.pluginDataDir() and rootsSignature ~= libraryRootSignature then
        startLibraryIndex()
    end
end

function onExit()
    local directory = runtimeDirectory()
    if not directory then
        return
    end
    for _, connector in ipairs(ownedConnectors(assignments, runtime)) do
        local live = runtime[connector] or {}
        noctalia.setWallpaperEnabled(connector, true)
        local socketPath = live.socket_path or socketPathFor(connector, directory)
        if isOwnedSocket(socketPath, directory) and noctalia.fileExists(socketPath) then
            local command = "printf '%s\\n' 'stop' | socat -T 2 - UNIX-CONNECT:" .. shellQuote(socketPath)
            noctalia.runAsync(command)
        end
    end
end

function update()
    local now = noctalia.nowMs()
    for connector, operation in pairs(pending) do
        if not isCurrent(connector, operation.generation) then
            clearPending(connector, operation)
        elseif operation.kind == "ready" and not operation.inFlight then
            operation.inFlight = true
            ipcCommand(operation.socketPath, "query", function(query)
                if pending[connector] ~= operation or not isCurrent(connector, operation.generation) then
                    return
                end
                operation.inFlight = false
                if query.ok and query.kind == "video" and query.path == operation.assignment.path then
                    commitVideo(connector, operation.generation, operation.assignment, query)
                elseif noctalia.nowMs() >= operation.deadline then
                    setConnectorError(connector, operation.generation, query.error or "gSlapper readiness timed out")
                    stopOwned(connector, operation.generation)
                end
            end)
        elseif operation.kind == "stop" then
            if not noctalia.fileExists(operation.socketPath) then
                clearPending(connector, operation)
                if operation.after then
                    operation.after()
                end
            elseif now >= operation.deadline and not operation.inFlight then
                operation.inFlight = true
                ipcCommand(operation.socketPath, "query", function(query)
                    if pending[connector] ~= operation or not isCurrent(connector, operation.generation) then
                        return
                    end
                    clearPending(connector, operation)
                    local directory = runtimeDirectory()
                    if query.notConnectable and directory and isOwnedSocket(operation.socketPath, directory) then
                        noctalia.removeFile(operation.socketPath)
                    end
                    processFallback(connector, operation.generation, operation.socketPath, operation.after)
                end)
            end
        end
    end
end

noctalia.setUpdateInterval(1000)
assignments = loadAssignments()
publishAssignments()
capabilitiesReady = restoreConnectedAssignments
if type(noctalia.commandExists) == "function" then
    restartSettingsSignature = settingsSignature()
    noctalia.state.watch("command", handleCommand)
    probeCapabilities()
    if noctalia.pluginDataDir() then
        startLibraryIndex()
    end
end

return {
    assignments = assignments,
    runtime = runtime,
    detectedConnectors = detectedConnectors,
    targetsFor = targetsFor,
    commandTargets = commandTargets,
    nextGeneration = nextGeneration,
    isCurrent = isCurrent,
    reconcileOutputs = reconcileOutputs,
    ownedConnectors = ownedConnectors,
    validateAssignment = validateAssignment,
    saveAssignments = saveAssignments,
    validateShellValue = validateShellValue,
    shellQuote = shellQuote,
    socketPathFor = socketPathFor,
    isOwnedSocket = isOwnedSocket,
    processMatchNeedles = processMatchNeedles,
    hiddenFlags = hiddenFlags,
    parseIpcResponse = parseIpcResponse,
    validateCommand = validateCommand,
    summarizeResults = summarizeResults,
    buildLaunchCommand = buildLaunchCommand,
    assignVideo = assignVideo,
    assignImage = assignImage,
    setPlayback = setPlayback,
    handleCommand = handleCommand,
    runSelfTest = runSelfTest,
    classifyMedia = classifyMedia,
    fnv1a32 = fnv1a32,
    validMediaRoot = validMediaRoot,
    requiredFlags = REQUIRED_FLAGS,
}
