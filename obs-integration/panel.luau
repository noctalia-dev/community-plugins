--!nonstrict

local OSC_CONFIG = noctalia.expandPath("~/.config/osc/oscrc")
local CACHE_FILE = "projects_cache.json"
local NAV_FILE = "nav_state.json"

local projects = {}
local packages = {}
local selectedProject = nil
local selectedPackage = nil
local packageFilter = ""
local projectFilter = ""
local sortAsc = true
local editFilesOpen = false
local editFilesOpenMap = {}
local filesOpen = false
local filesOpenMap = {}
local packageFiles = {}
local rebuildArchIndex = 0
local rebuildRepos = {}
local rebuildRepoIndex = 0
local rebuildConfirm = false
local runAllConfirm = false
local repoMap = {}
local statusMap = {}
local savedRebuildRepo = nil
local savedRebuildArch = nil
local rebuildLoaded = false
local busyByPkg = {}

local function pkgKey(project, pkg)
	return tostring(project) .. "/" .. tostring(pkg)
end

local function isBusy(action, project, pkg)
	local entry = busyByPkg[pkgKey(project, pkg)]
	return entry ~= nil and entry.action == action
end

local function setBusy(action, project, pkg, status)
	busyByPkg[pkgKey(project, pkg)] = { action = action, status = status or "" }
end

local function clearBusy(project, pkg)
	if project ~= nil and pkg ~= nil then
		busyByPkg[pkgKey(project, pkg)] = nil
	else
		busyByPkg = {}
	end
end

local function currentBusy()
	return busyByPkg[pkgKey(selectedProject, selectedPackage)]
end
local loadPackageFiles
local resolveCheckoutDir
local maintainerMap = {}
local ownedProjects = {}
local projectsLoading = false
local packagesLoading = false
local errorText = ""
local commandLog = ""
local logsByPkg = {}
local logsOpenMap = {}
local pendingProject = nil
local removeConfirm = false
local removeFileConfirm = false
local removeFileTarget = nil
local restoreProject = nil
local restorePackage = nil
local restoreFilesOpen = false
local restoreLogsByPkg = nil
local restoreLogsOpenMap = nil
local restoreBusyByPkg = nil
local saveCache
local saveNav
local maybeVerify

local ownedDone = false
local oscUser = nil
local oscWhoPending = false

-- Shared reset for the package detail view (back-nav, project switch,
-- package switch). Single source so the three call sites can't drift.
local function resetPackageView()
	editFilesOpen = false
	filesOpen = false
	packageFiles = {}
	removeConfirm = false
	rebuildArchIndex = 0
	rebuildRepos = {}
	rebuildRepoIndex = 0
	repoMap = {}
	statusMap = {}
	savedRebuildRepo = nil
	savedRebuildArch = nil
	rebuildLoaded = false
	rebuildConfirm = false
	runAllConfirm = false
end

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function commandError(result)
	return noctalia.string.trim(result.stderr ~= "" and result.stderr or result.stdout)
end

local function currentLog()
	return logsByPkg[pkgKey(selectedProject, selectedPackage)] or { error = "", output = "" }
end

local function setCommandLog(result, emptyMsg, project, pkg)
	local err = commandError(result)
	local entry = { error = "", output = "" }
	if result.exitCode ~= 0 then
		entry.error = err ~= "" and err or ("Command failed (exit " .. tostring(result.exitCode) .. ")")
	else
		local output = noctalia.string.trim(result.stdout)
		if output == "" and emptyMsg then
			output = emptyMsg
		end
		entry.output = output
	end
	logsByPkg[pkgKey(project, pkg)] = entry
	errorText = entry.error
	commandLog = entry.output
	render()
	saveNav()
end

local function runActionAsync(cmd, statusText, refreshFiles, pkgDir, pkg, emptyMsg, action)
	local project = selectedProject
	local package = selectedPackage
	setBusy(action, project, package, statusText)
	render()
	saveNav()
	noctalia.runAsync(cmd, function(result)
		clearBusy(project, package)
		if refreshFiles and result.exitCode == 0 then
			local dir = pkgDir
			if not dir then
				local checkoutDir = resolveCheckoutDir()
				dir = checkoutDir .. "/" .. project .. "/" .. package
			end
			loadPackageFiles(dir, pkg or package)
		end
		setCommandLog(result, emptyMsg, project, package)
	end, 60000)
end

-- OBS project/package identifiers: reject anything that could escape the
-- checkout dir or inject into shell commands (slashes, leading dots, spaces).
local function validName(value)
	return type(value) == "string"
		and value ~= ""
		and not value:find("/", 1, true)
		and value:match("^[%w:.+%-_]+$") ~= nil
		and value:match("^%.") == nil
end

resolveCheckoutDir = function()
	local checkoutDir = noctalia.getConfig("checkout_dir")
	if type(checkoutDir) ~= "string" or checkoutDir:match("^%s*$") then
		checkoutDir = "~/OBS"
	end
	return noctalia.expandPath(checkoutDir)
end


