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
local filesOpen = false
local packageFiles = {}
local rebuildArchIndex = 0
local rebuildRepos = {}
local rebuildRepoIndex = 0
local rebuildConfirm = false
local repoMap = {}
local savedRebuildRepo = nil
local savedRebuildArch = nil
local rebuildLoaded = false
local maintainerMap = {}
local ownedProjects = {}
local projectsLoading = false
local packagesLoading = false
local errorText = ""
local pendingProject = nil
local removeConfirm = false
local restoreProject = nil
local restorePackage = nil
local saveCache
local saveNav
local maybeVerify

local ownedDone = false
local oscUser = nil

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
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

local function resolveCheckoutDir()
	local checkoutDir = noctalia.getConfig("checkout_dir")
	if type(checkoutDir) ~= "string" or checkoutDir:match("^%s*$") then
		checkoutDir = "~/OBS"
	end
	return noctalia.expandPath(checkoutDir)
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
	local filtered = {}
	if filter == "" then
		for _, name in ipairs(list) do
			table.insert(filtered, name)
		end
	else
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
	noctalia.runInTerminal(
		"cd " .. shellQuote(resolveCheckoutDir()) .. " && osc co " .. shellQuote(project) .. " " .. shellQuote(pkg)
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
	noctalia.runInTerminal(cmd)
end

local function loadPackageFiles(pkgDir, pkg)
	noctalia.runAsync(
		"find " .. shellQuote(pkgDir) .. " -maxdepth 1 -not -name '.*' -printf '%f\\n'",
		function(result)
			local list = {}
			if result.exitCode == 0 then
				for _, f in ipairs(parseLines(result.stdout)) do
					if f ~= pkg and f ~= ".osc" then
						table.insert(list, f)
					end
				end
			end
			table.sort(list)
			packageFiles = list
			render()
		end,
		5000
	)
end

local function loadRebuildArches(project, pkg)
	rebuildLoaded = false
	noctalia.runAsync("osc results " .. shellQuote(project) .. " " .. shellQuote(pkg), function(result)
		local map = {}
		if result.exitCode == 0 then
			for line in tostring(result.stdout):gmatch("[^\n]+") do
				line = noctalia.string.trim(line)
				local repo, arch, _, status = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
				if repo ~= nil and arch ~= nil and status ~= "disabled" then
					if not map[repo] then
						map[repo] = {}
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

local function removeFileLocal(path, pkgDir, pkg)
	noctalia.runAsync("rm " .. shellQuote(path), function(result)
		if result.exitCode == 0 then
			loadPackageFiles(pkgDir, pkg)
		else
			errorText = noctalia.string.trim(result.stderr ~= "" and result.stderr or result.stdout)
			render()
		end
	end, 15000)
end

local function editFile(path, pkgDir, pkg, filename)
	if not validName(pkg) then
		return
	end
	if filename:match("%.changes$") then
		noctalia.runInTerminal("cd " .. shellQuote(pkgDir) .. " && osc vc")
	else
		noctalia.runInTerminal("${EDITOR:-nano} " .. shellQuote(path))
	end
end

local function oscAddRemove(pkgDir)
	noctalia.runInTerminal("cd " .. shellQuote(pkgDir) .. " && osc ar")
end

local function oscCommit(pkgDir)
	noctalia.runInTerminal("cd " .. shellQuote(pkgDir) .. " && osc ci")
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
			errorText = noctalia.string.trim(result.stderr ~= "" and result.stderr or result.stdout)
			render()
		end
	end, 15000)
	selectedPackage = nil
	removeConfirm = false
	render()
	saveNav()
end

local function loadPackages(project)
  selectedProject = project
  selectedPackage = nil
  packageFilter = ""
  editFilesOpen = false
  filesOpen = false
  packageFiles = {}
  removeConfirm = false
  rebuildConfirm = false
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
        errorText = noctalia.string.trim(result.stderr ~= "" and result.stderr or result.stdout)
      end
      render()
    end, 15000)
    saveNav()
    return
  end

  packagesLoading = false
  errorText = ""
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
	}))
end
local function readNav()
	local path = navPath()
	if not path or not noctalia.fileExists(path) then
		return nil, nil
	end
	local data, _ = noctalia.readFile(path)
	if not data then
		return nil, nil
	end
	local parsed, _ = noctalia.json.decode(data)
	if type(parsed) ~= "table" then
		return nil, nil
	end
	return parsed.project, parsed.package
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
  errorText = ""
  ownedDone = false

  if restoreProject then
    local proj = restoreProject
    local pkg = restorePackage
    restoreProject = nil
    restorePackage = nil
    if proj and (maintainerMap[proj] or ownedProjects[proj]) then
      projectsLoading = false
      loadPackages(proj)
      if pkg then
        selectedPackage = pkg
        render()
        saveNav()
        loadRebuildArches(proj, pkg)
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
    noctalia.runAsync("osc who | cut -d: -f1", function(userResult)
      if userResult.exitCode == 0 then
        oscUser = noctalia.string.trim(userResult.stdout)
      end
      maybeVerify()
    end, 15000)
  end
end

