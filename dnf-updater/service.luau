--!nonstrict
-- Headless [[service]] entry: monitors and manages DNF5 and Flatpak updates.
-- Publishes state updates to noctalia.state so the bar widget and panel stay synchronized.

local checkInterval = noctalia.getConfig("check_interval") or 30
local enableDnf = noctalia.getConfig("enable_dnf") ~= false
local enableFlatpak = noctalia.getConfig("enable_flatpak") ~= false
local notifyOnUpdates = noctalia.getConfig("notify_on_updates") ~= false
local updateInTerminal = noctalia.getConfig("update_in_terminal") == true

local state = {
  status = "IDLE", -- "IDLE" | "CHECKING" | "UPDATING" | "SUCCESS" | "ERROR"
  total_count = 0,
  total_download_bytes = 0,
  total_install_bytes = 0,
  total_download_formatted = "0 B",
  total_install_formatted = "0 B",
  dnf = {
    count = 0,
    packages = {},
    total_download_bytes = 0,
    total_install_bytes = 0,
    total_download_formatted = "0 B",
    total_install_formatted = "0 B",
    status = "idle", -- "idle" | "checking" | "updating" | "done" | "error"
    error = nil,
  },
  flatpak = {
    count = 0,
    packages = {},
    total_download_bytes = 0,
    total_install_bytes = 0,
    total_download_formatted = "0 B",
    total_install_formatted = "0 B",
    status = "idle", -- "idle" | "checking" | "updating" | "done" | "error"
    error = nil,
  },
  last_check = nil,
  last_check_timestamp = 0,
  error_message = nil,
}

local previousCount = 0
local elapsedMinutes = 0
local isChecking = false
local isUpdating = false

local function formatBytes(bytes)
  if not bytes or bytes <= 0 then
    return "0 B"
  end
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local b = tonumber(bytes) or 0
  local uIndex = 1
  while b >= 1024 and uIndex < #units do
    b = b / 1024
    uIndex = uIndex + 1
  end
  if uIndex == 1 then
    return string.format("%d %s", b, units[uIndex])
  else
    return string.format("%.1f %s", b, units[uIndex])
  end
end

local function publishState()
  noctalia.state.set("update_state", state)
end

local function getDnfBinary()
  if noctalia.commandExists("dnf5") then
    return "dnf5"
  elseif noctalia.commandExists("dnf") then
    return "dnf"
  end
  return nil
end

