--!nonstrict
-- Region Recorder — Headless Background Service

noctalia.setUpdateInterval(250)

local state = "idle" -- idle | selecting | recording
local isAvailable = false
local outputPath = ""
local recordingProcessName = ""
local tickCount = 0
local CHECK_TICKS = 8

local function cfg(key) return noctalia.getConfig(key) end
local function log(msg) noctalia.log(`region_recorder: {msg}`) end
local function shellQuote(val) return "'" .. tostring(val):gsub("'", [["'"']]) .. "'" end

local function publishStatus()
    noctalia.state.set("status", { state = state, available = isAvailable, outputPath = outputPath })
end

local function setState(nextState)
    if state == nextState then return end
    state = nextState
    publishStatus()
end

local function checkAvailability()
    local hasSlurp = noctalia.commandExists("slurp")
    local hasGSR = noctalia.commandExists("gpu-screen-recorder")
    local hasWl = noctalia.commandExists("wl-screenrec")
    local hasWf = noctalia.commandExists("wf-recorder")
    return hasSlurp and (hasGSR or hasWl or hasWf)
end

local function outputDirectory()
    local configured = cfg("directory")
    local dir = noctalia.expandPath(if configured == "" or configured == nil then "~/Videos/Recordings" else configured)
    if dir:sub(-1) ~= "/" then dir ..= "/" end
    noctalia.mkdirAll(dir)
    return dir
end

local function copyToClipboard(path)
    local escapedPath = path:gsub(" ", "%%20"):gsub("'", "%%27"):gsub('"', "%%22")
    noctalia.copyToClipboard(`file://{escapedPath}`, "text/uri-list")
end

local function buildRecordCommand(geom, targetPath)
    local fps = cfg("frame_rate") or 60
    local framerateMode = cfg("framerate_mode") or "cfr"
    local codec = cfg("video_codec") or "h264"
    local cursor = if cfg("show_cursor") then "yes" else "no"
    local audioSource = cfg("audio_source") or "none"

    if noctalia.commandExists("gpu-screen-recorder") then
        recordingProcessName = "gpu-screen-recorder"
        local audioFlags = ""
        if audioSource == "both" then audioFlags = '-a "default_output|default_input" -ac aac'
        elseif audioSource == "default_output" then audioFlags = "-a default_output -ac aac"
        elseif audioSource == "default_input" then audioFlags = "-a default_input -ac aac"
        end

        local targetFlag = "-w screen"
        if geom and geom ~= "" and geom ~= "screen" then
            local gx, gy, gw, gh = tostring(geom):match("^(%d+),(%d+) (%d+)x(%d+)$")
            if gx and gy and gw and gh then targetFlag = string.format("-w %sx%s+%s+%s", gw, gh, gx, gy) end
        end

        return string.format("gpu-screen-recorder %s -f %d -fm %s -k %s -cursor %s -cr limited %s -v no -o %s", targetFlag, fps, framerateMode, codec, cursor, audioFlags, shellQuote(targetPath))
    elseif noctalia.commandExists("wl-screenrec") then
        recordingProcessName = "wl-screenrec"
        local wlCodec = if codec == "h264" then "avc" else codec
        local parts = { "wl-screenrec", string.format("-f %s", shellQuote(targetPath)), string.format("-m %d", fps), string.format("--codec %s", wlCodec) }
        if framerateMode == "cfr" then table.insert(parts, "--no-damage") end
        if geom and geom ~= "" and geom ~= "screen" then table.insert(parts, string.format("-g %s", shellQuote(geom))) end
        if not cfg("show_cursor") then table.insert(parts, "--no-cursor") end
        if audioSource ~= "none" then table.insert(parts, "--audio") end
        return table.concat(parts, " ")
    elseif noctalia.commandExists("wf-recorder") then
        recordingProcessName = "wf-recorder"
        local parts = { "wf-recorder", string.format("-f %s", shellQuote(targetPath)), string.format("-r %d", fps), string.format("-c %s", codec) }
        if geom and geom ~= "" and geom ~= "screen" then table.insert(parts, string.format("-g %s", shellQuote(geom))) end
        if audioSource ~= "none" then table.insert(parts, "-a") end
        return table.concat(parts, " ")
    end
    return ""
end

local function startRecordingWithGeometry(geom)
    local dir = outputDirectory()
    local pattern = cfg("filename_pattern") or "recording_%Y%m%d_%H%M%S"
    local filename = `{noctalia.formatTime(pattern)}.mp4`
    outputPath = `{dir}{filename}`

    local cmd = buildRecordCommand(geom, outputPath)
    if cmd == "" then
        setState("idle")
        noctalia.notifyError(noctalia.tr("notify.recording_failed"), noctalia.tr("notify.no_recorder"))
        return
    end

    log(`executing recorder: {cmd}`)
    if noctalia.runAsync(cmd) then
        setState("recording")
    else
        setState("idle")
        outputPath = ""
        noctalia.notifyError(noctalia.tr("notify.recording_failed"))
    end
end

local function startSlurpSelection()
    if not isAvailable or state ~= "idle" then return end
    setState("selecting")
    log("starting slurp region selection...")

    local scriptPath = `{noctalia.pluginDir()}/scripts/get_windows.sh`
    local slurpCmd = string.format("sleep 0.2 && ( sh '%s' 2>/dev/null | slurp -f '%%x,%%y %%wx%%h' )", scriptPath)

    noctalia.runAsync(slurpCmd, function(res)
        if state ~= "selecting" then return end
        if res.exitCode == 0 and res.stdout and res.stdout:match("%d+,%d+ %d+x%d+") then
            local geom = res.stdout:match("%d+,%d+ %d+x%d+")
            log(`slurp selected region: {geom}`)
            startRecordingWithGeometry(geom)
        else
            log("slurp selection cancelled or empty")
            setState("idle")
        end
    end)
end

local function stopRecording()
    if state ~= "recording" then return end
    log(`stopping recording process for {outputPath}`)
    local targetEscaped = shellQuote(outputPath)
    noctalia.runAsync(string.format("pkill -SIGINT -f %s 2>/dev/null || pkill -SIGINT -f %s 2>/dev/null || true", targetEscaped, shellQuote(recordingProcessName)))

    local savedPath = outputPath
    setState("idle")
    noctalia.runAsync(string.format("sleep 0.5; test -s %s", targetEscaped), function(res)
        if res.exitCode == 0 then
            log(`recording saved successfully: {savedPath}`)
            noctalia.notify(noctalia.tr("notify.recording_saved"):format(savedPath), savedPath)
            if cfg("copy_to_clipboard") then copyToClipboard(savedPath) end
        else
            log("recording process stopped, file empty or missing")
        end
        outputPath = ""
    end)
end

function update()
    tickCount += 1
    if state == "recording" and tickCount % CHECK_TICKS == 0 and outputPath ~= "" then
        noctalia.processMatches(function(matched)
            if not matched and state == "recording" then
                log("recording process exited externally")
                stopRecording()
            end
        end, recordingProcessName, outputPath)
    end
end

local function handleCommand(cmd)
    local action = if type(cmd) == "table" and cmd.action ~= nil then cmd.action else cmd
    if type(action) ~= "string" then return end

    if action == "start" or action == "select-region" then
        if (cfg("video_source") or "region") == "region" or action == "select-region" then startSlurpSelection() else startRecordingWithGeometry("screen") end
    elseif action == "record-fullscreen" then
        startRecordingWithGeometry("screen")
    elseif action == "stop" then
        stopRecording()
    elseif action == "toggle" then
        if state == "recording" then stopRecording()
        elseif state == "idle" then
            if (cfg("video_source") or "region") == "region" then startSlurpSelection() else startRecordingWithGeometry("screen") end
        end
    end
end

function onIpc(event, payload)
    handleCommand(if type(payload) == "table" and payload.action ~= nil then payload else event)
end

isAvailable = checkAvailability()
publishStatus()
noctalia.state.watch("command", handleCommand)
