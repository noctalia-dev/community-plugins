--!nonstrict
-- Asus Fans Controller EC — headless service.
-- Three explicit control modes share one EC channel:
--   auto   → setp -1 (BIOS)
--   manual → fixed duty with setp
--   curve  → curve --once on an interval from the saved profile

local STATUS_KEY = "fan_status"
local COMMAND_KEY = "fan_command"
local IPC_TEMP_KEY = "fan_ipc_temp"
local IPC_FANS_KEY = "fan_ipc_fans"

local MODE_AUTO = "auto"
local MODE_MANUAL = "manual"
local MODE_CURVE = "curve"

local CURVE_MIN_POINTS = 2
local CURVE_MAX_POINTS = 8
local CURVE_TEMP_MIN = 0
local CURVE_TEMP_MAX = 105
local CURVE_TICK_SECONDS = 3

local fanCount = 0
local fans = {}
local temps = { cpu = nil, board = nil, max = nil }
local controlMode = MODE_AUTO
local synced = true
local available = false
local busy = false
local errorText = ""
local refreshPending = false
local refreshAgain = false
local detailPending = false
local tempsPending = false
local curveTickPending = false
local lastStatusKey = ""
local panelOpen = false
local tempsPollCounter = 0
local lastCurveTickAt = 0

local curvePoints = {}
local curveSelectedIndex = 1
local curvePath = nil
local modePath = nil
local privilegePrefix = nil
local handledCommandNonce = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function shellQuote(str)
    return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local CLI = "asus-fan-control-ec"

local function buildCli(args)
    if privilegePrefix == nil then
        local priv = cfg("privilege_command")
        if type(priv) == "string" and priv ~= "" then
            privilegePrefix = priv .. " "
        else
            privilegePrefix = ""
        end
    end
    return privilegePrefix .. CLI .. " " .. args
end