local function checkDnf(onFinished)
  if not enableDnf then
    state.dnf.count = 0
    state.dnf.packages = {}
    state.dnf.total_download_bytes = 0
    state.dnf.total_install_bytes = 0
    state.dnf.total_download_formatted = "0 B"
    state.dnf.total_install_formatted = "0 B"
    state.dnf.status = "idle"
    state.dnf.error = nil
    onFinished(true)
    return
  end

  local dnfBin = getDnfBinary()
  if not dnfBin then
    state.dnf.count = 0
    state.dnf.packages = {}
    state.dnf.total_download_bytes = 0
    state.dnf.total_install_bytes = 0
    state.dnf.total_download_formatted = "0 B"
    state.dnf.total_install_formatted = "0 B"
    state.dnf.status = "error"
    state.dnf.error = "DNF package manager not found"
    onFinished(false)
    return
  end

  state.dnf.status = "checking"
  state.dnf.error = nil

  noctalia.runAsync({ dnfBin, "check-upgrade", "--json" }, function(result)
    if result.timedOut then
      state.dnf.status = "error"
      state.dnf.error = "DNF check timed out"
      onFinished(false)
      return
    end

    local raw = noctalia.string.trim(result.stdout)
    if raw == "" then
      state.dnf.count = 0
      state.dnf.packages = {}
      state.dnf.total_download_bytes = 0
      state.dnf.total_install_bytes = 0
      state.dnf.total_download_formatted = "0 B"
      state.dnf.total_install_formatted = "0 B"
      state.dnf.status = "done"
      state.dnf.error = nil
      onFinished(true)
      return
    end

    local decoded, err = noctalia.json.decode(raw)
    if type(decoded) == "table" and type(decoded.upgrades) == "table" then
      local packages = {}
      for _, item in ipairs(decoded.upgrades) do
        if type(item) == "table" and item.name then
          table.insert(packages, {
            name = item.name,
            evr = item.evr or "",
            arch = item.arch or "",
            repo = item.repository or "",
            download_bytes = 0,
            install_bytes = 0,
            download_formatted = "",
            install_formatted = "",
          })
        end
      end
      state.dnf.count = #packages
      state.dnf.packages = packages

      if #packages > 0 then
        -- Query individual package download and install sizes
        noctalia.runAsync({ dnfBin, "repoquery", "--upgrades", "--queryformat", "%{name}\t%{downloadsize}\t%{installsize}\n" }, function(resSizes)
          local dnfTotalDownload = 0
          local dnfTotalInstall = 0
          if resSizes.exitCode == 0 and resSizes.stdout and resSizes.stdout ~= "" then
            local sizeMap = {}
            for line in resSizes.stdout:gmatch("[^\r\n]+") do
              local name, dl, inst = line:match("([^\t]+)\t([^\t]+)\t([^\t]+)")
              if name then
                sizeMap[name] = {
                  dl = tonumber(dl) or 0,
                  inst = tonumber(inst) or 0,
                }
              end
            end

            for _, pkg in ipairs(packages) do
              local s = sizeMap[pkg.name]
              if s then
                pkg.download_bytes = s.dl
                pkg.install_bytes = s.inst
                pkg.download_formatted = formatBytes(s.dl)
                pkg.install_formatted = formatBytes(s.inst)
                dnfTotalDownload += s.dl
                dnfTotalInstall += s.inst
              end
            end
          end

          state.dnf.total_download_bytes = dnfTotalDownload
          state.dnf.total_install_bytes = dnfTotalInstall
          state.dnf.total_download_formatted = formatBytes(dnfTotalDownload)
          state.dnf.total_install_formatted = formatBytes(dnfTotalInstall)
          state.dnf.status = "done"
          state.dnf.error = nil
          onFinished(true)
        end)
      else
        state.dnf.total_download_bytes = 0
        state.dnf.total_install_bytes = 0
        state.dnf.total_download_formatted = "0 B"
        state.dnf.total_install_formatted = "0 B"
        state.dnf.status = "done"
        state.dnf.error = nil
        onFinished(true)
      end
    else
      -- If JSON parsing failed or command returned non-standard error
      if result.exitCode ~= 0 and result.exitCode ~= 100 then
        state.dnf.status = "error"
        state.dnf.error = result.stderr ~= "" and result.stderr or (err or "DNF check failed")
        onFinished(false)
      else
        state.dnf.count = 0
        state.dnf.packages = {}
        state.dnf.total_download_bytes = 0
        state.dnf.total_install_bytes = 0
        state.dnf.total_download_formatted = "0 B"
        state.dnf.total_install_formatted = "0 B"
        state.dnf.status = "done"
        state.dnf.error = nil
        onFinished(true)
      end
    end
  end)
end

