--!nonstrict
local records = require("./records.luau")
local Module = {}

function Module.new(dataDir, onChanged)
    local M = {}
    local clean, validId, duration = records.clean, records.validId, records.duration
    local validRecords, record = records.validRecords, records.record
    local QUALITY = noctalia.getConfig("playback_quality")
    local AUTOPLAY = noctalia.getConfig("autoplay_recommendations") == true
    local AUTOPLAY_COUNT = tonumber(noctalia.getConfig("autoplay_count")) or 5
    if AUTOPLAY_COUNT % 1 ~= 0 or AUTOPLAY_COUNT < 1 or AUTOPLAY_COUNT > 10 then AUTOPLAY_COUNT = 5 end
    if QUALITY ~= "auto" and QUALITY ~= "2160" and QUALITY ~= "1440"
        and QUALITY ~= "1080" and QUALITY ~= "720"
        and QUALITY ~= "480" and QUALITY ~= "audio" then
        noctalia.notifyError(noctalia.tr("error.quality"))
        QUALITY = "auto"
    end
    local resumeDir = dataDir and (dataDir .. "/resume") or nil
    M.items, M.error = {}, nil
    local function queueText(key) return noctalia.tr("queue." .. key) end
    local queuePath = dataDir and (dataDir .. "/queue.json") or nil
    local function reloadQueue()
        if not queuePath or not noctalia.fileExists(queuePath) then
            M.items, M.error = {}, nil
            return
        end
        local ok, saved = pcall(noctalia.json.decode, noctalia.readFile(queuePath) or "")
        if ok and type(saved) == "table" and saved.version == 1 and validRecords(saved.items) then
            M.items, M.error = saved.items, nil
        else M.error = queueText("read_error") end
    end
    reloadQueue()
    local function saveQueue(items)
        if M.error then noctalia.notifyError(M.error); return false end
        if not queuePath or not noctalia.mkdirAll(dataDir) then
            noctalia.notifyError(queueText("storage_error")); return false
        end
        local ok, body = pcall(noctalia.json.encode, {version = 1, items = items})
        local temporary = queuePath .. ".part"
        if ok and type(body) == "string" and noctalia.writeFile(temporary, body)
            and noctalia.renameFile(temporary, queuePath) then
            M.items = items
            return true
        end
        noctalia.removeFile(temporary)
        noctalia.notifyError(queueText("save_error"))
        return false
    end
    local function resetQueue()
        if not M.error or not queuePath then return false end
        local body = noctalia.readFile(queuePath)
        if type(body) ~= "string" then noctalia.notifyError(queueText("backup_error")); return false end
        local base = queuePath .. ".backup-" .. tostring(noctalia.nowMs())
        local backup, suffix = base, 0
        while noctalia.fileExists(backup) do
            suffix = suffix + 1
            backup = base .. "-" .. suffix
        end
        local temporary = backup .. ".part"
        if not noctalia.writeFile(temporary, body) or not noctalia.renameFile(temporary, backup) then
            noctalia.removeFile(temporary)
            noctalia.notifyError(queueText("backup_error")); return false
        end
        local previousError = M.error
        M.error = nil
        if not saveQueue({}) then M.error = previousError; return false end
        noctalia.notify(queueText("reset_done"), backup)
        return true
    end
    local function playbackArgs()
        local pluginDir = noctalia.pluginDir()
        local args = {"mpv", "--include=" .. pluginDir .. "/mpv/mpv.conf", "--profile=youtube-explorer",
            "--script=" .. pluginDir .. "/mpv/youtube-resume.lua"}
        if QUALITY == "audio" then
            table.insert(args, "--ytdl-format=ba[protocol^=m3u8]/ba/b")
            table.insert(args, "--vid=no")
            -- Audio playback needs an explicit window when launched outside a terminal.
            table.insert(args, "--force-window=yes")
        elseif QUALITY ~= "auto" then
            -- Keep the profile's HLS preference while enforcing the height cap on every fallback.
            local cap = "[height<=" .. QUALITY .. "]"
            table.insert(args, "--ytdl-format=bv[protocol^=m3u8]" .. cap
                .. "+ba[protocol^=m3u8]/b[protocol^=m3u8]" .. cap .. "/bv*" .. cap .. "+ba/b" .. cap)
        end
        return args
    end
    local function runQueue(action, startId, startPosition, item)
        if M.error then noctalia.notifyError(M.error); return false end
        local pluginDir = noctalia.pluginDir()
        if not pluginDir or not queuePath or not noctalia.commandExists("python3") then
            noctalia.notifyError(queueText("helper_unavailable")); return false
        end
        local args = {"python3", pluginDir .. "/helpers/queue-player.py", action, queuePath}
        if item then table.insert(args, "--queue-item=" .. noctalia.json.encode(record(item))) end
        if action == "play" or action == "refresh" then
            table.insert(args, "--queue-autoplay=" .. (AUTOPLAY and "yes" or "no"))
            table.insert(args, "--queue-autoplay-count=" .. tostring(AUTOPLAY_COUNT))
        end
        if action == "play" then
            if startId then table.insert(args, "--queue-start=" .. startId) end
            if startPosition then table.insert(args, "--queue-start-time=" .. tostring(startPosition)) end
            local options = playbackArgs()
            for i = 2, #options do table.insert(args, options[i]) end
            table.insert(args, "--script-opts-append=youtube-resume-record_dir=" .. resumeDir)
            table.insert(args, "--script-opts-append=youtube-resume-queue_events=" .. dataDir .. "/queue-events")
        end
        local started = noctalia.runAsync(args, function(result)
            if result.exitCode ~= 0 then
                noctalia.notifyError(queueText(action == "play" and "play_error" or action == "refresh" and "refresh_error" or "sync_error"),
                    clean(result.stderr):sub(1, 240))
            end
            reloadQueue()
            if onChanged then onChanged() end
        end, action == "refresh" and 120000 or 15000)
        if not started then noctalia.notifyError(queueText("helper_unavailable")) end
        return started
    end
    local function clearEvents(id)
        local dir = dataDir and (dataDir .. "/queue-events")
        if not dir or not noctalia.fileExists(dir) then return true end
        local names = noctalia.listDir(dir)
        if not names then noctalia.notifyError(noctalia.tr("error.history_clear")); return false end
        for _, name in ipairs(names) do
            if name:match("^%d+%.%d+%.%d+%.json$") then
                local path = dir .. "/" .. name
                local remove = not id
                if id then
                    local ok, event = pcall(noctalia.json.decode, noctalia.readFile(path) or "")
                    if not ok or type(event) ~= "table" or not validId(event.id, false) then
                        noctalia.notifyError(noctalia.tr("error.history_clear")); return false
                    end
                    remove = event.id == id
                end
                if remove and not noctalia.removeFile(path) then
                    noctalia.notifyError(noctalia.tr("error.history_clear")); return false
                end
            end
        end
        return true
    end
    function M.clearProgress(id, onCleared)
        if not resumeDir or not noctalia.commandExists("mpv") then
            noctalia.notifyError(noctalia.tr("error.progress_clear")); return
        end
        if id and not validId(id, false) then return end
        if not clearEvents(id) then return end
        local args = playbackArgs()
        table.insert(args, "--idle=yes")
        table.insert(args, "--force-window=no")
        table.insert(args, "--script-opts-append=youtube-resume-action=clear")
        table.insert(args, "--script-opts-append=youtube-resume-record_dir=" .. resumeDir)
        if id then table.insert(args, "--script-opts-append=youtube-resume-clear_id=" .. id) end
        local started = noctalia.runAsync(args, function(result)
            if result.exitCode ~= 0 then
                noctalia.notifyError(noctalia.tr("error.progress_clear"))
                return
            end
            -- A video can load while mpv clears progress; drain late events too.
            if clearEvents(id) then onCleared() end
        end, 15000)
        if not started then noctalia.notifyError(noctalia.tr("error.progress_clear")) end
    end
    local function playbackProgress(id)
        if not resumeDir or not validId(id, false) then return nil end
        local path = resumeDir .. "/" .. id .. ".json"
        if not noctalia.fileExists(path) then return nil end
        local ok, saved = pcall(noctalia.json.decode, noctalia.readFile(path) or "")
        if ok and type(saved) == "table" and saved.id == id and type(saved.position) == "number"
            and saved.position >= 0 and saved.position < math.huge and type(saved.length) == "number"
            and saved.length >= 0 and saved.length < math.huge then
            return duration(saved.position) .. (saved.length > 0 and (" / " .. duration(saved.length)
                .. " · " .. math.min(100, math.floor(saved.position / saved.length * 100)) .. "%") or "")
        end
        return nil
    end
    local function startTime(url)
        local value = url:match("[?&#]t=([^&#]+)") or url:match("[?&#]start=([^&#]+)")
        if not value then return nil end
        if value:match("^%d+$") then return tonumber(value) end
        local hours, minutes, seconds = value:match("^(%d+)h(%d+)m(%d+)s$")
        if hours then return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds) end
        hours, minutes = value:match("^(%d+)h(%d+)m$")
        if hours then return tonumber(hours) * 3600 + tonumber(minutes) * 60 end
        hours, seconds = value:match("^(%d+)h(%d+)s$")
        if hours then return tonumber(hours) * 3600 + tonumber(seconds) end
        minutes, seconds = value:match("^(%d+)m(%d+)s$")
        if minutes then return tonumber(minutes) * 60 + tonumber(seconds) end
        hours = value:match("^(%d+)h$")
        if hours then return tonumber(hours) * 3600 end
        minutes = value:match("^(%d+)m$")
        if minutes then return tonumber(minutes) * 60 end
        seconds = value:match("^(%d+)s$")
        return seconds and tonumber(seconds) or nil
    end
    function M.collectEvents(onPlayed)
        reloadQueue()
        if not dataDir then return end
        local dir = dataDir .. "/queue-events"
        if not noctalia.fileExists(dir) then return end
        local names = noctalia.listDir(dir) or {}
        table.sort(names)
        for _, name in ipairs(names) do
            if name:match("^%d+%.%d+%.%d+%.json$") then
                local path = dir .. "/" .. name
                local ok, event = pcall(noctalia.json.decode, noctalia.readFile(path) or "")
                if ok and type(event) == "table" and validId(event.id, false) then
                    local item = validRecords({event}) and record(event)
                        or {id = event.id, title = "YouTube · " .. event.id, subtitle = "Added from URL", subtitleKind = "url"}
                    for _, queued in ipairs(M.items) do if queued.id == event.id then item = queued; break end end
                    if onPlayed(item, name) then noctalia.removeFile(path) end
                end
            end
        end
    end
    local function play(item, url)
        if not noctalia.commandExists("mpv") then noctalia.notifyError(noctalia.tr("error.mpv_missing")); return end
        if not item then noctalia.notifyError(noctalia.tr("url.invalid")); return end
        local start = startTime(url)
        runQueue("play", item.id, start and start < math.huge and start or nil, item)
    end
    M.autoplay = AUTOPLAY
    M.text, M.reload, M.reset, M.run = queueText, reloadQueue, resetQueue, runQueue
    M.progress, M.startTime, M.play = playbackProgress, startTime, play
    return M
end

return Module
