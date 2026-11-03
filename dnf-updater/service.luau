--!nonstrict
-- Headless [[service]] entry: monitors and manages DNF5 and Flatpak updates.
-- Publishes state updates to noctalia.state so the bar widget and panel stay synchronized.

local checkInterval = noctalia.getConfig("check_interval") or 30
local enableDnf = noctalia.getConfig("enable_dnf") ~= false
local enableFlatpak = noctalia.getConfig("enable_flatpak") ~= false
local notifyOnUpdates = noctalia.getConfig("notify_on_updates") ~= false
local updateInTerminal = noctalia.getConfig("update_in_terminal") ~= false
local includeFlatpakRuntimes = noctalia.getConfig("include_flatpak_runtimes") == true

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
  last_update_timestamp = 0,
  reboot_required = false,
  error_message = nil,
}

local previousCount = 0
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

local function parseSizeToBytes(sizeStr)
  if not sizeStr or type(sizeStr) ~= "string" or sizeStr == "" then
    return 0
  end
  local s = sizeStr:gsub(",", ".")
  local numStr, unit = s:match("([%d%.]+).-([%a]+)")
  if not numStr or not unit then
    return 0
  end
  local num = tonumber(numStr)
  if not num or num <= 0 then
    return 0
  end
  unit = string.upper(unit)
  if unit == "B" or unit == "BYTES" then
    return math.floor(num)
  elseif unit == "KIB" then
    return math.floor(num * 1024)
  elseif unit == "KB" or unit == "K" then
    return math.floor(num * 1000)
  elseif unit == "MIB" then
    return math.floor(num * 1024 * 1024)
  elseif unit == "MB" or unit == "M" then
    return math.floor(num * 1000 * 1000)
  elseif unit == "GIB" then
    return math.floor(num * 1024 * 1024 * 1024)
  elseif unit == "GB" or unit == "G" then
    return math.floor(num * 1000 * 1000 * 1000)
  elseif unit == "TIB" then
    return math.floor(num * 1024 * 1024 * 1024 * 1024)
  elseif unit == "TB" or unit == "T" then
    return math.floor(num * 1000 * 1000 * 1000 * 1000)
  end
  return math.floor(num)
end

-- Persisted so a shell restart shows the last result instead of re-checking: with a
-- daily/weekly interval, checking on every login defeated the point.
local function stateFile()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/state.json") or nil
end

local function saveState()
  local path = stateFile()
  local encoded = path and noctalia.json.encode(state)
  if encoded then
    noctalia.writeFile(path, encoded)
  end
end

local function loadState()
  local path = stateFile()
  if not path or not noctalia.fileExists(path) then
    return false
  end
  local contents = noctalia.readFile(path)
  local saved = contents and noctalia.json.decode(contents)
  if type(saved) ~= "table" or type(saved.last_check_timestamp) ~= "number" then
    return false
  end
  state = saved
  state.status = state.error_message and "ERROR" or (state.total_count == 0 and "SUCCESS" or "IDLE")
  state.reboot_required = saved.reboot_required == true
  previousCount = state.total_count or 0
  return true
end

local function checkDue()
  return checkInterval > 0 and os.time() - (state.last_check_timestamp or 0) >= checkInterval * 60
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

local function isValidPackageName(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  if name:sub(1, 1) == "-" then
    return false
  end
  return name:match("^[%w%._+%-]+$") ~= nil
end

local function isValidFlatpakId(id)
  if type(id) ~= "string" or id == "" then
    return false
  end
  if id:sub(1, 1) == "-" then
    return false
  end
  return id:match("^[%w%._%-%/]+$") ~= nil
end

local function shellQuote(str)
  return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

local function checkDnf(onFinished, isRetry)
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
      if not isRetry then
        print("[dnf-updater] DNF check timed out; retrying once...")
        checkDnf(onFinished, true)
        return
      end
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
        end, 30000)
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
  end, 30000)
end

