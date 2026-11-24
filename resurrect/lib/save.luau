--!nonstrict
-- The save: puts this device's setup into the git repository, for restore.sh to bring back.
--
-- Save.run(job, opt) runs inside a coroutine; <job> pauses it while a command runs and when
-- a callback's time is used up:
--   job.run(argv)    a command, waited for; returns its CommandResult
--   job.long(argv)   a command that may take longer than a minute, such as a push; returns
--                    { exitCode, output }
--   job.breathe()    pauses until the next update tick when this tick's time is used up
--   job.wait(ms)     pauses for a while
--   job.emit(line)   one line for the panel, as the service reads them
--   job.stop(code)   ends the save with an exit code: 1 failed, 2 not pushed, 3 a step failed,
--                    4 a secret found, 5 too big
--
-- What the plugin saves of this device goes into devices/<hostname>/, so devices sharing one
-- repository never overwrite each other. With sharing on, what the devices share goes into
-- shared/ instead: the dotfiles, Noctalia's config and settings, and the package and service
-- lists. The save brings in what other devices changed, and this device's folder keeps only
-- what differs. Then the owner's own steps run, and the save is committed and pushed.
--
-- Emits "count <what> <number>" lines; "applied", "removed" and "kept" lines for shared
-- files, and "incoming <version> <path>", "conflict <version> <path>" and "held <version>
-- <path>" with the other devices' version as "<blob>:<mode>", as git names them, or "-" for a
-- removal; "incoming-settings <number>"; "missing" and "left" lines for shared packages and services;
-- "settings applied <number>"; "unapproved <path>" for each step that waits; then "saved" or
-- "unchanged", and "pushed".

local Settings = require("./settings.luau")

local Save = {}

local LIMIT_BYTES = 50 * 1024 * 1024
local FILE_LIMIT = 1024 * 1024
-- Folders inside the dotfiles that hold no settings, by name in lower case.
local SKIP = {
  cache = true, caches = true, cacheddata = true, gpucache = true, ["code cache"] = true,
  logs = true, crashpad = true, ["crash reports"] = true,
}
local CHUNK = 500

-- trim, eachLine and entries take, as <_>, the error a file read returns beside the text.
local function trim(text, _)
  return noctalia.string.trim(text or "")
end

local function eachLine(text, _)
  return (text or ""):gmatch("[^\n]+")
end

local function parentOf(path)
  return path:match("^(.*)/[^/]*$") or "."
end

local function isDir(path)
  local info = noctalia.fileInfo(path)
  return info ~= nil and info.isDir
end

-- Lines of a list kept by hand, without comments and blank lines.
local function entries(text, _)
  local out = {}
  for line in eachLine(text) do
    line = line:gsub("#.*", ""):gsub("%s+$", "")
    if line ~= "" then
      table.insert(out, line)
    end
  end
  return out
end

local function setOf(list)
  local set = {}
  for _, item in ipairs(list) do
    set[item] = true
  end
  return set
end

local function sorted(set)
  local list = {}
  for item in pairs(set) do
    table.insert(list, item)
  end
  table.sort(list)
  return list
end

local function linesText(list)
  return #list > 0 and table.concat(list, "\n") .. "\n" or ""
end

-- Whether <path>, as git ls-tree lists it, is a plain relative path: no control characters,
-- no leading "/" or '"', which git puts around a path it had to quote, and no empty, ".",
-- ".." or ".git" part. Any other path did not come from Resurrect.
local function isPlain(path)
  if path == "" or path:find("%c") or path:find('^[/"]') then
    return false
  end
  for part in (path .. "/"):gmatch("([^/]*)/") do
    if part == "" or part == "." or part == ".." or part:lower() == ".git" then
      return false
    end
  end
  return true
end