-- Estimate the combined width (px) of the two .changes buttons to decide
-- whether they fit side-by-side or must stack.
local function changesButtonsFit(pkg)
	-- Rough per-char width at the button font size, plus glyph+padding budget.
	local charW = 7
	local base = 16 + 24
	local editW = (#"Edit " + #pkg + #".changes") * charW + base
	local updateW = (#"Update " + #pkg + #".changes") * charW + base
	return editW + updateW + 8 <= 396
end

local function parseLines(stdout)
	local out = {}
	for line in tostring(stdout or ""):gmatch("[^\n]+") do
		line = noctalia.string.trim(line)
		if line ~= "" then
			table.insert(out, line)
		end
	end
	return out
end

local function filterList(list, filter, ascending)
	local lower = filter:lower()
	local filtered
	if filter == "" then
		filtered = list
	else
		filtered = {}
		for _, name in ipairs(list) do
			if name:lower():find(lower, 1, true) then
				table.insert(filtered, name)
			end
		end
	end
	table.sort(filtered, function(a, b)
		if ascending then
			return a < b
		else
			return a > b
		end
	end)
	return filtered
end

local function configureOsc()
	noctalia.runInTerminal("osc version")
end

local function checkoutPackage(project, pkg)
	if not validName(project) or not validName(pkg) then
		return
	end
	local checkoutDir = resolveCheckoutDir()
	local pkgPath = checkoutDir .. "/" .. project .. "/" .. pkg
	setBusy("checkout", project, pkg, noctalia.tr("panel.checking_out"))
	render()
	saveNav()

	noctalia.runAsync(
		"cd " .. shellQuote(checkoutDir) .. " && osc co " .. shellQuote(project) .. " " .. shellQuote(pkg),
		function(result)
			clearBusy(project, pkg)
			if result.exitCode == 0 then
				setCommandLog({ exitCode = 0, stdout = "", stderr = "" }, nil, project, pkg)
				loadPackageFiles(pkgPath, pkg)
			else
				setCommandLog(result, nil, project, pkg)
			end
			render()
			saveNav()
		end,
		60000
	)
end

local function editProjectMeta(project)
	if not validName(project) then
		return
	end
	noctalia.runInTerminal("osc meta prj " .. shellQuote(project) .. " -e")
end

local function editPackageMeta(project, pkg)
	if not validName(project) or not validName(pkg) then
		return
	end
	noctalia.runInTerminal("osc meta pkg " .. shellQuote(project) .. " " .. shellQuote(pkg) .. " -e")
end

local function rebuildPackage(project, pkg, repo, arch)
	if not validName(project) or not validName(pkg) then
		return
	end
	local cmd = "osc rebuild " .. shellQuote(project) .. " " .. shellQuote(pkg)
	if repo ~= nil and repo ~= "All" and repo ~= "" then
		cmd = cmd .. " -r " .. shellQuote(repo)
	end
	if arch ~= nil and arch ~= "All" and arch ~= "" then
		cmd = cmd .. " -a " .. shellQuote(arch)
	end
	runActionAsync(cmd, noctalia.tr("panel.rebuilding_pkg"), false, nil, nil, nil, "rebuild")
end

local function collectPackageFiles(result, pkg)
	local list = {}
	if result.exitCode == 0 then
		for _, f in ipairs(parseLines(result.stdout)) do
			if f ~= pkg and f ~= ".osc" then
				table.insert(list, f)
			end
		end
	end
	table.sort(list)
	return list
end

loadPackageFiles = function(pkgDir, pkg)
	noctalia.runAsync(
		"find " .. shellQuote(pkgDir) .. " -maxdepth 1 -not -name '.*' -printf '%f\\n'",
		function(result)
			packageFiles = collectPackageFiles(result, pkg)
			render()
		end,
		5000
	)
	-- Re-fetch after a short delay so callers that just created the dir (checkout,
	-- osc up, service runs) settle into the complete file list.
	noctalia.runAsync("sleep 1", function()
		noctalia.runAsync(
			"find " .. shellQuote(pkgDir) .. " -maxdepth 1 -not -name '.*' -printf '%f\\n'",
			function(result)
				packageFiles = collectPackageFiles(result, pkg)
				render()
			end,
			5000
		)
	end, 2000)
end

local function loadRebuildArches(project, pkg)
	rebuildLoaded = false
	rebuildRepos = {}
	repoMap = {}
	statusMap = {}
	noctalia.runAsync("osc results " .. shellQuote(project) .. " " .. shellQuote(pkg), function(result)
		local map = {}
		local statuses = {}
		if result.exitCode == 0 then
			for line in tostring(result.stdout):gmatch("[^\n]+") do
				line = noctalia.string.trim(line)
				local repo, arch, _, status = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
				if status then
					status = status:gsub("%*$", "")
				end
				if repo ~= nil and arch ~= nil and status ~= "disabled" then
					if not map[repo] then
						map[repo] = {}
						statuses[repo] = {}
					end
					local found = false
					for _, a in ipairs(map[repo]) do
						if a == arch then
							found = true
							break
						end
					end
					if not found then
						table.insert(map[repo], arch)
					end
					statuses[repo][arch] = status
				end
			end
		end
		local repos = {}
		for repo in pairs(map) do
			table.insert(repos, repo)
		end
		table.sort(repos)
		for repo in pairs(map) do
			table.sort(map[repo])
		end
		repoMap = map
		statusMap = statuses
		rebuildRepos = repos
		local repoIndex = 0
		if savedRebuildRepo then
			for i, repo in ipairs(repos) do
				if repo == savedRebuildRepo then
					repoIndex = i
					break
				end
			end
		end
		rebuildRepoIndex = repoIndex
		local archIndex = 0
		local repoArchs = savedRebuildRepo and map[savedRebuildRepo] or {}
		if savedRebuildArch then
			for i, arch in ipairs(repoArchs or {}) do
				if arch == savedRebuildArch then
					archIndex = i
					break
				end
			end
		end
		rebuildArchIndex = archIndex
		rebuildLoaded = true
		render()
	end, 15000)
end

local STATUS_STYLE = {
	succeeded = { glyph = "check", color = "secondary", labelKey = "status_succeeded" },
	failure = { glyph = "x", color = "error", labelKey = "status_failed" },
	broken = { glyph = "alert-circle", color = "error", labelKey = "status_broken" },
	unresolvable = { glyph = "alert-circle", color = "error", labelKey = "status_unresolvable" },
	building = { glyph = "loader", color = "primary", labelKey = "status_building" },
	dispatching = { glyph = "loader", color = "primary", labelKey = "status_building" },
	scheduled = { glyph = "clock", color = "on_surface_variant", labelKey = "status_scheduled" },
	signing = { glyph = "lock", color = "warning", labelKey = "status_signing" },
	blocked = { glyph = "clock", color = "on_surface_variant", labelKey = "status_blocked" },
	excluded = { glyph = "ban", color = "on_surface_variant", labelKey = "status_excluded" },
	unbuildable = { glyph = "ban", color = "on_surface_variant", labelKey = "status_unbuildable" },
	finished = { glyph = "circle-dot", color = "tertiary", labelKey = "status_finished" },
	unknown = { glyph = "help-circle", color = "on_surface_variant", labelKey = "status_unknown" },
}

local STATUS_GROUPS = {
	["succeeded"] = "succeeded",
	["success"] = "succeeded",
	["finished"] = "finished",
	["failed"] = "failure",
	["broken"] = "broken",
	["unresolvable"] = "unresolvable",
	["building"] = "building",
	["dispatching"] = "building",
	["scheduled"] = "scheduled",
	["signing"] = "signing",
	["blocked"] = "blocked",
	["excluded"] = "excluded",
	["unbuildable"] = "unbuildable",
	["unknown"] = "unknown",
	["disabled"] = "disabled",
}

local function statusPresentation(status)
	status = status or "unknown"
	local group = STATUS_GROUPS[status] or status
	local base = STATUS_STYLE[group]
	if base then
		return base.glyph, base.color, noctalia.tr("panel." .. base.labelKey), group
	end
	return "help-circle", "on_surface_variant", status, "unknown"
end

local function removeFileLocal(path, pkgDir, pkg)
	noctalia.runAsync("rm " .. shellQuote(path), function(result)
		if result.exitCode == 0 then
			loadPackageFiles(pkgDir, pkg)
		else
			errorText = commandError(result)
			render()
		end
	end, 15000)
end

local function editFilePlain(path)
	noctalia.runInTerminal("${EDITOR:-nano} " .. shellQuote(path))
end

local function editFile(path, pkgDir, pkg, filename)
	if not validName(pkg) then
		return
	end
	if filename:match("%.changes$") then
		noctalia.runInTerminal("cd " .. shellQuote(pkgDir) .. " && osc vc")
	else
		editFilePlain(path)
	end
end

local function oscAddRemove(pkgDir)
	runActionAsync(
		"cd " .. shellQuote(pkgDir) .. " && osc ar",
		noctalia.tr("panel.adding_removing"),
		true,
		pkgDir,
		nil,
		noctalia.tr("panel.no_changes", { name = selectedPackage }),
		"addremove"
	)
end

local function oscCommit(pkgDir, project, pkg)
	local cmd = "cd " .. shellQuote(pkgDir) .. " && osc ci"
	setBusy("commit", project, pkg, noctalia.tr("panel.committing"))
	render()
	saveNav()
	noctalia.runAsync("cd " .. shellQuote(pkgDir) .. " && osc status", function(result)
		local output = result.stdout .. "\n" .. result.stderr
		local hasChanges = result.exitCode == 0 and noctalia.string.trim(output) ~= ""
		if hasChanges then
			clearBusy(project, pkg)
			render()
			saveNav()
			noctalia.runInTerminal(cmd)
		else
			noctalia.runAsync(cmd, function(result)
				clearBusy(project, pkg)
				setCommandLog(result, nil, project, pkg)
			end, 60000)
		end
	end, 15000)
end

local function oscUpdate(pkgDir)
	runActionAsync(
		"cd " .. shellQuote(pkgDir) .. " && osc up",
		noctalia.tr("panel.updating_dir"),
		true,
		pkgDir,
		nil,
		nil,
		"update"
	)
end

local function oscServiceRun(pkgDir)
	runActionAsync(
		"cd " .. shellQuote(pkgDir) .. " && osc service mr",
		noctalia.tr("panel.running_manual_service"),
		true,
		pkgDir,
		nil,
		nil,
		"service_manual"
	)
end

local function oscServiceRemoteRun(project, pkg)
	runActionAsync(
		"osc service rr " .. shellQuote(project) .. " " .. shellQuote(pkg),
		noctalia.tr("panel.running_remote_service"),
		false,
		nil,
		nil,
		nil,
		"service_remote"
	)
end

local function oscServiceLocalRun(pkgDir)
	runActionAsync(
		"cd " .. shellQuote(pkgDir) .. " && osc service r",
		noctalia.tr("panel.running_local_service"),
		true,
		pkgDir,
		nil,
		nil,
		"service_local"
	)
end

local function oscServiceRunAll(pkgDir)
	runActionAsync(
		"cd " .. shellQuote(pkgDir) .. " && osc service ra",
		noctalia.tr("panel.running_all_services"),
		true,
		pkgDir,
		nil,
		nil,
		"service_all"
	)
end

local function removePackageLocal(project, pkg)
	if not validName(project) or not validName(pkg) then
		return
	end
	local checkoutDir = resolveCheckoutDir()
	local projectDir = checkoutDir .. "/" .. project
	local pkgDir = projectDir .. "/" .. pkg
	local cmd = "rm -rf " .. shellQuote(pkgDir)
		.. "\nif ! ls -A " .. shellQuote(projectDir) .. " | grep -q -v '^\\.osc$'; then rm -rf " .. shellQuote(projectDir) .. "; fi"
	noctalia.runAsync(cmd, function(result)
		if result.exitCode ~= 0 then
			errorText = commandError(result)
		end
		selectedPackage = nil
		removeConfirm = false
		render()
		saveNav()
	end, 15000)
end

local function loadPackages(project)
  selectedProject = project
  selectedPackage = nil
  packageFilter = ""
  resetPackageView()
  packages = maintainerMap[project] or {}

  if #packages == 0 and projectsLoading then
    pendingProject = project
    packagesLoading = true
    render()
    return
  end

  if #packages == 0 and ownedProjects[project] then
    packagesLoading = true
    render()
    noctalia.runAsync("osc ls " .. shellQuote(project), function(result)
      packagesLoading = false
      if result.exitCode == 0 then
        packages = parseLines(result.stdout)
        maintainerMap[project] = packages
        saveCache()
        errorText = ""
      elseif errorText == "" then
        errorText = commandError(result)
      end
      render()
    end, 15000)
    saveNav()
    return
  end

  packagesLoading = false
  render()
  saveNav()
end

local function cachePath()
	local dir, _ = noctalia.pluginDataDir()
	if not dir then
		return nil
	end
	return dir .. "/" .. CACHE_FILE
end

local function navPath()
	local dir, _ = noctalia.pluginDataDir()
	if not dir then
		return nil
	end
	return dir .. "/" .. NAV_FILE
end

saveNav = function()
	local path = navPath()
	if not path then
		return
	end
	noctalia.writeFile(path, noctalia.json.encode({
		project = selectedProject,
		package = selectedPackage,
		filesOpen = filesOpen,
		logsByPkg = logsByPkg,
		logsOpenMap = logsOpenMap,
		busyByPkg = busyByPkg,
	}))
end
local function validNavName(value)
	return validName(value) and value or nil
end

local function readNav()
	local path = navPath()
	if not path or not noctalia.fileExists(path) then
		return nil, nil, false, nil, nil
	end
	local data, _ = noctalia.readFile(path)
	if not data then
		return nil, nil, false, nil, nil
	end
	local parsed, _ = noctalia.json.decode(data)
	if type(parsed) ~= "table" then
		return nil, nil, false, nil, nil
	end
	local busy = nil
	if type(parsed.busyByPkg) == "table" then
		busy = parsed.busyByPkg
	elseif type(parsed.busyAction) == "string" and type(parsed.busyProject) == "string" and type(parsed.busyPackage) == "string" then
		local key = tostring(parsed.busyProject) .. "/" .. tostring(parsed.busyPackage)
		busy = { [key] = { action = parsed.busyAction, status = type(parsed.actionStatus) == "string" and parsed.actionStatus or "" } }
	end
	local logs = nil
	if type(parsed.logsByPkg) == "table" then
		logs = parsed.logsByPkg
	elseif type(parsed.commandLog) == "string" or type(parsed.errorText) == "string" then
		local proj = validNavName(parsed.project)
		local pkg = validNavName(parsed.package)
		if proj ~= nil and pkg ~= nil then
			logs = { [tostring(proj) .. "/" .. tostring(pkg)] = { error = type(parsed.errorText) == "string" and parsed.errorText or "", output = type(parsed.commandLog) == "string" and parsed.commandLog or "" } }
		end
	end
	local openMap = nil
	if type(parsed.logsOpenMap) == "table" then
		openMap = parsed.logsOpenMap
	elseif parsed.logsOpen == true then
		local proj = validNavName(parsed.project)
		local pkg = validNavName(parsed.package)
		if proj ~= nil and pkg ~= nil then
			openMap = { [tostring(proj) .. "/" .. tostring(pkg)] = true }
		end
	end
	return validNavName(parsed.project), validNavName(parsed.package), parsed.filesOpen == true, logs,
		openMap, busy
end

saveCache = function()
	local path = cachePath()
	if not path or #projects == 0 then
		return
	end
	local ownedList = {}
	for project in pairs(ownedProjects) do
		table.insert(ownedList, project)
	end
	noctalia.writeFile(path, noctalia.json.encode({
		owned = ownedList,
		packages = maintainerMap,
	}))
end

local function prefetchOwnedPackages()
	for project in pairs(ownedProjects) do
		if not maintainerMap[project] then
			noctalia.runAsync("osc ls " .. shellQuote(project), function(result)
				if result.exitCode == 0 and not maintainerMap[project] then
					local list = parseLines(result.stdout)
					maintainerMap[project] = list
					saveCache()
					if selectedProject == project then
						packages = list
						packagesLoading = false
						errorText = ""
						render()
					end
				end
			end, 15000)
		end
	end
end

local function readCache()
	local path = cachePath()
	if not path or not noctalia.fileExists(path) then
		return false
	end
	local data, _ = noctalia.readFile(path)
	if not data then
		return false
	end
	local parsed, _ = noctalia.json.decode(data)
	if type(parsed) ~= "table" then
		return false
	end
	local cachedPkgs = parsed.packages
	local cachedOwned = parsed.owned
	if type(cachedPkgs) ~= "table" or type(cachedOwned) ~= "table" then
		return false
	end
	for key, list in pairs(cachedPkgs) do
		if type(key) ~= "string" or type(list) ~= "table" then
			return false
		end
	end
	maintainerMap = cachedPkgs
	ownedProjects = {}
	for _, project in ipairs(cachedOwned) do
		ownedProjects[project] = true
	end
	projects = {}
	local seen = {}
	for project in pairs(maintainerMap) do
		projects[#projects + 1] = project
		seen[project] = true
	end
	for project in pairs(ownedProjects) do
		if not seen[project] then
			projects[#projects + 1] = project
		end
	end
	table.sort(projects)
	return true
end

local function finalize()
  local merged = {}
  for project in pairs(ownedProjects) do
    merged[project] = true
  end
  for project in pairs(maintainerMap) do
    merged[project] = true
  end
  projects = {}
  for project in pairs(merged) do
    table.insert(projects, project)
  end
  table.sort(projects)

  saveCache()

  local deferred = pendingProject
  pendingProject = nil
  projectsLoading = false
  if deferred then
    loadPackages(deferred)
    return
  end
  render()
  prefetchOwnedPackages()
end

local function loadProjects(clearNav)
  readCache()

  selectedProject = nil
  selectedPackage = nil
  packages = {}
  projectFilter = ""
  pendingProject = nil
  projectsLoading = true
  ownedDone = false
  oscUser = nil
  oscWhoPending = false

  if restoreProject then
    local proj = restoreProject
    local pkg = restorePackage
    local filesOpenRestore = restoreFilesOpen
    local logsByPkgRestore = restoreLogsByPkg
    local logsOpenMapRestore = restoreLogsOpenMap
    local busyByPkgRestore = restoreBusyByPkg
    restoreProject = nil
    restorePackage = nil
    restoreFilesOpen = false
    restoreLogsByPkg = nil
    restoreLogsOpenMap = nil
    restoreBusyByPkg = nil
    if proj and (maintainerMap[proj] or ownedProjects[proj]) then
      projectsLoading = false
      loadPackages(proj)
      if pkg and validName(pkg) then
        selectedPackage = pkg
        filesOpen = filesOpenRestore
        logsByPkg = {}
        if type(logsByPkgRestore) == "table" then
          for key, entry in pairs(logsByPkgRestore) do
            if type(key) == "string" and type(entry) == "table" then
              logsByPkg[key] = {
                error = type(entry.error) == "string" and entry.error or "",
                output = type(entry.output) == "string" and entry.output or "",
              }
            end
          end
        end
        logsOpenMap = {}
        if type(logsOpenMapRestore) == "table" then
          for key, value in pairs(logsOpenMapRestore) do
            if type(key) == "string" and value == true then
              logsOpenMap[key] = true
            end
          end
        end
        local restored = logsByPkg[pkgKey(proj, pkg)] or { error = "", output = "" }
        errorText = restored.error
        commandLog = restored.output
        busyByPkg = {}
        if type(busyByPkgRestore) == "table" then
          for key, entry in pairs(busyByPkgRestore) do
            if type(key) == "string" and type(entry) == "table" and type(entry.action) == "string" then
              busyByPkg[key] = { action = entry.action, status = type(entry.status) == "string" and entry.status or "" }
            end
          end
        end
        render()
        saveNav()
        loadRebuildArches(proj, pkg)
        if filesOpen then
          local checkoutDir = resolveCheckoutDir()
          loadPackageFiles(checkoutDir .. "/" .. proj .. "/" .. pkg, pkg)
        end
        return
      end
    end
  end

  render()
  if clearNav then
    saveNav()
  end

  noctalia.runAsync("osc search --project --maintainer --csv", function(result)
    if result.exitCode == 0 then
      ownedProjects = {}
      for _, line in ipairs(parseLines(result.stdout)) do
        ownedProjects[line] = true
      end
    end
    ownedDone = true
    maybeVerify()
  end)

  if oscUser == nil then
    oscWhoPending = true
    noctalia.runAsync("osc who | cut -d: -f1", function(userResult)
      if userResult.exitCode == 0 then
        oscUser = noctalia.string.trim(userResult.stdout)
      else
        oscUser = ""
        local err = commandError(userResult)
        if err ~= "" then
          errorText = err
        end
      end
      oscWhoPending = false
      maybeVerify()
    end, 15000)
  end
end

maybeVerify = function()
  if not ownedDone then
    return
  end

  if oscWhoPending then
    return
  end

  if oscUser == nil then
    finalize()
    return
  end

  if oscUser == "" then
    finalize()
    return
  end

  local url = "/search/package_id?match=person/@userid='" .. oscUser .. "' and person/@role='maintainer'"
  noctalia.runAsync("osc api " .. shellQuote(url), function(verifyResult)
    if verifyResult.exitCode == 0 then
      maintainerMap = {}
      for line in tostring(verifyResult.stdout):gmatch("[^\n]+") do
        local project, name = line:match("<package project='([^']*)' name='([^']*)'")
        if project and name then
          if not maintainerMap[project] then
            maintainerMap[project] = {}
          end
          table.insert(maintainerMap[project], name)
        end
      end
    end
    finalize()
  end, 30000)
end

function render()
	local body = {}

	if not noctalia.commandExists("osc") then
		body = {
			ui.glyph({ name = "alert-triangle", color = "error", size = 32 }),
			ui.label({ text = noctalia.tr("panel.osc_missing"), fontWeight = "bold", color = "error" }),
			ui.label({ text = noctalia.tr("panel.osc_missing_hint"), color = "on_surface_variant" }),
		}
	elseif not noctalia.fileExists(OSC_CONFIG) then
		body = {
			ui.glyph({ name = "buildings", color = "primary", size = 32 }),
			ui.label({ text = noctalia.tr("panel.osc_not_configured"), fontWeight = "bold" }),
			ui.label({ text = noctalia.tr("panel.osc_not_configured_hint"), color = "on_surface_variant" }),
			ui.button({ text = noctalia.tr("panel.configure_oscrc"), glyph = "terminal", onClick = configureOsc }),
		}
  elseif projectsLoading and #projects == 0 then
    body = {
      ui.glyph({ name = "loader", color = "primary", size = 28 }),
      ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant" }),
    }
	elseif errorText ~= "" and #projects == 0 then
		body = {
			ui.glyph({ name = "alert-circle", color = "error", size = 32 }),
			ui.label({ text = noctalia.tr("panel.error"), fontWeight = "bold", color = "error" }),
			ui.label({ text = errorText, color = "on_surface_variant", wrap = true }),
			ui.button({
				text = noctalia.tr("panel.retry"),
				glyph = "refresh",
				variant = "default",
				onClick = function()
					if currentBusy() == nil then
						loadProjects(true)
					end
				end,
			}),
		}
	elseif selectedPackage then
		local checkoutDir = resolveCheckoutDir()
		local checkedOut = noctalia.fileExists(checkoutDir .. "/" .. selectedProject .. "/" .. selectedPackage)

		local headerChildren = {
			ui.button({
				glyph = "arrow-left",
				variant = "ghost",
				onClick = function()
					selectedPackage = nil
					resetPackageView()
					render()
					saveNav()
				end,
			}),
				ui.glyph({ name = "package", color = checkedOut and "primary" or "on_surface", size = 18 }),
			ui.label({ text = selectedPackage, fontWeight = "bold", flexGrow = 1 }),
		}
		table.insert(
			headerChildren,
			ui.button({
				glyph = "home-filled",
				tooltip = noctalia.tr("panel.my_projects"),
				variant = "default",
				onClick = function()
					if currentBusy() == nil then
						loadProjects(true)
					end
				end,
			})
		)
		table.insert(
			headerChildren,
			ui.button({
				glyph = "external-link",
				tooltip = noctalia.tr("panel.open_in_obs"),
				variant = "default",
				onClick = function()
					if not validName(selectedProject) or not validName(selectedPackage) then
						return
					end
					noctalia.runAsync(
						"xdg-open " .. shellQuote(
							"https://build.opensuse.org/package/show/" .. selectedProject .. "/" .. selectedPackage
						)
					)
				end,
			})
		)
		table.insert(
			headerChildren,
			ui.button({
				glyph = "feather-filled",
				tooltip = noctalia.tr("panel.edit_meta"),
				variant = "default",
				onClick = function()
					editPackageMeta(selectedProject, selectedPackage)
				end,
			})
		)
		if checkedOut then
			table.insert(
				headerChildren,
				ui.button({
					glyph = removeConfirm and "check" or "package-off",
					tooltip = removeConfirm and noctalia.tr("panel.confirm_remove") or noctalia.tr("panel.remove"),
					variant = "destructive",
					onClick = function()
						if removeConfirm then
							removePackageLocal(selectedProject, selectedPackage)
						else
							removeConfirm = true
							render()
						end
					end,
				})
			)
		end
		table.insert(
			body,
			ui.row({ align = "center", gap = 8, paddingV = 4 }, headerChildren)
		)


		if not checkedOut then
			local checkingOut = isBusy("checkout", selectedProject, selectedPackage)
			local remoteBusy = isBusy("service_remote", selectedProject, selectedPackage)
			table.insert(
				body,
				ui.button({
					key = "checkout-btn",
					text = noctalia.tr("panel.checkout"),
					glyph = checkingOut and "loader" or "package-import",
					variant = "default",
					onClick = function()
						if not checkingOut then
							checkoutPackage(selectedProject, selectedPackage)
						end
					end,
				})
			)
			table.insert(
				body,
				ui.button({
					key = "checkout-remote-run-btn",
					text = noctalia.tr("panel.service_remote_run"),
					glyph = remoteBusy and "loader" or "run",
					variant = "default",
					onClick = function()
						if not remoteBusy then
							oscServiceRemoteRun(selectedProject, selectedPackage)
						end
					end,
				})
			)
		end

		if checkedOut then
			local pkgDir = checkoutDir .. "/" .. selectedProject .. "/" .. selectedPackage
			local editable = {}
			if noctalia.fileExists(pkgDir .. "/_service") then
				table.insert(editable, "_service")
			end
			if noctalia.fileExists(pkgDir .. "/" .. selectedPackage .. ".spec") then
				table.insert(editable, selectedPackage .. ".spec")
			end
			if noctalia.fileExists(pkgDir .. "/" .. selectedPackage .. ".changes") then
				table.insert(editable, selectedPackage .. ".changes")
			end

			table.insert(
				body,
				ui.row({ key = "editfiles-row", align = "center", gap = 8 }, {
					ui.glyph({
						name = editFilesOpen and "arrow-badge-down-filled" or "arrow-badge-right-filled",
						size = 16,
						color = "on_surface",
					}),
					ui.button({
						text = noctalia.tr("panel.edit_files"),
						glyph = "ballpen-filled",
						variant = "default",
						flexGrow = 1,
						align = "left",
						onClick = function()
							editFilesOpen = not editFilesOpen
							editFilesOpenMap[selectedProject .. "/" .. selectedPackage] = editFilesOpen
							render()
							saveNav()
						end,
					}),
				})
			)
			if editFilesOpen then
				if #editable == 0 then
					table.insert(body, ui.label({ text = noctalia.tr("panel.no_editable"), color = "on_surface_variant" }))
				else
					for _, file in ipairs(editable) do
						if file:match("%.changes$") then
							local editBtn = ui.button({
								text = noctalia.tr("panel.edit_changes", { name = selectedPackage }),
								glyph = "ballpen-filled",
								variant = "default",
								flexGrow = 1,
								onClick = function()
									editFilePlain(pkgDir .. "/" .. file)
								end,
							})
							local updateBtn = ui.button({
								text = noctalia.tr("panel.update_changes", { name = selectedPackage }),
								glyph = "square-rounded-chevron-up",
								variant = "default",
								flexGrow = 1,
								onClick = function()
									noctalia.runInTerminal("cd " .. shellQuote(pkgDir) .. " && osc vc")
								end,
							})
							if changesButtonsFit(selectedPackage) then
								table.insert(
									body,
									ui.row({ key = "changes-row-" .. file, align = "center", gap = 8 }, {
										editBtn, updateBtn,
									})
								)
							else
								table.insert(
									body,
									ui.column({ key = "changes-col-" .. file, gap = 8, align = "stretch" }, {
										editBtn, updateBtn,
									})
							)
						end
					else
							table.insert(
								body,
								ui.button({
									text = file,
									glyph = "file-text",
									variant = "default",
									onClick = function()
										editFile(pkgDir .. "/" .. file, pkgDir, selectedPackage, file)
									end,
								})
							)
						end
					end
				end
			end

			table.insert(
				body,
				ui.row({ key = "files-row", align = "center", gap = 8 }, {
				ui.glyph({
					name = filesOpen and "arrow-badge-down-filled" or "arrow-badge-right-filled",
					size = 16,
					color = "on_surface",
				}),
				ui.button({
					text = noctalia.tr("panel.files"),
					glyph = filesOpen and "folder-open" or "folder",
					variant = "default",
					flexGrow = 1,
					align = "left",
						onClick = function()
							filesOpen = not filesOpen
							filesOpenMap[selectedProject .. "/" .. selectedPackage] = filesOpen
							if filesOpen and #packageFiles == 0 then
								loadPackageFiles(pkgDir, selectedPackage)
							end
							render()
							saveNav()
						end,
					}),
				})
			)
			if filesOpen then
				if #packageFiles == 0 then
					table.insert(body, ui.label({ text = noctalia.tr("panel.no_files"), color = "on_surface_variant" }))
				else
					for _, f in ipairs(packageFiles) do
						table.insert(
							body,
							ui.row({ key = "file-row-" .. f, align = "center", gap = 8 }, {
								ui.glyph({ name = "file-text", color = "on_surface_variant", size = 15 }),
								ui.label({ text = f, color = "on_surface", flexGrow = 1, maxLines = 1 }),
								ui.button({
									glyph = (removeFileConfirm and removeFileTarget == f) and "check" or "trash",
									tooltip = (removeFileConfirm and removeFileTarget == f) and noctalia.tr("panel.confirm_remove") or noctalia.tr("panel.remove_file"),
									variant = (removeFileConfirm and removeFileTarget == f) and "destructive" or "ghost",
									onClick = function()
										if removeFileConfirm and removeFileTarget == f then
											removeFileLocal(pkgDir .. "/" .. f, pkgDir, selectedPackage)
											removeFileConfirm = false
											removeFileTarget = nil
										else
											removeFileConfirm = true
											removeFileTarget = f
										end
										render()
									end,
								}),
							})
						)
					end
				end
			end

			table.insert(
				body,
				ui.row({ align = "center", gap = 8 }, {
					ui.button({
						key = "addremove-btn",
						text = noctalia.tr("panel.add_remove"),
						glyph = "plus-minus",
						variant = "default",
						flexGrow = 1,
						onClick = function()
							if not isBusy("addremove", selectedProject, selectedPackage) then
								oscAddRemove(pkgDir)
							end
						end,
					}),
					ui.button({
						key = "update-btn",
						text = noctalia.tr("panel.update_dir"),
						glyph = "cloud-download",
						variant = "default",
						flexGrow = 1,
						onClick = function()
							if not isBusy("update", selectedProject, selectedPackage) then
								oscUpdate(pkgDir)
							end
						end,
					}),
				})
			)
			table.insert(
				body,
				ui.row({ align = "center", gap = 8 }, {
					ui.button({
						key = "service-all-btn",
						text = runAllConfirm and noctalia.tr("panel.confirm") or noctalia.tr("panel.service_run_all"),
						glyph = runAllConfirm and "check" or "run",
						tooltip = runAllConfirm and noctalia.tr("panel.confirm_run_all") or noctalia.tr("panel.service_run_all"),
						variant = runAllConfirm and "secondary" or "default",
						flexGrow = 1,
						onClick = function()
							if isBusy("service_all", selectedProject, selectedPackage) then
								return
							end
							if runAllConfirm then
								oscServiceRunAll(pkgDir)
								runAllConfirm = false
							else
								runAllConfirm = true
							end
							render()
						end,
					}),
					ui.button({
						key = "service-local-btn",
						text = noctalia.tr("panel.service_local_run"),
						glyph = "run",
						variant = "default",
						flexGrow = 1,
						onClick = function()
							if not isBusy("service_local", selectedProject, selectedPackage) then
								oscServiceLocalRun(pkgDir)
							end
						end,
					}),
				})
			)
			table.insert(
				body,
				ui.row({ align = "center", gap = 8 }, {
					ui.button({
						key = "service-remote-btn",
						text = noctalia.tr("panel.service_remote_run"),
						glyph = "run",
						variant = "default",
						flexGrow = 1,
						onClick = function()
							if not isBusy("service_remote", selectedProject, selectedPackage) then
								oscServiceRemoteRun(selectedProject, selectedPackage)
							end
						end,
					}),
					ui.button({
						key = "service-manual-btn",
						text = noctalia.tr("panel.service_run"),
						glyph = "run",
						variant = "default",
						flexGrow = 1,
						onClick = function()
							if not isBusy("service_manual", selectedProject, selectedPackage) then
								oscServiceRun(pkgDir)
							end
						end,
					}),
				})
			)
			local committing = isBusy("commit", selectedProject, selectedPackage)
			local commitBtn = ui.button({
				key = "commit-btn",
				text = noctalia.tr("panel.commit"),
				glyph = "package-export",
				variant = "default",
				flexGrow = 1,
				onClick = function()
					if not committing then
						oscCommit(pkgDir, selectedProject, selectedPackage)
					end
				end,
			})
			table.insert(
				body,
				ui.row({ key = "commit-logs-row", align = "center", gap = 8 }, {
					ui.button({
						key = "logs-toggle",
						glyph = (logsOpenMap[pkgKey(selectedProject, selectedPackage)] or false) and "chevron-down" or "logs",
						tooltip = noctalia.tr("panel.logs"),
						variant = "default",
						onClick = function()
							local key = pkgKey(selectedProject, selectedPackage)
							local open = not (logsOpenMap[key] or false)
							logsOpenMap[key] = open or nil
							render()
							saveNav()
						end,
					}),
					commitBtn,
				})
			)

			local logsOpen = logsOpenMap[pkgKey(selectedProject, selectedPackage)] or false
			if logsOpen then
				local logLines = {}
				local busy = currentBusy()
				if busy ~= nil then
					table.insert(
						logLines,
						ui.row({ align = "center", gap = 8 }, {
							ui.glyph({ name = "loader", color = "primary", size = 14 }),
							ui.label({ text = busy.status ~= "" and busy.status or noctalia.tr("panel.loading"), color = "on_surface_variant" }),
						})
					)
				elseif errorText ~= "" then
					table.insert(logLines, ui.label({ text = errorText, color = "error", wrap = true }))
				elseif commandLog ~= "" then
					table.insert(logLines, ui.label({ text = commandLog, color = "on_surface_variant", wrap = true }))
				else
					table.insert(logLines, ui.label({ text = noctalia.tr("panel.no_logs"), color = "on_surface_variant", wrap = true }))
				end
				table.insert(
					body,
					ui.column({ key = "commit-log-card", fill = "surface_variant/0.5", radius = 6, padding = 8, gap = 4 }, logLines)
				)
			end
		end

		table.insert(body, ui.separator({ key = "logs-rebuild-sep", thickness = 1, spacing = 6 }))
		table.insert(
			body,
			ui.row({ key = "rebuild-header", align = "center", gap = 8 }, {
				ui.glyph({ name = "package", color = "primary", size = 16 }),
				ui.label({ text = noctalia.tr("panel.rebuild_package"), fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
			})
		)

		local repoOptions = { "All" }
		for _, repo in ipairs(rebuildRepos) do
			table.insert(repoOptions, repo)
		end
		local selectedRepo = rebuildRepos[rebuildRepoIndex]
		local archOptions = { "All" }
		if selectedRepo then
			for _, arch in ipairs(repoMap[selectedRepo] or {}) do
				table.insert(archOptions, arch)
			end
		else
			local seen = {}
			for _, archs in pairs(repoMap) do
				for _, arch in ipairs(archs) do
					if not seen[arch] then
						seen[arch] = true
						table.insert(archOptions, arch)
					end
				end
			end
			table.sort(archOptions, function(a, b)
				return a < b
			end)
		end

		if not rebuildLoaded then
			table.insert(
				body,
				ui.row({ align = "center", gap = 8 }, {
					ui.label({ text = noctalia.tr("panel.loading"), color = "on_surface_variant", flexGrow = 1 }),
					ui.button({
						glyph = "refresh",
						tooltip = noctalia.tr("panel.rebuild"),
						variant = "default",
						onClick = function()
							loadRebuildArches(selectedProject, selectedPackage)
						end,
					}),
				})
			)
		else
			table.insert(
				body,
				ui.row({ key = "rebuild-controls", align = "center", gap = 8 }, {
					ui.column({ gap = 8, align = "stretch", flexGrow = 1 }, {
						ui.row({ align = "center", gap = 6 }, {
							ui.label({ key = "rebuild-repo-label", text = noctalia.tr("panel.repo"), fontSize = 12, color = "on_surface_variant" }),
							ui.select({
								key = "rebuild-repo-" .. tostring(rebuildArchIndex),
								options = repoOptions,
								selectedIndex = rebuildRepoIndex,
								flexGrow = 1,
								onChange = function(index)
									rebuildRepoIndex = tonumber(index)
									savedRebuildRepo = repoOptions[rebuildRepoIndex + 1]
									rebuildArchIndex = 0
									savedRebuildArch = nil
									render()
								end,
							}),
						}),
						ui.row({ align = "center", gap = 6 }, {
							ui.label({ key = "rebuild-arch-label", text = noctalia.tr("panel.arch"), fontSize = 12, color = "on_surface_variant" }),
							ui.select({
								key = "rebuild-arch-" .. tostring(rebuildRepoIndex),
								options = archOptions,
								selectedIndex = rebuildArchIndex,
								flexGrow = 1,
								onChange = function(index)
									rebuildArchIndex = tonumber(index)
									savedRebuildArch = archOptions[rebuildArchIndex + 1]
									render()
								end,
							}),
						}),
					}),
					ui.button({
						key = "rebuild-btn",
						glyph = rebuildConfirm and "check" or "analyze-filled",
						tooltip = rebuildConfirm and noctalia.tr("panel.confirm_rebuild") or noctalia.tr("panel.rebuild"),
						variant = rebuildConfirm and "secondary" or "default",
						onClick = function()
							if isBusy("rebuild", selectedProject, selectedPackage) then
								return
							end
							if rebuildConfirm then
								local repo = repoOptions[rebuildRepoIndex + 1]
								local arch = archOptions[rebuildArchIndex + 1]
								rebuildPackage(selectedProject, selectedPackage, repo, arch)
								rebuildConfirm = false
							else
								rebuildConfirm = true
							end
							render()
						end,
					}),
				})
			)
		end

		table.insert(body, ui.separator({ key = "logs-status-sep", thickness = 1, spacing = 2 }))

		local statusChildren = {
			ui.row({ align = "center", gap = 8 }, {
				ui.glyph({ name = "activity", color = "primary", size = 16 }),
				ui.label({ text = noctalia.tr("panel.build_status"), fontWeight = "bold", fontSize = 15, flexGrow = 1 }),
				ui.button({
					glyph = "refresh",
					tooltip = noctalia.tr("panel.status_refresh"),
					variant = "ghost",
					controlSize = "sm",
					onClick = function()
						loadRebuildArches(selectedProject, selectedPackage)
					end,
				}),
			}),
		}
		if not rebuildLoaded then
			table.insert(statusChildren, ui.row({ align = "center", gap = 8, paddingV = 2 }, {
				ui.glyph({ name = "loader", color = "primary", size = 14 }),
				ui.label({ text = noctalia.tr("panel.status_loading"), color = "on_surface_variant" }),
			}))
		else
			local hadResults = false
			for _, repo in ipairs(rebuildRepos) do
				local archs = repoMap[repo] or {}
				if #archs > 0 then
					hadResults = true
					table.insert(
						statusChildren,
						ui.label({ text = repo, fontWeight = "bold", fontSize = 14, color = "on_surface" })
					)
					for _, arch in ipairs(archs) do
						local status = statusMap[repo] and statusMap[repo][arch] or nil
						local glyph, color, label = statusPresentation(status)
						table.insert(
							statusChildren,
							ui.row({ align = "center", gap = 8, paddingL = 12 }, {
								ui.glyph({ name = glyph, color = color, size = 14 }),
								ui.label({ text = arch, fontSize = 13, color = "on_surface", flexGrow = 1 }),
								ui.label({ text = label, fontSize = 13, color = color }),
							})
						)
					end
				end
			end
			if not hadResults then
				table.insert(statusChildren, ui.label({ text = noctalia.tr("panel.no_builds"), color = "on_surface_variant" }))
			end
		end
		table.insert(body, ui.column({ key = "build-status", gap = 4 }, statusChildren))

  elseif selectedProject then
    table.insert(
      body,
      ui.row({ align = "center", gap = 8 }, {
        ui.button({
          glyph = "arrow-left",
          variant = "ghost",
          onClick = function()
            if currentBusy() == nil then
              loadProjects(true)
            end
          end,
        }),
        ui.glyph({ name = "folder-filled", color = "primary", size = 22 }),
        ui.label({ text = selectedProject, fontWeight = "bold", fontSize = 18, flexGrow = 1 }),
        ui.button({
            glyph = "refresh",
            tooltip = noctalia.tr("panel.reload_packages"),
            variant = "default",
            onClick = function()
              if currentBusy() == nil and validName(selectedProject) then
                loadPackages(selectedProject)
              end
            end,
        }),
      })
    )

    if packagesLoading then
      table.insert(body, ui.label({ text = noctalia.tr("panel.loading_packages"), color = "on_surface_variant" }))
    elseif errorText ~= "" then
      table.insert(body, ui.label({ text = errorText, color = "error", wrap = true }))
      table.insert(
        body,
        ui.button({
            text = noctalia.tr("panel.retry"),
            glyph = "refresh",
            variant = "default",
            onClick = function()
              if currentBusy() == nil and validName(selectedProject) then
                loadPackages(selectedProject)
              end
            end,
        })
      )
    else
      table.insert(
        body,
        ui.row({ align = "center", gap = 8 }, {
          ui.input({
            key = "packageFilter",
            placeholder = noctalia.tr("panel.search_packages"),
            value = packageFilter,
            flexGrow = 1,
            onChange = function(value)
              packageFilter = value
              render()
            end,
          }),
          ui.button({
            key = "pkg-sort-btn",
            glyph = if sortAsc then "sort-ascending" else "sort-descending",
            tooltip = if sortAsc then "A-Z" else "Z-A",
            variant = "default",
            onClick = function()
              sortAsc = not sortAsc
              render()
            end,
          }),
        })
      )
      local filtered = filterList(packages, packageFilter, sortAsc)
      if #filtered == 0 then
        table.insert(body, ui.label({ text = noctalia.tr("panel.no_packages"), color = "on_surface_variant" }))
      else
        local checkoutDir = resolveCheckoutDir()
        for _, name in ipairs(filtered) do
          local checkedOut = noctalia.fileExists(checkoutDir .. "/" .. selectedProject .. "/" .. name)
          table.insert(
            body,
            ui.row({ key = "pkgrow-" .. name, align = "center", gap = 8 }, {
              ui.glyph({ name = "package", size = 16, color = checkedOut and "primary" or "on_surface" }),
              ui.button({
                key = "pkgbtn-" .. name,
                text = name,
                variant = "default",
                flexGrow = 1,
                align = "left",
                onClick = function()
                  resetPackageView()
                  editFilesOpen = editFilesOpenMap[selectedProject .. "/" .. name] or false
                  filesOpen = filesOpenMap[selectedProject .. "/" .. name] or false
                  if filesOpen and #packageFiles == 0 then
                    loadPackageFiles(checkoutDir .. "/" .. selectedProject .. "/" .. name, name)
                  end
                  local entry = currentLog()
                  errorText = entry.error
                  commandLog = entry.output
                  selectedPackage = name
                  render()
                  saveNav()
                  loadRebuildArches(selectedProject, name)
                end,
              }),
            })
          )
        end
      end
    end
	else
		table.insert(
			body,
			ui.row({ align = "center", gap = 8 }, {
				ui.glyph({ name = "buildings", color = "primary", size = 22 }),
				ui.label({ text = noctalia.tr("panel.my_projects"), fontWeight = "bold", fontSize = 18, flexGrow = 1 }),
				ui.button({
					glyph = "refresh",
					tooltip = noctalia.tr("panel.reload_projects"),
					variant = "default",
					onClick = function()
						if currentBusy() == nil then
							loadProjects(true)
						end
					end,
				}),
			})
		)

		table.insert(
			body,
			ui.row({ align = "center", gap = 8 }, {
				ui.input({
					key = "projectFilter",
					placeholder = noctalia.tr("panel.search_projects"),
					value = projectFilter,
					flexGrow = 1,
					onChange = function(value)
						projectFilter = value
						render()
					end,
				}),
				ui.button({
					key = "proj-sort-btn",
					glyph = sortAsc and "sort-ascending" or "sort-descending",
					tooltip = sortAsc and "A-Z" or "Z-A",
					variant = "default",
					onClick = function()
						sortAsc = not sortAsc
						render()
					end,
				}),
			})
		)

		if #projects == 0 then
			table.insert(body, ui.label({ text = noctalia.tr("panel.no_projects"), color = "on_surface_variant" }))
		else
			local filtered = filterList(projects, projectFilter, sortAsc)
			if #filtered == 0 then
				table.insert(body, ui.label({ text = noctalia.tr("panel.no_projects"), color = "on_surface_variant" }))
			else
			for _, name in ipairs(filtered) do
				table.insert(
					body,
					ui.row({ align = "center", gap = 8 }, {
						ui.button({
							text = name,
							glyph = "folder-filled",
							variant = "default",
							flexGrow = 1,
							align = "left",
							onClick = function()
								if currentBusy() == nil and validName(name) then
									loadPackages(name)
								end
							end,
						}),
						ui.button({
							glyph = "external-link",
							variant = "default",
							tooltip = noctalia.tr("panel.open_in_obs"),
							onClick = function()
								if not validName(name) then
									return
								end
								noctalia.runAsync(
									"xdg-open " .. shellQuote("https://build.opensuse.org/project/show/" .. name)
								)
							end,
						}),
						ui.button({
							glyph = "feather-filled",
							variant = "default",
							tooltip = noctalia.tr("panel.edit_project_meta"),
							onClick = function()
								editProjectMeta(name)
							end,
						}),
					})
				)
			end
			end
		end
	end

	panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
		ui.scroll({ key = "scroll-" .. tostring(selectedProject) .. "-" .. tostring(selectedPackage), flexGrow = 1 }, {
			ui.column({ gap = 10, paddingV = 6, paddingH = 12, align = "stretch" }, body),
		}),
	}))
end

function onOpen()
	if noctalia.commandExists("osc") and noctalia.fileExists(OSC_CONFIG) then
		restoreProject, restorePackage, restoreFilesOpen, restoreLogsByPkg,
			restoreLogsOpenMap, restoreBusyByPkg =
			readNav()
		loadProjects()
	else
		render()
	end
end

function onClose()
	editFilesOpen = false
	editFilesOpenMap = {}
	filesOpen = false
	filesOpenMap = {}
	saveNav()
end