local function checkFlatpak(onFinished, isRetry)
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

  local flatpakArgs = { "flatpak", "remote-ls", "--updates", "--columns=name,application,version,branch,origin,installed-size,download-size,ref", "-j" }
  if not includeFlatpakRuntimes then
    table.insert(flatpakArgs, 4, "--app")
  end

  noctalia.runAsync(flatpakArgs, function(result)
    if result.timedOut then
      if not isRetry then
        print("[dnf-updater] Flatpak check timed out; retrying once...")
        checkFlatpak(onFinished, true)
        return
      end
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
      local flatpakTotalDownload = 0
      local flatpakTotalInstall = 0
      for _, item in ipairs(decoded) do
        if type(item) == "table" then
          local dlBytes = parseSizeToBytes(item.download_size)
          local instBytes = parseSizeToBytes(item.installed_size)
          flatpakTotalDownload += dlBytes
          flatpakTotalInstall += instBytes

          local isRuntime = (item.ref and item.ref:find("^runtime/") ~= nil) or false
          table.insert(packages, {
            name = item.name or (item.application_id or "Unknown"),
            id = (item.application_id and item.application_id ~= "") and item.application_id or (item.ref or (item.name or "")),
            ref = item.ref or "",
            version = item.version or (item.branch or ""),
            branch = item.branch or "",
            origin = item.origin or "",
            is_runtime = isRuntime,
            download_bytes = dlBytes,
            install_bytes = instBytes,
            download_formatted = (item.download_size and item.download_size ~= "") and item.download_size or formatBytes(dlBytes),
            install_formatted = (item.installed_size and item.installed_size ~= "") and item.installed_size or formatBytes(instBytes),
          })
        end
      end
      state.flatpak.count = #packages
      state.flatpak.packages = packages
      state.flatpak.total_download_bytes = flatpakTotalDownload
      state.flatpak.total_install_bytes = flatpakTotalInstall
      state.flatpak.total_download_formatted = formatBytes(flatpakTotalDownload)
      state.flatpak.total_install_formatted = formatBytes(flatpakTotalInstall)
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
  end, 30000)
end

-- Read from dnf history rather than recorded on our own runs: terminal updates are
-- fire-and-forget, and a manual `dnf upgrade` counts too. Only an upgrade with no
-- package args is a full update; Flatpak keeps no history, so it is not tracked.
local function isFullUpgrade(commandLine)
  local verbSeen = false
  for word in (commandLine or ""):gmatch("%S+") do
    if verbSeen then
      if word:sub(1, 1) ~= "-" then
        return false
      end
    elseif word == "upgrade" or word == "update" or word == "distro-sync" then
      verbSeen = true
    end
  end
  return verbSeen
end

local function refreshLastUpdate()
  local dnfBin = getDnfBinary()
  if not dnfBin then
    return
  end
  noctalia.runAsync({ dnfBin, "history", "list", "--json" }, function(result)
    local transactions = result and result.exitCode == 0 and noctalia.json.decode(result.stdout or "")
    if type(transactions) ~= "table" then
      return
    end
    local latest = 0
    for _, t in ipairs(transactions) do
      if t.status == "Ok" and (t.end_time or 0) > latest and isFullUpgrade(t.command_line) then
        latest = t.end_time
      end
    end
    if latest > 0 and latest ~= state.last_update_timestamp then
      state.last_update_timestamp = latest
      publishState()
    end
  end)
end

local function checkReboot()
  if noctalia.fileExists("/run/reboot-required") or noctalia.fileExists("/var/run/reboot-required") then
    if not state.reboot_required then
      state.reboot_required = true
      publishState()
    end
    return
  end

  local dnfBin = getDnfBinary()
  if not dnfBin then
    return
  end

  noctalia.runAsync({ dnfBin, "--disablerepo=*", "needs-restarting", "-r", "--json" }, function(result)
    local isReboot = false
    if result then
      if result.exitCode == 1 then
        isReboot = true
      elseif result.exitCode == 0 and result.stdout and result.stdout ~= "" then
        local data = noctalia.json.decode(result.stdout)
        if type(data) == "table" and data[1] and data[1].reboot_required == true then
          isReboot = true
        end
      end
    end
    if isReboot ~= state.reboot_required then
      state.reboot_required = isReboot
      publishState()
    end
  end, 10000)
end

