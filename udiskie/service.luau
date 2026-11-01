--!nonstrict
-- Udiskie service: monitors `udisksctl monitor` in real time, publishes device.
-- state to shared state (`udiskie_devices`), handles notifications, and processes IPC.
--
-- External commands: udiskie-info, udiskie-mount, udiskie-umount, udisksctl, xdg-open.

local prevMountedDevices = {}
local prevAllDevices = {}
local isInitialFetch = true
-- 同一服务内串行执行设备操作，避免卸载过程中再次挂载或重复断电。
local operationBusy = false
noctalia.state.set("udiskie_busy", false)

local function isTrue(val)
    return type(val) == "string" and val:lower() == "true"
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function openWithFileManager(path)
    local cmd = noctalia.getConfig("file_manager_cmd") or "xdg-open"
    noctalia.runAsync(cmd .. " " .. shellQuote(path))
end

local function parseUdiskieOutput(stdout)
    local rawDevices = {}
    local currentMounted = {}

    if not stdout then
        return rawDevices, currentMounted
    end

    for line in stdout:gmatch("[^\r\n]+") do
        local dev, label, mounted, mountPath, isLuks, isDrive, isPartition, isFilesystem, isDetachable, isEjectable, inUse, deviceSize = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        if dev ~= nil and dev ~= "" then
            local cleanLabel = (label ~= nil and label ~= "") and label or dev
            cleanLabel = cleanLabel:gsub("^[^:]+:%s*", "")

            local isM = isTrue(mounted)
            local devObj = {
                device = dev,
                label = cleanLabel,
                mounted = isM,
                mountPath = mountPath or "",
                isLuks = isTrue(isLuks),
                isDrive = isTrue(isDrive),
                isPartition = isTrue(isPartition),
                isFilesystem = isTrue(isFilesystem),
                isDetachable = isTrue(isDetachable),
                isEjectable = isTrue(isEjectable),
                inUse = isTrue(inUse),
                size = tonumber(deviceSize) or 0,
            }
            table.insert(rawDevices, devObj)
            if isM then
                currentMounted[dev] = devObj.label
            end
        end
    end

    return rawDevices, currentMounted
end

local function buildHierarchy(rawDevices)
    local drives = {}
    local standalonePartitions = {}

    for _, d in ipairs(rawDevices) do
        if not d.isPartition and not d.isFilesystem then
            table.insert(drives, { drive = d, partitions = {} })
        end
    end

    for _, d in ipairs(rawDevices) do
        if d.isPartition or d.isFilesystem or d.isLuks then
            local parentFound = false
            for _, drvItem in ipairs(drives) do
                if d.device:find("^" .. drvItem.drive.device .. "[%dp]") then
                    table.insert(drvItem.partitions, d)
                    parentFound = true
                    break
                end
            end
            if not parentFound then
                table.insert(standalonePartitions, d)
            end
        end
    end

    return {
        drives = drives,
        standalone = standalonePartitions,
        raw = rawDevices,
    }
end

local function processNotifications(rawDevices, currentMounted)
    local enableNotifs = noctalia.getConfig("enable_notifications")
    if enableNotifs == false then
        return
    end

    local currentAllDevs = {}
    for _, d in ipairs(rawDevices) do
        -- Physical drives only: LUKS containers are excluded so the "Drive
        -- Connected" notification fires once for the underlying physical disk,
        -- not again for the encrypted volume.
        if not d.isLuks and (d.isDrive or (not d.isPartition and not d.isFilesystem)) then
            currentAllDevs[d.device] = d.label
        end
    end

    -- 1. Device Insertion (Physical USB plugged in)
    if not isInitialFetch then
        for dev, label in pairs(currentAllDevs) do
            if not prevAllDevices[dev] then
                noctalia.notify(noctalia.tr("notif_drive_connected_title"), noctalia.tr("notif_drive_connected_body", { label = label }))
            end
        end
        -- 2. Device Removal (Physical USB unplugged / powered off)
        for dev, label in pairs(prevAllDevices) do
            if not currentAllDevs[dev] then
                noctalia.notify(noctalia.tr("notif_drive_removed_title"), noctalia.tr("notif_drive_removed_body", { label = label }))
            end
        end
    end

    -- 3. Device Mounted
    for dev, label in pairs(currentMounted) do
        if not prevMountedDevices[dev] then
            noctalia.notify(noctalia.tr("notif_drive_mounted_title"), noctalia.tr("notif_drive_mounted_body", { label = label }))
            if noctalia.getConfig("auto_open_filemanager") == true then
                for _, d in ipairs(rawDevices) do
                    if d.device == dev and d.mountPath ~= "" then
                        openWithFileManager(d.mountPath)
                        break
                    end
                end
            end
        end
    end

    -- 4. Device Unmounted
    for dev, label in pairs(prevMountedDevices) do
        if not currentMounted[dev] and currentAllDevs[dev] then
            noctalia.notify(noctalia.tr("notif_drive_unmounted_title"), noctalia.tr("notif_drive_unmounted_body", { label = label }))
        end
    end

    prevAllDevices = currentAllDevs
    prevMountedDevices = currentMounted
    isInitialFetch = false