maybeVerify = function()
  if not ownedDone then
    return
  end

  if oscUser == nil then
    noctalia.runAsync("osc who | cut -d: -f1", function(userResult)
      if userResult.exitCode == 0 then
        oscUser = noctalia.string.trim(userResult.stdout)
      end
      maybeVerify()
    end, 15000)
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
					loadProjects(true)
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
					editFilesOpen = false
					filesOpen = false
					packageFiles = {}
					rebuildArchIndex = 0
					rebuildRepos = {}
					rebuildRepoIndex = 0
					repoMap = {}
					savedRebuildRepo = nil
					savedRebuildArch = nil
					rebuildLoaded = false
					rebuildConfirm = false
					removeConfirm = false
					render()
					saveNav()
				end,
			}),
				ui.glyph({ name = "package", color = checkedOut and "primary" or "on_surface", size = 18 }),
			ui.label({ text = selectedPackage, fontWeight = "bold", flexGrow = 1 }),
		}
		if checkedOut then
			table.insert(
				headerChildren,
				ui.button({
					glyph = removeConfirm and "check" or "trash",
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
			ui.row({ align = "center", gap = 8 }, headerChildren)
		)

		if not checkedOut then
			table.insert(
				body,
				ui.button({
					text = noctalia.tr("panel.checkout"),
					glyph = "download",
					variant = "default",
					onClick = function()
						checkoutPackage(selectedProject, selectedPackage)
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
							render()
						end,
					}),
				})
			)
			if editFilesOpen then
				if #editable == 0 then
					table.insert(body, ui.label({ text = noctalia.tr("panel.no_editable"), color = "on_surface_variant" }))
				else
					for _, file in ipairs(editable) do
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
						glyph = "folder",
						variant = "default",
						flexGrow = 1,
						align = "left",
						onClick = function()
							filesOpen = not filesOpen
							if filesOpen and #packageFiles == 0 then
								loadPackageFiles(pkgDir, selectedPackage)
							end
							render()
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
								ui.label({ text = f, color = "on_surface", flexGrow = 1 }),
								ui.button({
									glyph = "trash",
									tooltip = noctalia.tr("panel.remove_file"),
									variant = "ghost",
									onClick = function()
										removeFileLocal(pkgDir .. "/" .. f, pkgDir, selectedPackage)
									end,
								}),
							})
						)
					end
				end

				table.insert(
					body,
					ui.row({ align = "center", gap = 8 }, {
						ui.button({
							text = noctalia.tr("panel.add_remove"),
							glyph = "plus-minus",
							variant = "default",
							flexGrow = 1,
							onClick = function()
								oscAddRemove(pkgDir)
							end,
						}),
						ui.button({
							text = noctalia.tr("panel.commit"),
							glyph = "upload",
							variant = "default",
							flexGrow = 1,
							onClick = function()
								oscCommit(pkgDir)
							end,
						}),
					})
				)
			end
		end

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
				ui.row({ align = "center", gap = 8 }, {
					ui.select({
						key = "rebuild-repo-" .. #repoOptions,
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
					ui.select({
						key = "rebuild-arch-" .. tostring(selectedRepo) .. "-" .. #archOptions,
						options = archOptions,
						selectedIndex = rebuildArchIndex,
						flexGrow = 1,
						onChange = function(index)
							rebuildArchIndex = tonumber(index)
							savedRebuildArch = archOptions[rebuildArchIndex + 1]
							render()
						end,
					}),
					ui.button({
						glyph = rebuildConfirm and "check" or "refresh",
						tooltip = rebuildConfirm and noctalia.tr("panel.confirm_rebuild") or noctalia.tr("panel.rebuild"),
						variant = rebuildConfirm and "secondary" or "default",
						onClick = function()
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

		table.insert(
			body,
			ui.button({
				text = noctalia.tr("panel.edit_meta"),
				glyph = "feather-filled",
				variant = "default",
				onClick = function()
					editPackageMeta(selectedProject, selectedPackage)
				end,
			})
		)
  elseif selectedProject then
    table.insert(
      body,
      ui.row({ align = "center", gap = 8 }, {
        ui.button({
          glyph = "arrow-left",
          variant = "ghost",
          onClick = function()
            loadProjects(true)
          end,
        }),
        ui.glyph({ name = "folder-filled", color = "primary", size = 22 }),
        ui.label({ text = selectedProject, fontWeight = "bold", fontSize = 18, flexGrow = 1 }),
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
            loadPackages(selectedProject)
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
                  selectedPackage = name
                  savedRebuildRepo = nil
                  savedRebuildArch = nil
                  rebuildLoaded = false
                  rebuildConfirm = false
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
					variant = "ghost",
					onClick = function()
						loadProjects(true)
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
								loadPackages(name)
							end,
						}),
						ui.button({
							glyph = "feather-filled",
							variant = "ghost",
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

	panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
		ui.scroll({ flexGrow = 1 }, {
			ui.column({ gap = 10, paddingV = 6, paddingH = 12, align = "stretch" }, body),
		}),
	}))
end

function onOpen()
	if noctalia.commandExists("osc") and noctalia.fileExists(OSC_CONFIG) then
		restoreProject, restorePackage = readNav()
		loadProjects()
	else
		render()
	end
end