function Save.run(job, opt)
  local home = noctalia.expandPath("~")
  local repo = opt.repo
  local remote = opt.remote
  local share = opt.share
  local device = trim(noctalia.readFile("/proc/sys/kernel/hostname"))
  local dir = "devices/" .. device
  local breathe = job.breathe
  Settings.breathe = breathe

  -- Stops the save with the error output of a command.
  local function failed(result, code, message)
    for line in eachLine((result.stderr or "") .. "\n" .. (result.stdout or "")) do
      job.emit(line)
    end
    if message then
      job.emit(message)
    end
    job.stop(code)
  end

  local function git(...)
    return job.run({ "git", "-C", repo, ... })
  end

  local function gitAs(...)
    local user = noctalia.getenv("USER") or "resurrect"
    return job.run({ "git", "-C", repo, "-c", "user.name=" .. user, "-c", "user.email=" .. user .. "@" .. device, ... })
  end

  -- Writes a file in one step, through a temporary file next to it.
  local function replace(path, text)
    noctalia.mkdirAll(parentOf(path))
    local tmp = parentOf(path) .. "/." .. path:match("[^/]*$") .. ".resurrect-tmp"
    local ok = noctalia.writeFile(tmp, text) and noctalia.renameFile(tmp, path)
    if not ok then
      noctalia.removeFile(tmp)
    end
    return ok
  end

  -- Writes a file in the repository, or removes it when <text> is empty.
  local function writeOrRemove(path, text)
    if text == nil or text == "" then
      noctalia.removeFile(path)
    else
      noctalia.mkdirAll(parentOf(path))
      noctalia.writeFile(path, text)
    end
  end

  -- Removes every file under <path>. Folders stay; git does not keep empty ones.
  local function removeTree(path)
    breathe()
    local info = noctalia.fileInfo(path)
    if info == nil then
      return
    elseif not info.isDir then
      noctalia.removeFile(path)
      return
    end
    for _, name in ipairs(noctalia.listDir(path) or {}) do
      removeTree(path .. "/" .. name)
    end
  end

  -- The files under <path>, relative to it.
  local function filesUnder(path, prefix, out)
    out = out or {}
    breathe()
    for _, name in ipairs(noctalia.listDir(path) or {}) do
      breathe()
      local full = path .. "/" .. name
      local relative = (prefix and prefix .. "/" or "") .. name
      if isDir(full) then
        filesUnder(full, relative, out)
      else
        table.insert(out, relative)
      end
    end
    return out
  end

  -- The paths among <paths> that are executable. Links are followed.
  local function executable(paths)
    local found = {}
    for first = 1, #paths, CHUNK do
      local argv = { "find", "-L" }
      for i = first, math.min(first + CHUNK - 1, #paths) do
        table.insert(argv, paths[i])
      end
      for _, word in ipairs({ "-maxdepth", "0", "-type", "f", "-perm", "-u=x" }) do
        table.insert(argv, word)
      end
      for line in eachLine(job.run(argv).stdout) do
        found[line] = true
      end
    end
    return found
  end

  -- Sets the mode of <paths>: 755 for those in <exec>, else 644, as git keeps only that bit.
  local function setModes(paths, exec)
    local groups = { ["755"] = {}, ["644"] = {} }
    for _, path in ipairs(paths) do
      table.insert(groups[exec[path] and "755" or "644"], path)
    end
    for mode, list in pairs(groups) do
      for first = 1, #list, CHUNK do
        local argv = { "chmod", mode, "--" }
        for i = first, math.min(first + CHUNK - 1, #list) do
          table.insert(argv, list[i])
        end
        job.run(argv)
      end
    end
  end

  ---------------------------------------------------------------------------------------
  -- The repository and the other devices' saves.

  if not noctalia.fileExists(repo .. "/.git") and remote ~= "" and #(noctalia.listDir(repo) or {}) == 0 then
    -- A new device starts from the remote's saves, so all devices share one history.
    local listed = job.long({ "git", "ls-remote", "--", remote })
    if listed.exitCode == 0 and trim(listed.output) ~= "" then
      local cloned = job.long({ "git", "clone", "-q", "-c", "core.symlinks=false", "--", remote, repo })
      if cloned.exitCode ~= 0 then
        failed({ stdout = cloned.output }, 2)
      end
    end
  end
  if not noctalia.mkdirAll(repo) then
    job.emit("could not create " .. repo)
    job.stop(1)
  end
  if not noctalia.fileExists(repo .. "/.git") then
    local made = git("init", "-q")
    if made.exitCode ~= 0 then
      failed(made, 1)
    end
  end
  local gitDir = trim(git("rev-parse", "--absolute-git-dir").stdout)

  -- A save never writes a link, so a link where it reads, writes or runs anything came from
  -- elsewhere, such as the remote. git writes links as plain files here, and links already
  -- in those places are removed before a save writes or removes anything, so nothing goes
  -- through one. The rest of the folder is the owner's, and stays as it is.
  git("config", "core.symlinks", "false")
  local tops = { "shared", "devices", "hooks", "packages", "restore.sh", "settings.awk", ".gitleaksignore" }
  local atTop = { "find", repo, "-mindepth", "1", "-maxdepth", "1", "(" }
  for i, name in ipairs(tops) do
    table.move(i == 1 and { "-name", name } or { "-o", "-name", name }, 1, i == 1 and 2 or 3, #atTop + 1, atTop)
  end
  table.move({ ")", "-type", "l", "-delete" }, 1, 4, #atTop + 1, atTop)
  local links = job.run(atTop)
  local inside = { "find" }
  for _, name in ipairs(tops) do
    if isDir(repo .. "/" .. name) then
      table.insert(inside, repo .. "/" .. name)
    end
  end
  if links.exitCode == 0 and #inside > 1 then
    table.move({ "-type", "l", "-delete" }, 1, 3, #inside + 1, inside)
    links = job.run(inside)
  end
  if links.exitCode ~= 0 then
    failed(links, 1, "could not remove the links in " .. repo)
  end
  -- The owner's .gitleaksignore, put aside by a secret check that did not end.
  if noctalia.fileExists(gitDir .. "/resurrect-gitleaksignore") and not noctalia.fileExists(repo .. "/.gitleaksignore") then
    noctalia.renameFile(gitDir .. "/resurrect-gitleaksignore", repo .. "/.gitleaksignore")
  end

  -- The other devices' latest saves: the remote's branch merged with this repository's own,
  -- the remote's side winning where both changed a file.
  local branch = ""
  if remote ~= "" then
    if git("remote", "get-url", "origin").exitCode == 0 then
      git("remote", "set-url", "--", "origin", remote)
    else
      git("remote", "add", "--", "origin", remote)
    end
    branch = trim(git("symbolic-ref", "--short", "HEAD").stdout)
    job.long({ "git", "-C", repo, "fetch", "-q", "origin", branch })
  end
  local function verify(name)
    local result = git("rev-parse", "-q", "--verify", name)
    return result.exitCode == 0 and trim(result.stdout) or nil
  end
  local fetched = remote ~= "" and verify("origin/" .. branch) or nil
  local theirs = nil
  if verify("HEAD") then
    theirs = "HEAD"
    if fetched then
      local tree = (git("merge-tree", "--write-tree", "-X", "theirs", "HEAD", "origin/" .. branch).stdout or ""):match("^(%x+)")
      theirs = tree and git("cat-file", "-e", tree).exitCode == 0 and tree or "origin/" .. branch
    end
  elseif fetched then
    theirs = "origin/" .. branch
  end

  -- A file of <theirs>, or nil.
  local function theirFile(path)
    if theirs == nil then
      return nil
    end
    local result = git("show", theirs .. ":" .. path)
    return result.exitCode == 0 and not result.stdoutTruncated and result.stdout or nil
  end

  -- Puts the other devices' version of folder <path> in place, so this save starts from it.
  local function fromTheirs(path)
    removeTree(repo .. "/" .. path)
    if theirs == nil then
      return
    end
    for file in eachLine(git("-c", "core.quotePath=false", "ls-tree", "-r", "--name-only", theirs, "--", path).stdout) do
      local text = isPlain(file) and theirFile(file)
      if text then
        noctalia.mkdirAll(parentOf(repo .. "/" .. file))
        noctalia.writeFile(repo .. "/" .. file, text)
      end
    end
  end

  noctalia.mkdirAll(repo .. "/" .. dir)

  ---------------------------------------------------------------------------------------
  -- Packages and services.

  -- This device's lists: here[list] holds what was installed or turned on on purpose,
  -- all[list] every package installed, so a dependency never reads as removed. Packages come
  -- by package manager, without the names packages/exclude.txt matches: one regular
  -- expression per line, for the whole name. Services come for the system and the user.
  local here, all, listOrder = {}, {}, {}
  local function output(argv)
    return job.run(argv).stdout or ""
  end
  local function addList(name, text, allText)
    here[name] = {}
    for line in eachLine(text) do
      table.insert(here[name], line)
    end
    all[name] = {}
    for line in eachLine(allText) do
      all[name][line] = true
    end
    table.insert(listOrder, name)
  end
  local function kind(list)
    return (list == "system" or list == "user") and "services" or "packages"
  end

  if opt.packages then
    local patterns = entries(noctalia.readFile(repo .. "/packages/exclude.txt"))
    local work = opt.dataDir .. "/work"
    noctalia.mkdirAll(work)
    noctalia.writeFile(work .. "/exclude", linesText(patterns))
    -- Leaves out the names the exclude patterns match.
    local function kept(text)
      if #patterns == 0 then
        return text
      end
      noctalia.writeFile(work .. "/names", text)
      return output({ "grep", "-vxEf", work .. "/exclude", work .. "/names" })
    end
    if noctalia.commandExists("pacman") then
      local installed = output({ "pacman", "-Qq" })
      addList("pacman", kept(output({ "pacman", "-Qqen" })), installed)
      addList("aur", kept(output({ "pacman", "-Qqem" })), installed)
    end
    if noctalia.commandExists("apt-mark") then
      addList("apt", kept(output({ "apt-mark", "showmanual" })), output({ "dpkg-query", "-W", "-f", "${Package}\n" }))
    end
    if noctalia.commandExists("dnf") then
      addList("dnf", kept(output({ "dnf", "repoquery", "--userinstalled", "--qf", "%{name}\n" })),
        output({ "rpm", "-qa", "--qf", "%{NAME}\n" }))
    end
    if noctalia.commandExists("flatpak") then
      addList("flatpak", kept(output({ "flatpak", "list", "--app", "--columns=application" })),
        output({ "flatpak", "list", "--columns=application" }))
    end
    noctalia.removeFile(work .. "/exclude")
    noctalia.removeFile(work .. "/names")
    local n = 0
    for _, list in ipairs(listOrder) do
      n += #here[list]
    end
    job.emit("count packages " .. n)
  end
  if opt.services and noctalia.commandExists("systemctl") then
    local n = 0
    for _, scope in ipairs({ "system", "user" }) do
      local argv = { "systemctl", "list-unit-files", "--state=enabled", "--no-legend", "--type=service,timer,socket" }
      if scope == "user" then
        table.insert(argv, 2, "--user")
      end
      local units = {}
      for line in eachLine(output(argv)) do
        table.insert(units, line:match("^(%S+)"))
      end
      addList(scope, table.concat(units, "\n"), "")
      n += #units
    end
    job.emit("count services " .. n)
  end

  for _, folder in ipairs({ "packages", "services", "noctalia" }) do
    removeTree(repo .. "/" .. dir .. "/" .. folder)
  end
  if not share then
    -- Without sharing, this device's lists are saved in its own folder.
    for _, list in ipairs(listOrder) do
      local path = repo .. "/" .. dir .. "/" .. kind(list) .. "/" .. list .. ".txt"
      noctalia.mkdirAll(parentOf(path))
      noctalia.writeFile(path, linesText(here[list]))
    end
  else
    -- With sharing on, the devices share one list of each kind. This device's folder keeps
    -- only what differs: exclude.txt, shared names it leaves out, and extra.txt, "<list>
    -- <name>" lines it keeps only here.
    local excludePath = repo .. "/" .. dir .. "/exclude.txt"
    local extraPath = repo .. "/" .. dir .. "/extra.txt"
    -- The panel's Not here, and skip.txt of older versions, add to exclude.txt.
    local excludeText = noctalia.readFile(excludePath) or ""
    local adding = entries(noctalia.readFile(repo .. "/" .. dir .. "/skip.txt"))
    noctalia.removeFile(repo .. "/" .. dir .. "/skip.txt")
    table.move(opt.exclude, 1, #opt.exclude, #adding + 1, adding)
    if #adding > 0 then
      local lines = {}
      for line in eachLine(excludeText) do
        lines[line] = true
      end
      for _, name in ipairs(adding) do
        lines[name] = true
      end
      excludeText = linesText(sorted(lines))
      writeOrRemove(excludePath, excludeText)
    end
    local excluded = setOf(entries(excludeText))
    local extra = {}
    for line in eachLine(noctalia.readFile(extraPath)) do
      extra[line] = true
    end
    for _, item in ipairs(opt.only) do
      extra[item.list .. " " .. item.name] = true
    end
    local again = {}
    for _, item in ipairs(opt.again) do
      again[item.list .. " " .. item.name] = true
    end
    fromTheirs("shared/packages")
    fromTheirs("shared/services")

    -- One list. A name only this device added joins it. A shared name this device had and
    -- removed leaves it. A name another device removed, which this device still has, does
    -- not come back by itself: it stays out until the owner shares it again or keeps it only
    -- here, and the base keeps it, so it still reads as removed elsewhere on the next save.
    for _, list in ipairs(listOrder) do
      breathe()
      local sharedPath = repo .. "/shared/" .. kind(list) .. "/" .. list .. ".txt"
      local basePath = gitDir .. "/resurrect-lists/" .. list .. ".txt"
      local hadPath = gitDir .. "/resurrect-lists/" .. list .. ".had"
      local mine = setOf(here[list])
      local installed = table.clone(all[list])
      for name in pairs(mine) do
        installed[name] = true
      end
      local their = setOf(entries(noctalia.readFile(sharedPath)))
      local base = setOf(entries(noctalia.readFile(basePath)))
      local had = setOf(entries(noctalia.readFile(hadPath)))
      local shared, left = {}, {}
      for name in pairs(their) do
        -- Removed here: this device had it, and it is not installed or turned on any more.
        if not had[name] or installed[name] or excluded[name] then
          shared[name] = true
        end
      end
      for name in pairs(mine) do
        if not their[name] and not extra[list .. " " .. name] then
          if base[name] and not again[list .. " " .. name] then
            left[name] = true
          else
            shared[name] = true
          end
        end
      end
      local newBase = table.clone(shared)
      for name in pairs(left) do
        newBase[name] = true
      end
      local nowHad = {}
      for name in pairs(shared) do
        if installed[name] then
          nowHad[name] = true
        end
      end
      writeOrRemove(sharedPath, linesText(sorted(shared)))
      noctalia.mkdirAll(gitDir .. "/resurrect-lists")
      replace(basePath, linesText(sorted(newBase)))
      replace(hadPath, linesText(sorted(nowHad)))
      -- What waits for the owner. Names this device has, or leaves out, are not missing.
      for _, name in ipairs(sorted(shared)) do
        if not installed[name] and not excluded[name] then
          job.emit("missing " .. list .. " " .. name)
        end
      end
      for _, name in ipairs(sorted(left)) do
        job.emit("left " .. list .. " " .. name)
      end
      -- A name kept only here leaves extra.txt once it is not installed or turned on here.
      for line in pairs(extra) do
        local itsList, name = line:match("^(%S+) (%S+)$")
        if itsList == list and not installed[name] then
          extra[line] = nil
        end
      end
    end
    writeOrRemove(extraPath, linesText(sorted(extra)))
  end

  ---------------------------------------------------------------------------------------
  -- Choosing the dotfiles.

  -- The files a save takes from <roots>, full paths under the home folder, as
  -- { relative path -> content } and the sorted relative paths. A file named itself is always
  -- taken. Inside a folder, these are left out: nested git folders; caches, logs and crash
  -- reports; the data of browsers and Electron apps, which is a folder with a "Local State"
  -- or "profiles.ini" file; binary files; files over 1 MB; and sockets, pipes and devices,
  -- which hold nothing to save and which reading could block on. Every path in <leaveOut> is
  -- left out with all it holds. Links are followed. A file or folder it cannot read stops the
  -- save, so it never reads as removed; so does a total over 50 MB.
  local function pick(roots, leaveOut)
    local files, errors, total = {}, {}, 0
    local lefts = {}
    for _, left in ipairs(leaveOut) do
      table.insert(lefts, (left:gsub("/$", "")))
    end
    local function leftOut(path)
      for _, left in ipairs(lefts) do
        if path == left or path:sub(1, #left + 1) == left .. "/" then
          return true
        end
      end
      return false
    end
    local function take(path, content)
      local relative = path:sub(#home + 2)
      if files[relative] == nil then
        files[relative] = content
        total += #content
      end
    end
    -- Reads the file at <path>, of <size> bytes, into the save; a binary one only when it is
    -- <named>. Sockets, pipes and devices have no size, so a file of none is read only when
    -- find says it is a regular file.
    local function read(path, size, named)
      if size == 0 then
        if trim(job.run({ "find", "-L", path, "-maxdepth", "0", "-type", "f" }).stdout) == path then
          take(path, "")
        end
        return
      end
      local content = noctalia.readFile(path)
      if content == nil then
        table.insert(errors, path)
      elseif named or not content:find("\0", 1, true) then
        take(path, content)
      end
    end
    local function walk(folder, depth)
      breathe()
      local names = noctalia.listDir(folder)
      if names == nil or depth > 40 then
        table.insert(errors, folder)
        return
      end
      for _, name in ipairs(names) do
        breathe()
        local full = folder .. "/" .. name
        local info = noctalia.fileInfo(full)
        if info == nil or leftOut(full) then
          continue
        elseif info.isDir then
          if name ~= ".git" and not SKIP[name:lower()] and not noctalia.fileExists(full .. "/Local State")
            and not noctalia.fileExists(full .. "/profiles.ini") then
            walk(full, depth + 1)
          end
        elseif info.size <= FILE_LIMIT then
          read(full, info.size)
        end
      end
    end
    for _, root in ipairs(roots) do
      root = root:gsub("/$", "")
      if root:sub(1, #home + 1) == home .. "/" and not leftOut(root) then
        if isDir(root) then
          walk(root, 0)
        else
          local info = noctalia.fileInfo(root)
          if info then
            read(root, info.size, true)
          end
        end
      end
    end
    if #errors > 0 then
      for i = 1, math.min(3, #errors) do
        job.emit("could not read: " .. errors[i])
      end
      job.stop(1)
    end
    if total > LIMIT_BYTES then
      -- Sizes by the folder two levels under the home folder, such as .config/app.
      local sizes = {}
      for relative, content in pairs(files) do
        local folder = relative:match("^([^/]+/[^/]+)/") or relative
        sizes[folder] = (sizes[folder] or 0) + #content
      end
      local folders = sorted(sizes)
      table.sort(folders, function(a, b)
        return sizes[a] < sizes[b]
      end)
      for i = math.max(1, #folders - 4), #folders do
        job.emit(string.format("too big: ~/%s is %d MB, leave it out", folders[i], math.ceil(sizes[folders[i]] / 1048576)))
      end
      job.stop(5)
    end
    local order = {}
    for relative in pairs(files) do
      table.insert(order, relative)
    end
    table.sort(order)
    return files, order
  end

  -- Writes <files> under folder <into>, with the modes of the originals under the home folder.
  local function writeFiles(files, order, into)
    local written, sources = {}, {}
    for _, relative in ipairs(order) do
      breathe()
      local path = into .. "/" .. relative
      noctalia.mkdirAll(parentOf(path))
      if not noctalia.writeFile(path, files[relative]) then
        job.emit("could not write " .. path)
        job.stop(1)
      end
      table.insert(written, path)
      table.insert(sources, home .. "/" .. relative)
    end
    local exec = executable(sources)
    local execWritten = {}
    for i, source in ipairs(sources) do
      if exec[source] then
        execWritten[written[i]] = true
      end
    end
    setModes(written, execWritten)
  end

  ---------------------------------------------------------------------------------------
  -- Noctalia: its config, the settings changed in its settings window, and the plugins
  -- that are on. With sharing on, the config folder is shared like the dotfiles, the
  -- settings one at a time, and this device's folder keeps only the settings tied to its
  -- hardware, in settings.toml.

  local settingsPath = home .. "/.local/state/noctalia/settings.toml"
  noctalia.removeFile(repo .. "/" .. dir .. "/settings.toml")
  if opt.noctalia then
    if not share then
      local config = home .. "/.config/noctalia"
      local into = repo .. "/" .. dir .. "/noctalia/config"
      if isDir(config) then
        for _, relative in ipairs(filesUnder(config)) do
          breathe()
          noctalia.mkdirAll(parentOf(into .. "/" .. relative))
          noctalia.writeFile(into .. "/" .. relative, noctalia.readFile(config .. "/" .. relative) or "")
        end
      end
      local settings = noctalia.readFile(settingsPath)
      if settings then
        noctalia.mkdirAll(repo .. "/" .. dir .. "/noctalia/state")
        noctalia.writeFile(repo .. "/" .. dir .. "/noctalia/state/settings.toml", settings)
      end
    end
    if noctalia.commandExists("noctalia") then
      local plugins = {}
      for line in eachLine(output({ "noctalia", "msg", "plugins", "list" })) do
        local fields = string.split(line, " ")
        if fields[4] == "enabled" then
          table.insert(plugins, fields[1])
        end
      end
      job.emit("count plugins " .. #plugins)
      if not share then
        noctalia.mkdirAll(repo .. "/" .. dir .. "/noctalia")
        noctalia.writeFile(repo .. "/" .. dir .. "/noctalia/plugins.txt", linesText(plugins))
      end
    end
  end

  ---------------------------------------------------------------------------------------
  -- This device's own dotfiles: all of them without sharing, else those kept on this device.

  removeTree(repo .. "/" .. dir .. "/files")
  local own, candidates = {}, opt.deviceFiles
  if not share then
    candidates = table.clone(opt.files)
    table.move(opt.deviceFiles, 1, #opt.deviceFiles, #candidates + 1, candidates)
  end
  for _, path in ipairs(candidates) do
    if path:sub(1, #home + 1) ~= home .. "/" then
      job.emit("skipped, not in the home folder: " .. path)
    elseif not noctalia.fileExists(path) then
      job.emit("skipped, missing: " .. path)
    else
      table.insert(own, path)
    end
  end
  local ownCount = 0
  if #own > 0 then
    local files, order = pick(own, opt.leaveOut)
    writeFiles(files, order, repo .. "/" .. dir .. "/files")
    ownCount = #order
  end
  job.emit("count files " .. ownCount)

  ---------------------------------------------------------------------------------------
  -- Sharing.

  local agreedSettings = nil
  if share and opt.noctalia then
    -- The settings come first, so a file list another device changed is in place for the
    -- plugin's next save.
    local before = noctalia.readFile(settingsPath)
    if before then
      local ok, merged = pcall(Settings.merge, before, theirFile("shared/noctalia/settings.toml") or "",
        noctalia.readFile(gitDir .. "/resurrect-settings") or "", opt.settingsChoice == "mine")
      if not ok then
        job.emit(tostring(merged))
        job.emit("could not share Noctalia's settings")
        job.stop(1)
      end
      if not replace(repo .. "/shared/noctalia/settings.toml", merged.shared) then
        job.emit("could not share Noctalia's settings")
        job.stop(1)
      end
      writeOrRemove(repo .. "/" .. dir .. "/settings.toml", merged.localText)
      -- Settings another device changed wait until the owner takes them. Until then the
      -- agreed settings stay as they were, so they still read as changed elsewhere, and the
      -- new settings are kept for Review to show.
      local incoming = opt.dataDir .. "/incoming-settings.toml"
      local applied = 0
      -- Taking them takes the settings the owner was shown: when they changed since, they
      -- wait again.
      if merged.taken > 0 and not (opt.settingsChoice == "theirs" and (merged.settings or "") == opt.settingsShown) then
        noctalia.writeFile(incoming, merged.settings or "")
        job.emit("incoming-settings " .. merged.taken)
      else
        noctalia.removeFile(incoming)
        -- The agreed settings take their place once the save is committed. A setting of a
        -- save that was not committed would otherwise read, on the next save, as removed by
        -- another device, and be removed here too.
        agreedSettings = merged.shared
        -- Noctalia may have written the file meanwhile; then this waits for the next save.
        if merged.settings and noctalia.readFile(settingsPath) == before then
          if replace(settingsPath, merged.settings) then
            applied = merged.taken
          end
        end
      end
      job.emit("settings applied " .. applied)
      job.emit("count settings " .. merged.count)
      if applied > 0 then
        job.run({ "noctalia", "msg", "config-reload" })
      end
    end
  end

  if share then
    -- Shares the dotfiles. shared/files/ holds every shared file at its place under the
    -- home folder. For each file there are three versions: this device's, the one in
    -- <theirs>, and the one this device last agreed on, kept in .git/resurrect-base. A file
    -- only this device changed is saved. A file only another device changed waits, reported
    -- as incoming, until the owner takes it; then it is put in place here, after a backup. A
    -- file both changed is left alone on both sides and reported, until the owner chooses.
    -- When files put in place give Hyprland config errors, they go
    -- back and stay held in .git/resurrect-held until another device changes them again.
    -- When another device removed more than half of the shared files at once, none is
    -- removed here; this device shares them again.
    local roots = {}
    if opt.noctalia then
      table.insert(roots, home .. "/.config/noctalia")
    end
    for _, path in ipairs(opt.files) do
      table.insert(roots, path)
    end
    -- Paths kept on this device, relative to the home folder: Leave out and Only this device.
    local only = table.clone(opt.leaveOut)
    for _, path in ipairs(opt.deviceFiles) do
      table.insert(only, path)
    end
    local kept = {}
    for _, path in ipairs(only) do
      path = path:gsub("/$", "")
      if path:sub(1, #home + 1) == home .. "/" then
        table.insert(kept, path:sub(#home + 2))
      end
    end
    -- Only the paths this device lists are written by a save. Resurrect's data folder, which
    -- holds the approved steps, is never shared, so no other device can approve a step here.
    local listed = {}
    for _, path in ipairs(roots) do
      path = path:gsub("/$", "")
      if path:sub(1, #home + 1) == home .. "/" then
        table.insert(listed, path:sub(#home + 2))
      end
    end
    local data = opt.dataDir:sub(1, #home + 1) == home .. "/" and { opt.dataDir:sub(#home + 2) } or {}
    local function under(path, list)
      for _, top in ipairs(list) do
        if path == top or path:sub(1, #top + 1) == top .. "/" then
          return true
        end
      end
      return false
    end
    local function isKept(path)
      return under(path, kept) or not under(path, listed) or under(path, data)
    end

    local function readPairs(path)
      local map, n = {}, 0
      for line in eachLine(noctalia.readFile(path)) do
        local blob, file = line:match("^(%S+) (.+)$")
        if blob then
          map[file] = blob
          n += 1
        end
      end
      return map, n
    end
    local basePath, heldPath = gitDir .. "/resurrect-base", gitDir .. "/resurrect-held"
    local base, baseCount = readPairs(basePath)
    local held = readPairs(heldPath)
    local resolve = opt.resolve
    local backup = home .. "/.local/state/resurrect/backup-" .. os.date("%Y%m%d-%H%M%S")

    -- This device's shared files.
    local mine = pick(roots, only)

    -- { blob, mode } for each shared file in <theirs>.
    local their = {}
    if theirs then
      local tree = git("-c", "core.quotePath=false", "ls-tree", "-r", theirs, "--", "shared/files")
      if tree.stdoutTruncated then
        job.emit("could not list the shared files")
        job.stop(1)
      end
      for line in eachLine(tree.stdout) do
        local mode, blob, path = line:match("^(%d+) %a+ (%x+)\t(.+)$")
        -- A save never shares a link, or a path that is not plain, so neither came from
        -- Resurrect.
        if path and mode ~= "120000" and isPlain(path) then
          their[path:sub(#"shared/files/" + 1)] = { blob = blob, mode = mode }
        end
      end
    end

    -- A file other devices share is this device's too when it is here; otherwise its next
    -- save would read it as deleted.
    local others = {}
    for path in pairs(their) do
      others[path] = true
    end
    for path in pairs(base) do
      others[path] = true
    end
    for _, path in ipairs(sorted(others)) do
      breathe()
      local full = home .. "/" .. path
      if mine[path] == nil and not isKept(path) and noctalia.fileExists(full) and not isDir(full) then
        local content = noctalia.readFile(full)
        if content == nil then
          job.emit("could not read ~/" .. path)
          job.stop(1)
        end
        mine[path] = content
      end
    end
    for path in pairs(mine) do
      breathe()
      if isKept(path) or path == ".git" or path:find("^%.git/") or path:find("/%.git/") or path:find("/%.git$") then
        mine[path] = nil
      end
    end

    -- The blob of each of this device's files, as git names it.
    local mineOrder = sorted(mine)
    local hashes = {}
    for first = 1, #mineOrder, CHUNK do
      local argv = { "git", "-C", repo, "hash-object", "--no-filters", "--" }
      for i = first, math.min(first + CHUNK - 1, #mineOrder) do
        table.insert(argv, home .. "/" .. mineOrder[i])
      end
      local result = job.run(argv)
      if result.exitCode ~= 0 then
        failed(result, 1)
      end
      local i = first
      for line in eachLine(result.stdout) do
        hashes[mineOrder[i]] = line
        i += 1
      end
    end
    local mineExec = {}
    do
      local sources = {}
      for _, path in ipairs(mineOrder) do
        table.insert(sources, home .. "/" .. path)
      end
      for full in pairs(executable(sources)) do
        mineExec[full:sub(#home + 2)] = true
      end
    end

    -- The content of a blob.
    local function blob(hash)
      local result = git("cat-file", "blob", hash)
      if result.exitCode ~= 0 or result.stdoutTruncated then
        return nil
      end
      return result.stdout
    end

    local function noBackup(path)
      job.emit("could not back up ~/" .. path .. " to " .. backup .. ", so the save stopped before replacing it")
      job.stop(1)
    end

    -- Copies the file at <path> under the home folder into the backup, or stops the save.
    local function backUp(path)
      local content = noctalia.readFile(home .. "/" .. path)
      local target = backup .. "/" .. path
      if content == nil or not noctalia.mkdirAll(parentOf(target)) or not noctalia.writeFile(target, content) then
        noBackup(path)
      end
    end

    -- Whether <target>, through a link on the way, is in Resurrect's data folder.
    local function intoData(target)
      local argv = { "find", "-L", opt.dataDir, "-samefile", parentOf(target) }
      if noctalia.fileExists(target) then
        table.move({ "-o", "-samefile", target }, 1, 3, #argv + 1, argv)
      end
      if trim(job.run(argv).stdout) ~= "" then
        job.emit("left out ~/" .. target:sub(#home + 2) .. ": it leads into Resurrect's data folder")
        return true
      end
      return false
    end

    -- Puts blob <hash> with <mode> at <path> under the home folder, in one step.
    local function put(path, hash, mode)
      local target = home .. "/" .. path
      if isDir(target) then
        return false
      end
      local content = blob(hash)
      if content == nil or not noctalia.mkdirAll(parentOf(target)) or intoData(target) then
        return false
      end
      if noctalia.fileExists(target) then
        backUp(path)
      end
      local tmp = parentOf(target) .. "/." .. path:match("[^/]*$") .. ".resurrect-tmp"
      if not noctalia.writeFile(tmp, content) then
        return false
      end
      job.run({ "chmod", mode == "100755" and "755" or "644", "--", tmp })
      return noctalia.renameFile(tmp, target)
    end

    -- Moves the file at <path> under the home folder into the backup.
    local function drop(path)
      local target = home .. "/" .. path
      if not noctalia.fileExists(target) or intoData(target) then
        return
      end
      if not noctalia.mkdirAll(parentOf(backup .. "/" .. path)) or not noctalia.renameFile(target, backup .. "/" .. path) then
        noBackup(path)
      end
    end

    -- The shared copy of each path: this device's file, or a blob, with its mode.
    local sharedFiles = {}
    local function keep(path, hash, mode)
      if hash == nil then
        sharedFiles[path] = { content = mine[path], exec = mineExec[path] }
      else
        sharedFiles[path] = { blob = hash, exec = mode == "100755" }
      end
    end

    local paths = {}
    for path in pairs(mine) do
      paths[path] = true
    end
    for path in pairs(their) do
      paths[path] = true
    end
    for path in pairs(base) do
      paths[path] = true
    end
    paths = sorted(paths)

    -- Files only another device removed. More than half of them at once is a mistake, such
    -- as a failed save there: then none is removed here.
    local removing = 0
    for _, path in ipairs(paths) do
      if not isKept(path) and mine[path] ~= nil and their[path] == nil and base[path] ~= nil and hashes[path] == base[path] then
        removing += 1
      end
    end
    local manyRemoved = removing > 0 and removing * 2 > baseCount

    local newBase, newHeld, applied = {}, {}, {}
    for _, path in ipairs(paths) do
      breathe()
      local t = their[path] and their[path].blob
      local mode = their[path] and their[path].mode
      -- What the owner is shown and takes: the content and whether it is executable.
      local version = t and t .. ":" .. mode or "-"
      local b = base[path]
      local m = hashes[path]
      -- Theirs is held when it is the version that broke Hyprland here.
      local isHeld = held[path] ~= nil and held[path] == t
      -- "theirs <version>" takes the version the owner was shown. When another device changed
      -- the file again since, its content or its mode, the choice is dropped and the file waits
      -- again, with its new version.
      local choice = resolve[path]
      if choice ~= nil and choice ~= "mine" then
        choice = choice == "theirs " .. version and "theirs" or nil
      end

      if isKept(path) then
        -- Kept on this device, or not listed here: the shared copy stays as the other devices
        -- left it.
        if t then
          keep(path, t, mode)
        end
        if b then
          newBase[path] = b
        end
      elseif m == t or choice == "mine" or (t == b and choice ~= "theirs")
        or (t == nil and m ~= nil and manyRemoved and choice ~= "theirs") then
        -- Same on both sides, or only this device changed it: this device's version is shared.
        if m then
          keep(path)
          newBase[path] = m
        end
      elseif m == b and not isHeld and choice == nil then
        -- Only another device changed it: it waits until the owner takes it or keeps theirs
        -- out. The shared copy stays theirs and the agreed version stays, so it still reads
        -- as changed elsewhere on the next save.
        if t then
          keep(path, t, mode)
        end
        if b then
          newBase[path] = b
        end
        job.emit("incoming " .. version .. " " .. path)
      elseif choice == "theirs" then
        -- The owner took theirs: it is put in place here.
        if t == nil then
          drop(path)
          job.emit("removed " .. path)
        elseif put(path, t, mode) then
          keep(path, t, mode)
          newBase[path] = t
          table.insert(applied, path)
          job.emit("applied " .. path)
        else
          keep(path, t, mode)
          if b then
            newBase[path] = b
          end
          job.emit("conflict " .. version .. " " .. path)
        end
      else
        -- Changed on both sides, or held back: nothing moves until the owner chooses.
        if t then
          keep(path, t, mode)
        end
        if b then
          newBase[path] = b
        end
        if isHeld then
          newHeld[path] = t
          job.emit("held " .. version .. " " .. path)
        else
          job.emit("conflict " .. version .. " " .. path)
        end
      end
    end

    -- Hyprland reloads its config when a file changes. If what came in gives config errors,
    -- every file put in place goes back, and stays held until another device changes it.
    local hypr = false
    for _, path in ipairs(applied) do
      if path:find("^%.config/hypr/") then
        hypr = true
      end
    end
    if hypr and noctalia.commandExists("hyprctl") and job.run({ "hyprctl", "reload" }).exitCode == 0 then
      job.wait(1000)
      local errors = false
      for line in eachLine(job.run({ "hyprctl", "configerrors" }).stdout) do
        if not trim(line):lower():match("^$") and trim(line):lower() ~= "no errors" then
          errors = true
        end
      end
      if errors then
        for _, path in ipairs(applied) do
          local target = home .. "/" .. path
          local saved = noctalia.readFile(backup .. "/" .. path)
          if saved then
            replace(target, saved)
          else
            noctalia.removeFile(target)
          end
          -- The agreed version goes back to what it was, so the file stays a difference.
          newBase[path] = base[path]
          newHeld[path] = their[path].blob
          job.emit("held " .. their[path].blob .. ":" .. their[path].mode .. " " .. path)
        end
        job.run({ "hyprctl", "reload" })
      end
    end
    if manyRemoved then
      job.emit("kept " .. removing .. " files another device removed")
    end

    -- shared/files/ as decided. Files that did not change stay as they are.
    local sharedRoot = repo .. "/shared/files"
    for _, relative in ipairs(filesUnder(sharedRoot)) do
      if sharedFiles[relative] == nil then
        noctalia.removeFile(sharedRoot .. "/" .. relative)
      end
    end
    local written, execWritten = {}, {}
    for _, path in ipairs(sorted(sharedFiles)) do
      breathe()
      local file = sharedFiles[path]
      local content = file.content or blob(file.blob)
      if content == nil then
        job.emit("could not read the shared copy of ~/" .. path)
        job.stop(1)
      end
      local target = sharedRoot .. "/" .. path
      if noctalia.readFile(target) ~= content then
        noctalia.mkdirAll(parentOf(target))
        noctalia.writeFile(target, content)
      end
      table.insert(written, target)
      execWritten[target] = file.exec
    end
    setModes(written, execWritten)

    local baseLines, heldLines = {}, {}
    for _, path in ipairs(sorted(newBase)) do
      table.insert(baseLines, newBase[path] .. " " .. path)
    end
    for _, path in ipairs(sorted(newHeld)) do
      table.insert(heldLines, newHeld[path] .. " " .. path)
    end
    replace(basePath, linesText(baseLines))
    replace(heldPath, linesText(heldLines))
    job.emit("count shared " .. #written)
  end

  ---------------------------------------------------------------------------------------
  -- The restore script, and the owner's own steps.

  -- Older versions put restore.sh, and settings.awk for it, in the repository. A restore runs
  -- the plugin's own copy, as the remote could change the repository's, so neither stays.
  noctalia.removeFile(repo .. "/restore.sh")
  noctalia.removeFile(repo .. "/settings.awk")

  -- Each executable file in hooks/save/ runs, in name order, and in
  -- devices/<name>/hooks/save/. A step runs only when this device approved it as it is now:
  -- its path and checksum are in the approved file, which lives outside the repository, so
  -- a step that came from the remote never runs unseen.
  local approved = setOf(entries(noctalia.readFile(opt.approved)))
  local hooks, waiting = 0, 0
  local function runHooks(folder, into)
    if not isDir(repo .. "/" .. folder) then
      return
    end
    local names = noctalia.listDir(repo .. "/" .. folder) or {}
    table.sort(names)
    local candidates = {}
    for i = #names, 1, -1 do
      if names[i]:sub(1, 1) == "." then
        table.remove(names, i)
      end
    end
    for _, name in ipairs(names) do
      table.insert(candidates, repo .. "/" .. folder .. "/" .. name)
    end
    local exec = executable(candidates)
    for _, name in ipairs(names) do
      local hook = folder .. "/" .. name
      if exec[repo .. "/" .. hook] then
        local sum = (job.run({ "sha256sum", "--", repo .. "/" .. hook }).stdout or ""):match("^(%x+)")
        if sum == nil or not approved[sum .. " " .. hook] then
          waiting += 1
          job.emit("unapproved " .. hook)
        else
          hooks += 1
          noctalia.mkdirAll(into)
          local result = job.run({
            "env", "-C", repo, "RESURRECT_REPO=" .. repo, "RESURRECT_DEVICE=" .. device, "RESURRECT_DIR=" .. into,
            repo .. "/" .. hook,
          })
          for line in eachLine(result.stdout .. "\n" .. result.stderr) do
            job.emit(line)
          end
          if result.exitCode ~= 0 then
            job.emit("hook failed: " .. hook)
            job.stop(3)
          end
        end
      end
    end
  end
  if share then
    fromTheirs("shared/steps")
    runHooks("hooks/save", repo .. "/shared/steps")
  else
    runHooks("hooks/save", repo .. "/" .. dir)
  end
  runHooks(dir .. "/hooks/save", repo .. "/" .. dir)
  job.emit("count hooks " .. hooks)
  job.emit("count waiting " .. waiting)

  ---------------------------------------------------------------------------------------
  -- Committing and pushing.

  -- A save commits only the paths it writes, never anything else in the folder, staged or
  -- not: shared/, this device's folder, and the files older versions wrote at the top.
  local ours = {}
  for _, path in ipairs({ "shared", dir, "restore.sh", "settings.awk" }) do
    if noctalia.fileExists(repo .. "/" .. path) or trim(git("ls-files", "--", path).stdout) ~= "" then
      table.insert(ours, path)
    end
  end
  local function gitPaths(...)
    local argv = { ... }
    table.insert(argv, "--")
    table.move(ours, 1, #ours, #argv + 1, argv)
    return git(table.unpack(argv))
  end
  local function commitPaths()
    local argv = { "commit", "-q", "-m", "Snapshot of " .. device .. " on " .. os.date("%Y-%m-%d %H:%M"), "--" }
    table.move(ours, 1, #ours, #argv + 1, argv)
    return gitAs(table.unpack(argv))
  end
  gitPaths("add", "-A")

  -- Nothing that looks like a password or key is committed, since saves may be pushed,
  -- except in Noctalia's config and settings, which are saved whole (gitleaks.toml). Known
  -- findings can be allowed in .gitleaksignore in the data folder. gitleaks also reads one
  -- in the repository, which the remote could fill, so that one is moved aside meanwhile.
  if opt.secretCheck and noctalia.commandExists("gitleaks") then
    local ignore, aside = repo .. "/.gitleaksignore", gitDir .. "/resurrect-gitleaksignore"
    local moved = noctalia.fileExists(ignore) and noctalia.renameFile(ignore, aside)
    if noctalia.fileExists(ignore) then
      job.emit("could not move " .. ignore .. " aside for the secret check")
      job.stop(1)
    end
    local result = job.run({
      "gitleaks", "git", "--pre-commit", "--staged", "--redact", "--no-banner", "-v",
      "--config", (noctalia.pluginDir() or "") .. "/gitleaks.toml",
      "--gitleaks-ignore-path", opt.dataDir .. "/.gitleaksignore", repo,
    })
    if moved then
      noctalia.renameFile(aside, ignore)
    end
    if result.exitCode ~= 0 then
      gitPaths("reset", "-q")
      local found = {}
      for line in eachLine((result.stdout .. "\n" .. result.stderr):gsub("\27%[[%d;]*m", "")) do
        local file = line:match("^File:%s*(.+)$")
        if file then
          found["secret found in: " .. file] = true
        end
      end
      for _, line in ipairs(sorted(found)) do
        job.emit(line)
      end
      job.stop(4)
    end
  end

  if gitPaths("diff", "--cached", "--quiet").exitCode == 0 then
    job.emit("unchanged")
  else
    local committed = commitPaths()
    if committed.exitCode ~= 0 then
      failed(committed, 1)
    end
    job.emit("saved")
  end
  if agreedSettings then
    replace(gitDir .. "/resurrect-settings", agreedSettings)
  end

  if remote ~= "" then
    -- Other devices push to the same repository. Their saves are in their own folders, and
    -- their shared files are already taken in, so this save goes on top of theirs; a file
    -- both changed keeps this device's version. The rebase never runs over changes of the
    -- owner's own that are not committed, so their files and what they staged stay as they
    -- are: the save is kept here and pushed once they are committed or undone.
    if trim(git("status", "--porcelain", "--untracked-files=no").stdout) ~= "" then
      job.emit("not pushed: commit or undo your own changes in " .. repo .. " first; see git status there")
      job.stop(2)
    end
    branch = trim(git("symbolic-ref", "--short", "HEAD").stdout)
    local saved = trim(git("rev-parse", "HEAD").stdout)
    if job.long({ "git", "-C", repo, "fetch", "-q", "origin", branch }).exitCode == 0 then
      if gitAs("rebase", "-q", "-X", "theirs", "origin/" .. branch).exitCode ~= 0 then
        git("rebase", "--abort")
        job.emit("could not combine this save with the other devices' saves; see git status in " .. repo)
        job.stop(2)
      end
      -- The shared files are already merged, so shared/ stays as this save made it, also
      -- where it equals this device's last save. When another device pushed meanwhile, its
      -- save is newer: the next save merges it.
      if share and verify("origin/" .. branch) == fetched then
        git("restore", "-q", "--source=" .. saved, "--staged", "--worktree", "--", "shared")
        if git("diff", "--cached", "--quiet", "--", "shared").exitCode ~= 0 then
          local committed = gitAs("commit", "-q", "-m", "Snapshot of " .. device .. " on " .. os.date("%Y-%m-%d %H:%M"),
            "--", "shared")
          if committed.exitCode ~= 0 then
            failed(committed, 1)
          end
        end
      end
    end
    local pushed = job.long({ "git", "-C", repo, "push", "-q", "-u", "origin", "HEAD" })
    if pushed.exitCode ~= 0 then
      failed({ stdout = pushed.output }, 2)
    end
    job.emit("pushed")
  end
end

return Save