local function checkFlatpak(onFinished)
  if not enableFlatpak then
    state.flatpak.count = 0
    state.flatpak.packages = {}
    state.flatpak.total_download_bytes = 0
    state.flatpak.total_install_bytes = 0
    state.flatpak.total_download_formatted = "0 B"
    state.flatpak.total_install_formatted = "0 B"
    state.flatpak.status = "idle"
    state.flatpak.error = nil
    onFinished(true)
    return
  end

  if not noctalia.commandExists("flatpak") then
    state.flatpak.count = 0
    state.flatpak.packages = {}
    state.flatpak.total_download_bytes = 0
    state.flatpak.total_install_bytes = 0
    state.flatpak.total_download_formatted = "0 B"
    state.flatpak.total_install_formatted = "0 B"
    state.flatpak.status = "error"
    state.flatpak.error = "Flatpak not installed"
    onFinished(false)
    return
  end

  state.flatpak.status = "checking"
  state.flatpak.error = nil

  noctalia.runAsync({ "flatpak", "remote-ls", "--updates", "--columns=name,application,version,branch,origin,installed-size,download-size", "-j" }, function(result)
    if result.timedOut then
      state.flatpak.status = "error"
      state.flatpak.error = "Flatpak check timed out"
      onFinished(false)
      return
    end

    local raw = noctalia.string.trim(result.stdout)
    if raw == "" then
      state.flatpak.count = 0
      state.flatpak.packages = {}
      state.flatpak.total_download_bytes = 0
      state.flatpak.total_install_bytes = 0
      state.flatpak.total_download_formatted = "0 B"
      state.flatpak.total_install_formatted = "0 B"
      state.flatpak.status = "done"
      state.flatpak.error = nil
      onFinished(true)
      return
    end

    local decoded, err = noctalia.json.decode(raw)
    if type(decoded) == "table" then
      local packages = {}
      for _, item in ipairs(decoded) do
        if type(item) == "table" then
          table.insert(packages, {
            name = item.name or (item.application_id or "Unknown"),
            id = item.application_id or (item.name or ""),
            version = item.version or (item.branch or ""),
            branch = item.branch or "",
            origin = item.origin or "",
            download_formatted = item.download_size or "",
            install_formatted = item.installed_size or "",
          })
        end
      end
      state.flatpak.count = #packages
      state.flatpak.packages = packages
      state.flatpak.status = "done"
      state.flatpak.error = nil
      onFinished(true)
    else
      if result.exitCode ~= 0 then
        state.flatpak.status = "error"
        state.flatpak.error = result.stderr ~= "" and result.stderr or (err or "Flatpak check failed")
        onFinished(false)
      else
        state.flatpak.count = 0
        state.flatpak.packages = {}
        state.flatpak.total_download_bytes = 0
        state.flatpak.total_install_bytes = 0
        state.flatpak.total_download_formatted = "0 B"
        state.flatpak.total_install_formatted = "0 B"
        state.flatpak.status = "done"
        state.flatpak.error = nil
        onFinished(true)
      end
    end
  end)
end

local function checkAll(force)
  if isChecking or isUpdating then
    return
  end

  isChecking = true
  state.status = "CHECKING"
  publishState()

  local dnfDone = false
  local flatpakDone = false
  local dnfSuccess = false
  local flatpakSuccess = false

  local function finalize()
    if not dnfDone or not flatpakDone then
      return
    end

    isChecking = false
    state.total_count = state.dnf.count + state.flatpak.count
    state.total_download_bytes = (state.dnf.total_download_bytes or 0) + (state.flatpak.total_download_bytes or 0)
    state.total_install_bytes = (state.dnf.total_install_bytes or 0) + (state.flatpak.total_install_bytes or 0)
    state.total_download_formatted = formatBytes(state.total_download_bytes)
    state.total_install_formatted = formatBytes(state.total_install_bytes)
    state.last_check = noctalia.formatTime("%H:%M")
    state.last_check_timestamp = os.time()

    if state.dnf.error and state.flatpak.error then
      state.status = "ERROR"
      state.error_message = state.dnf.error .. " | " .. state.flatpak.error
    elseif state.dnf.error then
      state.status = "ERROR"
      state.error_message = state.dnf.error
    elseif state.flatpak.error then
      state.status = "ERROR"
      state.error_message = state.flatpak.error
    else
      state.status = state.total_count == 0 and "SUCCESS" or "IDLE"
      state.error_message = nil
    end

    -- Send notification when new updates are detected
    if notifyOnUpdates and state.total_count > previousCount and state.total_count > 0 then
      noctalia.notify(
        noctalia.tr("notifications.updates_available_title"),
        noctalia.trp("notifications.updates_available_body", state.total_count, { count = state.total_count })
      )
    end
    previousCount = state.total_count

    publishState()
  end

  checkDnf(function(ok)
    dnfDone = true
    dnfSuccess = ok
    finalize()
  end)

  checkFlatpak(function(ok)
    flatpakDone = true
    flatpakSuccess = ok
    finalize()
  end)