local function defaultFans(count)
    local list = {}
    for i = 0, math.max(count - 1, 0) do
        list[#list + 1] = { index = i, rpm = 0, percent = 50 }
    end
    return list
end

local function defaultCurvePoints()
    return {
        { percent = 0, temp = 0 },
        { percent = 20, temp = 60 },
        { percent = 40, temp = 75 },
        { percent = 80, temp = 90 },
    }
end

local function cloneCurvePoints(points)
    local copy = {}
    for index, point in ipairs(points) do
        copy[index] = { percent = point.percent, temp = point.temp }
    end
    return copy
end

local function sortCurvePoints(points)
    table.sort(points, function(a, b)
        return a.temp < b.temp
    end)
    return points
end

local function curveSummary()
    local parts = {}
    for _, point in ipairs(curvePoints) do
        table.insert(parts, tostring(point.percent) .. "@" .. tostring(point.temp))
    end
    return table.concat(parts, ";")
end

local function clampCurveTemp(value)
    local num = math.floor((tonumber(value) or 0) + 0.5)
    if num < CURVE_TEMP_MIN then num = CURVE_TEMP_MIN end
    if num > CURVE_TEMP_MAX then num = CURVE_TEMP_MAX end
    return num
end

local function clampPercent(value, minValue, maxValue)
    local minBound = minValue or 0
    local maxBound = maxValue or 100
    local num = math.floor((tonumber(value) or 0) + 0.5)
    if num < minBound then num = minBound end
    if num > maxBound then num = maxBound end
    return num
end

local function pluginStorePath(name)
    local dataDir = noctalia.pluginDataDir()
    if not dataDir then
        return nil
    end
    return dataDir .. "/" .. name
end

local function resolveCurvePath()
    if curvePath == nil then
        curvePath = pluginStorePath("fan-curve.conf")
    end
    return curvePath
end

local function resolveModePath()
    if modePath == nil then
        modePath = pluginStorePath("control-mode.txt")
    end
    return modePath
end

local function serializeCurve(points)
    local lines = { "# percent,temperature" }
    for _, point in ipairs(points) do
        table.insert(lines, tostring(point.percent) .. "," .. tostring(point.temp))
    end
    return table.concat(lines, "\n") .. "\n"
end

local function parseCurveFile(text)
    local points = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^#") then
            local percent, temp = trimmed:match("^([^,]+),([^,]+)$")
            percent = tonumber(percent)
            temp = tonumber(temp)
            if percent ~= nil and temp ~= nil then
                if percent < 0 then percent = 0 end
                table.insert(points, {
                    percent = clampPercent(percent),
                    temp = clampCurveTemp(temp),
                })
            end
        end
    end
    if #points < CURVE_MIN_POINTS then
        return defaultCurvePoints()
    end
    return sortCurvePoints(points)
end

local function saveCurveFile()
    local path = resolveCurvePath()
    if not path then
        return false
    end
    return noctalia.writeFile(path, serializeCurve(curvePoints))
end

local function loadCurveFile()
    local path = resolveCurvePath()
    if path and noctalia.fileExists(path) then
        local content = noctalia.readFile(path)
        if type(content) == "string" and content ~= "" then
            curvePoints = parseCurveFile(content)
            curveSelectedIndex = math.min(math.max(curveSelectedIndex, 1), #curvePoints)
            return
        end
    end
    curvePoints = defaultCurvePoints()
    saveCurveFile()
end

local function saveControlMode()
    local path = resolveModePath()
    if path then
        noctalia.writeFile(path, controlMode .. "\n")
    end
end

local function loadControlMode()
    local path = resolveModePath()
    if not path or not noctalia.fileExists(path) then
        controlMode = MODE_AUTO
        return
    end
    local content = (noctalia.readFile(path) or ""):match("^%s*(%w+)%s*$")
    if content == MODE_MANUAL or content == MODE_CURVE or content == MODE_AUTO then
        controlMode = content
    else
        controlMode = MODE_AUTO
    end
end

local function publishCurveState()
    return {
        points = cloneCurvePoints(curvePoints),
        selectedIndex = curveSelectedIndex,
        path = resolveCurvePath(),
    }
end

local function publishStatus()
    local parts = {}
    for _, fan in ipairs(fans) do
        table.insert(parts, tostring(fan.rpm or 0) .. "/" .. tostring(fan.percent or 0))
    end
    local key = table.concat({
        available and "1" or "0",
        controlMode,
        synced and "1" or "0",
        busy and "1" or "0",
        tostring(fanCount),
        table.concat(parts, ","),
        tostring(temps.cpu or ""),
        tostring(temps.board or ""),
        tostring(temps.max or ""),
        curveSummary(),
        tostring(curveSelectedIndex),
        errorText or "",
    }, "|")
    if key == lastStatusKey then
        return
    end
    lastStatusKey = key

    noctalia.state.set(STATUS_KEY, {
        available = available,
        controlMode = controlMode,
        synced = synced,
        busy = busy,
        fanCount = fanCount,
        fans = fans,
        temps = temps,
        curve = publishCurveState(),
        error = errorText,
    })
end

local function setBusy(value)
    if busy == value then
        return
    end
    busy = value
    publishStatus()
end

local function parseFanSpeed(stdout)
    local text = stdout or ""
    local parsed = {}
    for index, rpm in text:gmatch("fan (%d+):%s*(%d+)%s*rpm") do
        parsed[tonumber(index)] = tonumber(rpm)
    end

    local maxIndex = -1
    for index in pairs(parsed) do
        if index > maxIndex then maxIndex = index end
    end

    local count = math.max(fanCount, maxIndex + 1, #fans)
    if count <= 0 then count = math.max(#fans, 2) end

    local nextFans = {}
    for i = 0, count - 1 do
        local previous = fans[i + 1]
        nextFans[#nextFans + 1] = {
            index = i,
            rpm = parsed[i] or (previous and previous.rpm) or 0,
            percent = previous and previous.percent or 50,
        }
    end
    fans = nextFans
    fanCount = #fans
end

local function parseFanInfo(stdout)
    local text = stdout or ""
    local countMatch = text:match("Fan count:%s*(%d+)")
    if countMatch then fanCount = tonumber(countMatch) or fanCount end

    local parsed = {}
    for index, percent in text:gmatch("fan(%d+):.-PWM duty:%s*%d+%s*%((%d+)%%%)") do
        parsed[tonumber(index)] = tonumber(percent)
    end
    local rpmParsed = {}
    for index, rpm in text:gmatch("fan(%d+):.-Fan speed reg:%s*(%d+)%s*rpm") do
        rpmParsed[tonumber(index)] = tonumber(rpm)
    end

    local count = fanCount
    if count <= 0 then count = math.max(#fans, 2) end

    local nextFans = {}
    for i = 0, count - 1 do
        local previous = fans[i + 1]
        nextFans[#nextFans + 1] = {
            index = i,
            rpm = rpmParsed[i] or (previous and previous.rpm) or 0,
            percent = parsed[i] or (previous and previous.percent) or 50,
        }
    end
    fans = nextFans
    fanCount = #fans
end

local function parseTemps(stdout)
    local text = stdout or ""
    temps = {
        cpu = tonumber(text:match("CPU:%s*(%d+)%s*C")),
        board = tonumber(text:match("Board:%s*(%d+)%s*C")),
        max = tonumber(text:match("Max:%s*(%d+)%s*C")),
    }
end

local function refreshTemps(callback)
    if tempsPending then return end
    tempsPending = true
    local ok = noctalia.runAsync(buildCli("temps-info"), function(result)
        tempsPending = false
        if result.exitCode == 0 then
            parseTemps(result.stdout)
            publishStatus()
        end
        if callback then callback(result.exitCode == 0) end
    end, 10000)
    if not ok then
        tempsPending = false
        if callback then callback(false) end
    end
end

local function finishRefresh(callback, ok)
    if refreshAgain then
        refreshAgain = false
        refreshFanSpeed(callback)
        return
    end
    if callback then callback(ok) end
end

local function refreshFanSpeed(callback)
    if refreshPending then
        refreshAgain = true
        return
    end
    refreshPending = true
    local ok = noctalia.runAsync(buildCli("fan-speed"), function(result)
        refreshPending = false
        if result.exitCode ~= 0 then
            available = false
            local detail = (result.stderr or result.stdout or ""):match("^%s*(.-)%s*$")
            errorText = detail ~= "" and (tr("error.read_failed") .. " " .. detail) or tr("error.read_failed")
            publishStatus()
            finishRefresh(callback, false)
            return
        end

        available = true
        errorText = ""
        parseFanSpeed(result.stdout)
        publishStatus()

        tempsPollCounter = tempsPollCounter + 1
        if panelOpen or tempsPollCounter % 5 == 0 then
            refreshTemps()
        end
        finishRefresh(callback, true)
    end, 10000)

    if not ok then
        refreshPending = false
        available = false
        errorText = tr("error.command_start")
        publishStatus()
        finishRefresh(callback, false)
    end
end

local function refreshFanInfo(callback)
    if detailPending then return end
    detailPending = true
    local ok = noctalia.runAsync(buildCli("fan-info"), function(result)
        detailPending = false
        if result.exitCode == 0 then
            available = true
            errorText = ""
            parseFanInfo(result.stdout)
            publishStatus()
        end
        if callback then callback(result.exitCode == 0) end
    end, 15000)
    if not ok then
        detailPending = false
        if callback then callback(false) end
    end
end

local function runSetCommand(args, onDone)
    setBusy(true)
    local ok = noctalia.runAsync(buildCli(args), function(result)
        setBusy(false)
        if result.exitCode ~= 0 then
            errorText = tr("error.write_failed")
            publishStatus()
            if onDone then onDone(false) end
            return
        end
        errorText = ""
        refreshFanSpeed(function()
            if panelOpen then
                refreshFanInfo(onDone)
            elseif onDone then
                onDone(true)
            end
        end)
    end, 15000)

    if not ok then
        setBusy(false)
        errorText = tr("error.command_start")
        publishStatus()
        if onDone then onDone(false) end
    end
end

local function applyPercentLocally(percent, fanIndex)
    local value = clampPercent(percent)
    if fanIndex == nil then
        for _, fan in ipairs(fans) do fan.percent = value end
        return
    end
    for _, fan in ipairs(fans) do
        if fan.index == fanIndex then
            fan.percent = value
            return
        end
    end
end

local function tickCurve()
    if controlMode ~= MODE_CURVE or curveTickPending then
        return
    end
    local path = resolveCurvePath()
    if not path or not saveCurveFile() then
        errorText = tr("error.curve_save")
        publishStatus()
        return
    end

    curveTickPending = true
    local ok = noctalia.runAsync(
        buildCli("curve --config " .. shellQuote(path) .. " --once"),
        function(result)
            curveTickPending = false
            if result.exitCode ~= 0 then
                local detail = (result.stderr or result.stdout or ""):match("^%s*(.-)%s*$")
                errorText = detail ~= "" and (tr("error.curve_apply") .. " " .. detail) or tr("error.curve_apply")
            else
                errorText = ""
            end
            refreshFanSpeed()
        end,
        20000
    )
    if not ok then
        curveTickPending = false
        errorText = tr("error.command_start")
        publishStatus()
    end
end

local function maybeCurveTick()
    if controlMode ~= MODE_CURVE or busy or curveTickPending then
        return
    end
    local now = os.time()
    if now - lastCurveTickAt < CURVE_TICK_SECONDS then
        return
    end
    lastCurveTickAt = now
    tickCurve()
end

local function releaseToBios(onDone)
    controlMode = MODE_AUTO
    saveControlMode()
    publishStatus()
    runSetCommand("setp -1", function(ok)
        if ok then lastCurveTickAt = 0 end
        if onDone then onDone(ok) end
    end)
end

local function activateManual(percent)
    local value = clampPercent(percent or (fans[1] and fans[1].percent) or 50)
    controlMode = MODE_MANUAL
    saveControlMode()
    applyPercentLocally(value)
    publishStatus()
    runSetCommand("setp " .. tostring(value))
end

local function activateCurve()
    controlMode = MODE_CURVE
    saveControlMode()
    lastCurveTickAt = 0
    publishStatus()
    tickCurve()
end

local function setControlMode(mode)
    if busy or mode == controlMode then
        return
    end
    if mode == MODE_AUTO then
        releaseToBios()
    elseif mode == MODE_MANUAL then
        activateManual(fans[1] and fans[1].percent or 50)
    elseif mode == MODE_CURVE then
        activateCurve()
    end
end

local function nextControlMode()
    if controlMode == MODE_AUTO then
        return MODE_MANUAL
    end
    if controlMode == MODE_MANUAL then
        return MODE_CURVE
    end
    return MODE_AUTO
end

local function switchControlMode()
    if busy then
        return
    end
    setControlMode(nextControlMode())
end

local function setAllPercent(percent)
    if controlMode ~= MODE_MANUAL then
        activateManual(percent)
        return
    end
    local value = clampPercent(percent)
    applyPercentLocally(value)
    publishStatus()
    runSetCommand("setp " .. tostring(value))
end

local function setFanPercent(fanIndex, percent)
    if controlMode ~= MODE_MANUAL then
        activateManual(percent)
        return
    end
    local value = clampPercent(percent)
    applyPercentLocally(value, fanIndex)
    publishStatus()
    runSetCommand("setp " .. tostring(value) .. " --fan " .. tostring(fanIndex))
end

local function adjustPercent(delta)
    if busy then
        return
    end
    local base = tonumber(fans[1] and fans[1].percent) or 50
    setAllPercent(clampPercent(base + (tonumber(delta) or 0)))
end

local function parsePayloadNumber(payload, default)
    if type(payload) == "number" then
        return payload
    end
    if type(payload) == "string" then
        local value = tonumber(payload:match("^%s*(-?%d+)%s*$"))
        if value ~= nil then
            return value
        end
    end
    return default
end

local function parseModeName(payload)
    if type(payload) ~= "string" then
        return nil
    end
    local mode = payload:match("^%s*(%w+)%s*$")
    if mode == "auto" or mode == "bios" then
        return MODE_AUTO
    end
    if mode == MODE_MANUAL or mode == MODE_CURVE then
        return mode
    end
    return nil
end

local function selectCurveIndex(index)
    local nextIndex = tonumber(index) or 1
    if nextIndex < 1 then nextIndex = 1 end
    if nextIndex > #curvePoints then nextIndex = #curvePoints end
    curveSelectedIndex = nextIndex
    publishStatus()
end

local function updateSelectedCurvePoint(mutator)
    local point = curvePoints[curveSelectedIndex]
    if point == nil then return end
    mutator(point)
    sortCurvePoints(curvePoints)
    for index, candidate in ipairs(curvePoints) do
        if candidate == point then
            curveSelectedIndex = index
            break
        end
    end
    saveCurveFile()
    publishStatus()
    if controlMode == MODE_CURVE then
        lastCurveTickAt = 0
        tickCurve()
    end
end

local function setCurveTemp(value)
    updateSelectedCurvePoint(function(point)
        point.temp = clampCurveTemp(value)
    end)
end

local function setCurvePercent(value)
    updateSelectedCurvePoint(function(point)
        point.percent = clampPercent(value)
    end)
end

local function addCurvePoint()
    if #curvePoints >= CURVE_MAX_POINTS then return end
    local last = curvePoints[#curvePoints]
    table.insert(curvePoints, {
        percent = clampPercent(last and last.percent or 50),
        temp = clampCurveTemp((last and last.temp or 60) + 5),
    })
    sortCurvePoints(curvePoints)
    curveSelectedIndex = #curvePoints
    saveCurveFile()
    publishStatus()
end

local function removeCurvePoint()
    if #curvePoints <= CURVE_MIN_POINTS then return end
    table.remove(curvePoints, curveSelectedIndex)
    if curveSelectedIndex > #curvePoints then
        curveSelectedIndex = #curvePoints
    end
    saveCurveFile()
    publishStatus()
end

local function handleCommand(command)
    if type(command) ~= "table" then return end
    local action = command.action

    if action == "refresh" then
        refreshFanSpeed(function()
            if panelOpen or command.detail == true then refreshFanInfo() end
        end)
    elseif action == "panel_open" then
        panelOpen = true
        refreshFanInfo()
        refreshTemps()
    elseif action == "panel_close" then
        panelOpen = false
    elseif action == "set_mode" then
        setControlMode(command.mode)
    elseif action == "set_synced" then
        synced = command.value == true
        publishStatus()
        refreshFanInfo()
    elseif action == "set_all_percent" then
        if busy then return end
        setAllPercent(command.percent)
    elseif action == "adjust_percent" then
        adjustPercent(command.delta)
    elseif action == "set_fan_percent" then
        if busy then return end
        setFanPercent(tonumber(command.fan), command.percent)
    elseif action == "select_curve_point" then
        selectCurveIndex(command.index)
    elseif action == "set_curve_temp" then
        setCurveTemp(command.temp)
    elseif action == "set_curve_percent" then
        setCurvePercent(command.percent)
    elseif action == "add_curve_point" then
        addCurvePoint()
    elseif action == "remove_curve_point" then
        removeCurvePoint()
    end
end

loadCurveFile()
loadControlMode()
fans = defaultFans(2)
fanCount = #fans

if not noctalia.commandExists(CLI) then
    available = false
    errorText = tr("error.missing_dependency")
else
    refreshFanSpeed(function()
        refreshFanInfo()
        refreshTemps()
        if controlMode == MODE_CURVE then
            lastCurveTickAt = 0
            maybeCurveTick()
        end
    end)
end

publishStatus()

local pollInterval = tonumber(cfg("poll_interval")) or 2000
noctalia.setUpdateInterval(pollInterval)

function update()
    refreshFanSpeed(function()
        maybeCurveTick()
    end)
end

noctalia.state.watch(COMMAND_KEY, function(command)
    if type(command) ~= "table" then
        return
    end
    if type(command.nonce) == "number" then
        if command.nonce <= handledCommandNonce then
            return
        end
        handledCommandNonce = command.nonce
    end
    handleCommand(command)
end)

local IPC_SPEED_STEP = 5

local function wantsRefresh(payload)
    return type(payload) == "string" and payload:match("^%s*refresh%s*$") ~= nil
end

local function encodeJson(value)
    local ok, encoded = pcall(noctalia.json.encode, value, true)
    if ok and type(encoded) == "string" then
        return encoded
    end
    noctalia.log("asus-fans-controller-ec: failed to encode IPC JSON")
    return "{}"
end

local function tempsSnapshot()
    return {
        available = available,
        cpu = temps.cpu,
        board = temps.board,
        max = temps.max,
        error = errorText ~= "" and errorText or nil,
    }
end

local function fansSnapshot()
    local fanList = {}
    for _, fan in ipairs(fans) do
        fanList[#fanList + 1] = {
            index = fan.index,
            rpm = fan.rpm,
            percent = fan.percent,
        }
    end
    return {
        available = available,
        controlMode = controlMode,
        synced = synced,
        busy = busy,
        fanCount = fanCount,
        fans = fanList,
        error = errorText ~= "" and errorText or nil,
    }
end

local function publishIpcQuery(kind, data)
    local json = encodeJson(data)
    local stateKey = kind == "temp" and IPC_TEMP_KEY or IPC_FANS_KEY
    local fileName = kind == "temp" and "get-temp.json" or "get-fans.json"
    noctalia.state.set(stateKey, data)
    print(json)
    local path = pluginStorePath(fileName)
    if path then
        noctalia.writeFile(path, json .. "\n")
    end
end

local function publishTempsIpc(refreshFirst)
    if refreshFirst then
        refreshTemps(function()
            publishIpcQuery("temp", tempsSnapshot())
        end)
        return
    end
    publishIpcQuery("temp", tempsSnapshot())
end

local function publishFansIpc(refreshFirst)
    if refreshFirst then
        refreshFanSpeed(function()
            refreshFanInfo(function()
                publishIpcQuery("fans", fansSnapshot())
            end)
        end)
        return
    end
    publishIpcQuery("fans", fansSnapshot())
end

function onIpc(event, payload)
    if event == "refresh" then
        handleCommand({ action = "refresh", detail = true })
    elseif event == "set-mode" or event == "set_mode" then
        local mode = parseModeName(payload)
        if mode ~= nil then
            handleCommand({ action = "set_mode", mode = mode })
        end
    elseif event == "switch" then
        switchControlMode()
    elseif event == "set_speed" or event == "set_percent" then
        local percent = parsePayloadNumber(payload, nil)
        if percent ~= nil then
            handleCommand({ action = "set_all_percent", percent = percent })
        end
    elseif event == "increment" or event == "speed_up" then
        local step = parsePayloadNumber(payload, IPC_SPEED_STEP)
        handleCommand({ action = "adjust_percent", delta = step })
    elseif event == "decrement" or event == "speed_down" then
        local step = parsePayloadNumber(payload, IPC_SPEED_STEP)
        handleCommand({ action = "adjust_percent", delta = -step })
    elseif event == "get-temp" or event == "get_temp" then
        publishTempsIpc(wantsRefresh(payload))
    elseif event == "get-fans" or event == "get_fans" then
        publishFansIpc(wantsRefresh(payload))
    end
end

function onExit(_signal, reason)
    if reason == "reload" then
        return
    end
    if busy then
        busy = false
        publishStatus()
    end
end

function onConfigChanged()
    privilegePrefix = nil
    noctalia.setUpdateInterval(tonumber(cfg("poll_interval")) or 2000)
end