end

local function fetchDevices()
    noctalia.runAsync("udiskie-info -a -o \"{device_file}\t{ui_label}\t{is_mounted}\t{mount_path}\t{is_luks}\t{is_drive}\t{is_partition}\t{is_filesystem}\t{is_detachable}\t{is_ejectable}\t{in_use}\t{device_size}\"", function(res)
        if not res or res.exitCode ~= 0 then
            noctalia.state.set("udiskie_devices", { drives = {}, standalone = {}, raw = {}, error = "missing_dep" })
            return
        end

        local rawDevices, currentMounted = parseUdiskieOutput(res.stdout)
        local structured = buildHierarchy(rawDevices)
        structured.error = nil

        processNotifications(rawDevices, currentMounted)

        -- Fetch df disk usage for mounted partitions
        noctalia.runAsync("df -B1 --output=target,used 2>/dev/null", function(dfRes)
            if dfRes and dfRes.exitCode == 0 and dfRes.stdout then
                local usageMap = {}
                for line in dfRes.stdout:gmatch("[^\r\n]+") do
                    local target, used = line:match("^(%S+)%s+(%d+)$")
                    if target and used then
                        usageMap[target] = tonumber(used)
                    end
                end

                for _, d in ipairs(rawDevices) do
                    if d.mounted and d.mountPath ~= "" and usageMap[d.mountPath] then
                        d.usedSize = usageMap[d.mountPath]
                    end
                end
            end

            noctalia.state.set("udiskie_devices", structured)
        end)
    end, 5000)
end

-- Initial fetch on startup
noctalia.state.set("udiskie_devices", {})
fetchDevices()

-- Event-driven streaming using udisksctl monitor
noctalia.runStream("udisksctl monitor 2>/dev/null", function(line)
    if line:find("Added") or line:find("PropertiesChanged") or line:find("Removed") then
        fetchDevices()
    end
end)

local function cleanError(stderr, fallback)
    if not stderr or stderr == "" then
        return fallback
    end
    -- upstream formats errors as "failed to <verb> <device>: <message>").
    local clean = stderr:gsub("failed to %w+ [^:]+:%s*", "")
    -- Strip GDBus error identifiers like "GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy:"
    clean = clean:gsub("GDBus%.Error:[%w%.]+:%s*", "")
    -- Clean leading/trailing whitespace
    clean = clean:gsub("^%s*", ""):gsub("%s*$", "")
    return clean ~= "" and clean or fallback
end

-- 结束一次操作并刷新状态；命令超时或未返回结果也必须作为失败显示。
local function finishOperation(res, titleKey, fallback)
    operationBusy = false
    noctalia.state.set("udiskie_busy", false)
    if (not res or res.exitCode ~= 0) and noctalia.getConfig("enable_notifications") ~= false then
        noctalia.notifyError(noctalia.tr(titleKey), cleanError(res and res.stderr, fallback))
    end
    fetchDevices()
end

-- 普通挂载和卸载也经过同一把操作锁；超时后不自动重试设备写操作。
local function runOperation(command, titleKey, fallback)
    operationBusy = true
    noctalia.state.set("udiskie_busy", true)
    noctalia.runAsync(command, function(res)
        finishOperation(res, titleKey, fallback)
    end, 120000)