local function checkAll(force)
  if isChecking or isUpdating then
    return
  end

  isChecking = true
  state.status = "CHECKING"
  publishState()
  refreshLastUpdate()
  checkReboot()

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
    state.last_check = noctalia.formatTime("%d/%m %H:%M")
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
    saveState()
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

-- runInTerminal is fire-and-forget, so the terminal itself pings us back when done
-- (`;`, not `&&`: a failed or partial run still changes what is pending).
local function runInTerminalThenRecheck(cmd)
  noctalia.runInTerminal(cmd .. "; noctalia msg plugin strob3/dnf-updater:service all check")
end

local function updateDnf(excludedList, onFinished)
  local dnfBin = getDnfBinary()
  if not dnfBin then
    state.dnf.status = "error"
    state.dnf.error = "DNF not found"
    if onFinished then onFinished(false) end
    return
  end

  local validExcluded = {}
  if excludedList and type(excludedList) == "table" then
    for _, name in ipairs(excludedList) do
      if isValidPackageName(name) then
        table.insert(validExcluded, name)
      else
        print(string.format("[dnf-updater] Warning: invalid DNF package name skipped: %s", tostring(name)))
      end
    end
  end

  local dnfCount = state.dnf.count or 0
  if excludedList and type(excludedList) == "table" and #validExcluded >= dnfCount and dnfCount > 0 then
    state.dnf.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  local excludeArg = nil
  if #validExcluded > 0 then
    excludeArg = "--exclude=" .. table.concat(validExcluded, ",")
  end

  if updateInTerminal then
    local sudoCmd = noctalia.commandExists("sudo") and "sudo" or "pkexec"
    local cmd = sudoCmd .. " " .. dnfBin .. " upgrade -y"
    if excludeArg then
      cmd = cmd .. " " .. shellQuote(excludeArg)
    end
    runInTerminalThenRecheck(cmd)
    state.dnf.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  state.dnf.status = "updating"
  state.status = "UPDATING"
  publishState()

  local helperBin = "/usr/local/bin/dnf-updater-helper"
  local args
  if noctalia.fileExists(helperBin) then
    args = { "pkexec", helperBin, "upgrade" }
  else
    args = { "pkexec", dnfBin, "upgrade", "-y" }
  end
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
      local errMsg = "DNF upgrade failed"
      if result.timedOut then
        errMsg = "DNF upgrade timed out (consider running updates in terminal)"
      elseif result.stderr and result.stderr ~= "" then
        errMsg = result.stderr
      elseif result.stdout and result.stdout ~= "" then
        errMsg = result.stdout
      end
      state.dnf.error = errMsg
      if onFinished then onFinished(false) end
    end
    publishState()
  end, 600000)
end

local function updateFlatpak(selectedList, onFinished)
  if not noctalia.commandExists("flatpak") then
    state.flatpak.status = "error"
    state.flatpak.error = "Flatpak not found"
    if onFinished then onFinished(false) end
    return
  end

  local validSelected = nil
  if selectedList and type(selectedList) == "table" then
    validSelected = {}
    local seen = {}
    for _, ref in ipairs(selectedList) do
      if isValidFlatpakId(ref) and not seen[ref] then
        seen[ref] = true
        table.insert(validSelected, ref)
      elseif not isValidFlatpakId(ref) then
        print(string.format("[dnf-updater] Warning: invalid Flatpak ID skipped: %s", tostring(ref)))
      end
    end
  end

  if selectedList and type(selectedList) == "table" and #selectedList == 0 and (state.flatpak.count or 0) > 0 then
    state.flatpak.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  if selectedList and type(selectedList) == "table" and #selectedList > 0 and validSelected and #validSelected == 0 then
    print("[dnf-updater] Warning: all selected Flatpak IDs were invalid; skipping update")
    state.flatpak.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  local flatpakCount = (state.flatpak and state.flatpak.count) or 0
  local hasSubset = validSelected and #validSelected > 0 and #validSelected < flatpakCount

  if updateInTerminal then
    local cmd = "flatpak update -y"
    if hasSubset then
      for _, ref in ipairs(validSelected) do
        cmd = cmd .. " " .. shellQuote(ref)
      end
    end
    runInTerminalThenRecheck(cmd)
    state.flatpak.status = "done"
    publishState()
    if onFinished then onFinished(true) end
    return
  end

  state.flatpak.status = "updating"
  state.status = "UPDATING"
  publishState()

  local args = { "flatpak", "update", "-y", "--noninteractive" }
  if hasSubset then
    for _, ref in ipairs(validSelected) do
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
      local errMsg = "Flatpak update failed"
      if result.timedOut then
        errMsg = "Flatpak update timed out (consider running updates in terminal)"
      elseif result.stderr and result.stderr ~= "" then
        errMsg = result.stderr
      elseif result.stdout and result.stdout ~= "" then
        errMsg = result.stdout
      end
      state.flatpak.error = errMsg
      if onFinished then onFinished(false) end
    end
    publishState()
  end, 600000)