end

local function updateDnf(excludedList, onFinished)
  local dnfBin = getDnfBinary()
  if not dnfBin then
    state.dnf.status = "error"
    state.dnf.error = "DNF not found"
    if onFinished then onFinished(false) end
    return
  end

  local dnfCount = state.dnf.count or 0
  if excludedList and type(excludedList) == "table" and #excludedList >= dnfCount and dnfCount > 0 then
    state.dnf.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  local excludeArg = nil
  if excludedList and type(excludedList) == "table" and #excludedList > 0 then
    excludeArg = "--exclude=" .. table.concat(excludedList, ",")
  end

  if updateInTerminal then
    local cmd = "pkexec " .. dnfBin .. " upgrade"
    if excludeArg then
      cmd = cmd .. " " .. excludeArg
    end
    noctalia.runInTerminal(cmd)
    state.dnf.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  state.dnf.status = "updating"
  state.status = "UPDATING"
  publishState()

  local args = { "pkexec", dnfBin, "upgrade", "-y" }
  if excludeArg then
    table.insert(args, excludeArg)
  end

  noctalia.runAsync(args, function(result)
    if result.exitCode == 0 then
      state.dnf.status = "done"
      state.dnf.error = nil
      if onFinished then onFinished(true) end
    else
      state.dnf.status = "error"
      state.dnf.error = result.stderr ~= "" and result.stderr or "DNF upgrade failed"
      if onFinished then onFinished(false) end
    end
    publishState()
  end)
end

local function updateFlatpak(selectedList, onFinished)
  if not noctalia.commandExists("flatpak") then
    state.flatpak.status = "error"
    state.flatpak.error = "Flatpak not found"
    if onFinished then onFinished(false) end
    return
  end

  if selectedList and type(selectedList) == "table" and #selectedList == 0 and (state.flatpak.count or 0) > 0 then
    state.flatpak.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  if updateInTerminal then
    local cmd = "flatpak update"
    if selectedList and type(selectedList) == "table" and #selectedList > 0 then
      for _, ref in ipairs(selectedList) do
        cmd = cmd .. " " .. ref
      end
    end
    noctalia.runInTerminal(cmd)
    state.flatpak.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  state.flatpak.status = "updating"
  state.status = "UPDATING"
  publishState()

  local args = { "flatpak", "update", "-y", "--noninteractive" }
  if selectedList and type(selectedList) == "table" and #selectedList > 0 then
    for _, ref in ipairs(selectedList) do
      table.insert(args, ref)
    end
  end

  noctalia.runAsync(args, function(result)
    if result.exitCode == 0 then
      state.flatpak.status = "done"
      state.flatpak.error = nil
      if onFinished then onFinished(true) end
    else
      state.flatpak.status = "error"
      state.flatpak.error = result.stderr ~= "" and result.stderr or "Flatpak update failed"
      if onFinished then onFinished(false) end
    end
    publishState()
  end)
end