end

-- 先读取当前整盘能力，再以两阶段命令执行安全移除。
-- requestedMode 保留旧 eject/detach IPC 的含义；safe_remove 自动选择可用操作。
local function safelyRemove(payload, requestedMode)
    operationBusy = true
    noctalia.state.set("udiskie_busy", true)
    local titleKey = "notif_safe_remove_failed_title"
    local fallback = noctalia.tr("notif_safe_remove_failed_fallback", { device = payload })
    if requestedMode == "eject" then
        titleKey = "notif_eject_failed_title"
        fallback = noctalia.tr("notif_eject_failed_fallback", { device = payload })
    elseif requestedMode == "detach" then
        titleKey = "notif_poweroff_failed_title"
        fallback = noctalia.tr("notif_poweroff_failed_fallback", { device = payload })
    end
    local query = "udiskie-info -o " .. shellQuote("{is_toplevel}\t{is_ejectable}\t{is_detachable}\t{device_id}") .. " " .. shellQuote(payload)

    -- 1. 不信任面板缓存：设备拔出、权限变化或查询失败时直接停止。
    noctalia.runAsync(query, function(res)
        if not res or res.exitCode ~= 0 then
            finishOperation(res, titleKey, fallback)
            return
        end
        local top, ejectable, detachable, deviceId = (res.stdout or ""):match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\r\n]*)[\r\n]*$")
        local mode = requestedMode
        if mode == "safe_remove" then
            mode = isTrue(ejectable) and "eject" or "detach"
        end
        if not isTrue(top) or (mode == "eject" and not isTrue(ejectable)) or (mode == "detach" and not isTrue(detachable)) then
            finishOperation({ exitCode = 1 }, titleKey, noctalia.tr("error_remove_unsupported"))
            return
        end

        -- 2. 优先使用持久设备路径，减少 /dev/sdX 在两阶段之间被复用的风险。
        local target = payload
        if deviceId and deviceId ~= "" and deviceId ~= "None" and not deviceId:find("/", 1, true) then
            target = "/dev/disk/by-id/" .. deviceId
        end
        local quotedTarget = shellQuote(target)
        -- udiskie 的 --force 表示递归处理子设备，不是强制/延迟卸载忙碌文件系统。
        -- 显式禁止第一阶段弹出或断电；&& 保证任一卸载失败都不会进入第二阶段。
        local unmount = "udiskie-umount --force --no-detach --no-eject " .. quotedTarget
        local remove = mode == "eject"
            and "udiskie-umount --no-force --no-detach --eject "
            or "udiskie-umount --no-force --no-eject --detach "
        noctalia.runAsync(unmount .. " && " .. remove .. quotedTarget, function(result)
            finishOperation(result, titleKey, fallback)
        end, 120000)
    end, 5000)
end

-- 面板与快捷键共用入口；只读刷新始终可用，设备变更在服务内部串行化。
function onIpc(event, payload)
    if event == "refresh" then
        fetchDevices()
        return
    end
    if operationBusy then
        return
    end
    if event == "mount" and payload then
        runOperation("udiskie-mount -r " .. shellQuote(payload), "notif_mount_failed_title", noctalia.tr("notif_mount_failed_fallback", { device = payload }))
    elseif event == "mount_all" then
        runOperation("udiskie-mount -a", "notif_mount_all_failed_title", noctalia.tr("notif_mount_all_failed_fallback"))
    elseif event == "unmount" and payload then
        -- 卸载仅处理文件系统，明确覆盖用户配置中可能启用的弹出或断电选项。
        runOperation("udiskie-umount --no-detach --no-eject " .. shellQuote(payload), "notif_unmount_failed_title", noctalia.tr("notif_unmount_failed_fallback", { device = payload }))
    elseif event == "unmount_all" then
        runOperation("udiskie-umount -a --no-detach --no-eject", "notif_unmount_all_failed_title", noctalia.tr("notif_unmount_all_failed_fallback"))
    elseif (event == "safe_remove" or event == "eject" or event == "detach") and payload then
        safelyRemove(payload, event)
    elseif event == "open" and payload then
        openWithFileManager(payload)
    end
end