end

local function updateAll(excludedDnf, selectedFlatpaks)
  if isUpdating or isChecking then
    return
  end

  isUpdating = true
  state.status = "UPDATING"

  local dnfCount = (state.dnf and state.dnf.count) or 0
  local flatpakCount = (state.flatpak and state.flatpak.count) or 0

  local validExcluded = {}
  if excludedDnf and type(excludedDnf) == "table" then
    for _, name in ipairs(excludedDnf) do
      if isValidPackageName(name) then
        table.insert(validExcluded, name)
      end
    end
  end
  local dnfNeedsUpdate = enableDnf and dnfCount > 0 and (#validExcluded < dnfCount)

  local validSelected = nil
  if selectedFlatpaks and type(selectedFlatpaks) == "table" then
    validSelected = {}
    local seen = {}
    for _, ref in ipairs(selectedFlatpaks) do
      if isValidFlatpakId(ref) and not seen[ref] then
        seen[ref] = true
        table.insert(validSelected, ref)
      end
    end
  end
  local flatpakNeedsUpdate = enableFlatpak and flatpakCount > 0
  if flatpakNeedsUpdate and selectedFlatpaks and type(selectedFlatpaks) == "table" and #validSelected == 0 then
    flatpakNeedsUpdate = false
  end

  if not dnfNeedsUpdate and not flatpakNeedsUpdate then
    isUpdating = false
    checkAll(true)
    return
  end

  if updateInTerminal then
    local cmds = {}
    local dnfBin = getDnfBinary()

    if dnfNeedsUpdate and dnfBin then
      local sudoCmd = noctalia.commandExists("sudo") and "sudo" or "pkexec"
      local dnfCmd = sudoCmd .. " " .. dnfBin .. " upgrade -y"
      if #validExcluded > 0 then
        dnfCmd = dnfCmd .. " " .. shellQuote("--exclude=" .. table.concat(validExcluded, ","))
      end
      table.insert(cmds, dnfCmd)
    end

    if flatpakNeedsUpdate then
      local fpCmd = "flatpak update -y"
      if validSelected and #validSelected > 0 and #validSelected < flatpakCount then
        for _, ref in ipairs(validSelected) do
          fpCmd = fpCmd .. " " .. shellQuote(ref)
        end
      end
      table.insert(cmds, fpCmd)
    end

    if #cmds > 0 then
      local fullCmd = table.concat(cmds, " && ")
      runInTerminalThenRecheck(fullCmd)
      if dnfNeedsUpdate then state.dnf.status = "done" end
      if flatpakNeedsUpdate then state.flatpak.status = "done" end
      state.status = "SUCCESS"
      publishState()
    end

    isUpdating = false
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
    if not isUpdating and not isChecking then
      isUpdating = true
      updateDnf(cmd.excluded_dnf, function()
        isUpdating = false
        checkAll(true)
      end)
    end
  elseif cmd.action == "update_flatpak" then
    if not isUpdating and not isChecking then
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
  includeFlatpakRuntimes = noctalia.getConfig("include_flatpak_runtimes") == true
  notifyOnUpdates = noctalia.getConfig("notify_on_updates") ~= false
  updateInTerminal = noctalia.getConfig("update_in_terminal") ~= false
  if checkDue() then
    checkAll(true)
  end
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
  if checkDue() then
    checkAll(false)
  end
end

local restored = loadState()
publishState()
if not restored or checkDue() then
  checkAll(true)
end