local function updateAll(excludedDnf, selectedFlatpaks)
  if isUpdating or isChecking then
    return
  end

  isUpdating = true
  state.status = "UPDATING"

  local dnfCount = (state.dnf and state.dnf.count) or 0
  local flatpakCount = (state.flatpak and state.flatpak.count) or 0

  local excludedDnfCount = (excludedDnf and type(excludedDnf) == "table") and #excludedDnf or 0
  local dnfNeedsUpdate = enableDnf and dnfCount > 0 and (excludedDnfCount < dnfCount)

  local flatpakNeedsUpdate = enableFlatpak and flatpakCount > 0
  if flatpakNeedsUpdate and selectedFlatpaks and type(selectedFlatpaks) == "table" and #selectedFlatpaks == 0 then
    flatpakNeedsUpdate = false
  end

  if not dnfNeedsUpdate and not flatpakNeedsUpdate then
    isUpdating = false
    checkAll(true)
    return
  end

  if dnfNeedsUpdate and flatpakNeedsUpdate then
    state.dnf.status = "updating"
    state.flatpak.status = "waiting"
    publishState()

    updateDnf(excludedDnf, function(dnfOk)
      state.flatpak.status = "updating"
      publishState()

      updateFlatpak(selectedFlatpaks, function(flatpakOk)
        isUpdating = false
        if dnfOk and flatpakOk then
          noctalia.notify(
            noctalia.tr("notifications.update_complete_title"),
            noctalia.tr("notifications.update_complete_body")
          )
        else
          noctalia.notifyError(
            noctalia.tr("notifications.update_failed_title"),
            noctalia.tr("notifications.update_failed_body")
          )
        end
        checkAll(true)
      end)
    end)
  elseif dnfNeedsUpdate then
    state.dnf.status = "updating"
    publishState()
    updateDnf(excludedDnf, function(ok)
      isUpdating = false
      if ok then
        noctalia.notify(
          noctalia.tr("notifications.update_complete_title"),
          noctalia.tr("notifications.update_complete_body")
        )
      else
        noctalia.notifyError(
          noctalia.tr("notifications.update_failed_title"),
          noctalia.tr("notifications.update_failed_body")
        )
      end
      checkAll(true)
    end)
  elseif flatpakNeedsUpdate then
    state.flatpak.status = "updating"
    publishState()
    updateFlatpak(selectedFlatpaks, function(ok)
      isUpdating = false
      if ok then
        noctalia.notify(
          noctalia.tr("notifications.update_complete_title"),
          noctalia.tr("notifications.update_complete_body")
        )
      else
        noctalia.notifyError(
          noctalia.tr("notifications.update_failed_title"),
          noctalia.tr("notifications.update_failed_body")
        )
      end
      checkAll(true)
    end)
  end
end

-- Watch for commands from widget and panel
noctalia.state.watch("service_command", function(cmd)
  if type(cmd) ~= "table" or not cmd.action then
    return
  end

  if cmd.action == "check_now" then
    checkAll(true)
  elseif cmd.action == "update_all" then
    updateAll(cmd.excluded_dnf, cmd.selected_flatpak)
  elseif cmd.action == "update_dnf" then
    if not isUpdating then
      isUpdating = true
      updateDnf(cmd.excluded_dnf, function()
        isUpdating = false
        checkAll(true)
      end)
    end
  elseif cmd.action == "update_flatpak" then
    if not isUpdating then
      isUpdating = true
      updateFlatpak(cmd.selected_flatpak, function()
        isUpdating = false
        checkAll(true)
      end)
    end
  end
end)

function onConfigChanged()
  checkInterval = noctalia.getConfig("check_interval") or 30
  enableDnf = noctalia.getConfig("enable_dnf") ~= false
  enableFlatpak = noctalia.getConfig("enable_flatpak") ~= false
  notifyOnUpdates = noctalia.getConfig("notify_on_updates") ~= false
  updateInTerminal = noctalia.getConfig("update_in_terminal") == true
  elapsedMinutes = 0
  checkAll(true)
end

function onIpc(event, payload)
  local p = (type(payload) == "table") and payload or {}
  if event == "check" or event == "check_now" then
    checkAll(true)
  elseif event == "update" or event == "update_all" then
    updateAll(p.excluded_dnf, p.selected_flatpak)
  elseif event == "update_dnf" then
    if not isUpdating then
      isUpdating = true
      updateDnf(p.excluded_dnf, function()
        isUpdating = false
        checkAll(true)
      end)
    end
  elseif event == "update_flatpak" then
    if not isUpdating then
      isUpdating = true
      updateFlatpak(p.selected_flatpak, function()
        isUpdating = false
        checkAll(true)
      end)
    end
  end
end

-- Timer tick: runs once every 60 seconds (60000ms)
noctalia.setUpdateInterval(60000)

function update()
  elapsedMinutes += 1
  if checkInterval > 0 and elapsedMinutes >= checkInterval then
    elapsedMinutes = 0
    checkAll(false)
  end
end

-- Initial state publish and immediate check on startup
publishState()
checkAll(true)
