--!nonstrict
-- Downloader service: owns the queue and runs yt-dlp, one download at a time.
--
-- yt-dlp runs detached, so a download outlives the 60 s limit of runAsync callbacks and
-- survives a reload of this script. RUNNER writes yt-dlp's output, its process id and its
-- exit code next to the queue in the data directory; update() reads them back.
--
-- Publishes "downloader.model" and takes commands on "downloader.command".

local REQUIRED = { "yt-dlp", "ffmpeg" }

local INSTALLERS = {
  { manager = "pacman", command = "sudo pacman -S --needed yt-dlp ffmpeg" },
  { manager = "apt", command = "sudo apt install yt-dlp ffmpeg" },
  { manager = "dnf", command = "sudo dnf install yt-dlp ffmpeg" },
  { manager = "zypper", command = "sudo zypper install yt-dlp ffmpeg" },
}

-- $1 is the path prefix of the job's files, the rest is the yt-dlp command.
local RUNNER = [[
prefix=$1
shift
"$@" >"$prefix.log" 2>&1 &
echo $! >"$prefix.pid"
wait $!
echo $? >"$prefix.exit"
]]

-- Bytes rather than yt-dlp's percent text, which can lag behind on fast downloads.
local PROGRESS_TEMPLATE = "download:progress:%(progress.downloaded_bytes)s|"
  .. "%(progress.total_bytes,progress.total_bytes_estimate)s|%(progress._speed_str)s|%(progress._eta_str)s"

local FINISHED = { done = true, failed = true, cancelled = true }

local dataDir = noctalia.pluginDataDir()
local jobsDir = dataDir .. "/jobs"
local queueFile = dataDir .. "/queue.json"

local jobs = {}
local lastMode = "video"
local missing = {}
local install = nil
local canOpen = false
local reading = false

local function jobPrefix(job)
  return jobsDir .. "/" .. job.id
end

local function save()
  local text = noctalia.json.encode({ jobs = jobs, lastMode = lastMode })
  if text then
    noctalia.writeFile(queueFile, text)
  end
end

local function installCommand()
  for _, installer in ipairs(INSTALLERS) do
    if noctalia.commandExists(installer.manager) then
      return installer.command
    end
  end
  return nil
end

local function checkDependencies()
  missing = {}
  for _, command in ipairs(REQUIRED) do
    if not noctalia.commandExists(command) then
      table.insert(missing, command)
    end
  end
  install = installCommand()
  canOpen = noctalia.commandExists("xdg-open")
end

local function publish()
  noctalia.state.set("downloader.model", {
    ready = #missing == 0,
    missing = missing,
    installCommand = install,
    canOpen = canOpen,
    folder = noctalia.expandPath(noctalia.getConfig("folder")),
    folderLabel = noctalia.getConfig("folder"),
    lastMode = lastMode,
    jobs = jobs,
  })
end

local function field(value)
  value = noctalia.string.trim(value or "")
  if value == "" or value == "NA" or value:find("Unknown") then
    return nil
  end
  return value
end

-- Reads what yt-dlp printed: progress lines from PROGRESS_TEMPLATE, and the title: and
-- file: lines from the --print options in downloadArgs.
local function readLog(job, text)
  for line in text:gmatch("[^\n]+") do
    local progress = line:match("^progress:(.*)")
    local title = line:match("^title:(.*)")
    local file = line:match("^file:(.*)")
    local err = line:match("^ERROR: (.*)")
    if progress then
      local done, total, speed, eta = progress:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)")
      done, total = tonumber(field(done) or ""), tonumber(field(total) or "")
      if done and total and total > 0 then
        job.progress = math.clamp(done / total, 0, 1)
      end
      job.speed = field(speed)
      job.eta = field(eta)
    elseif title then
      job.title = field(title) or job.title
    elseif file then
      job.file = field(file)
    elseif err then
      job.error = err
    end
  end
end

local function downloadArgs(job)
  local args = {
    "yt-dlp", "--newline", "--no-colors", "--no-warnings",
    "--progress", "--progress-delta", "0.5", "--progress-template", PROGRESS_TEMPLATE,
    "--print", "before_dl:title:%(title)s",
    "--print", "after_move:file:%(filepath)s",
    "--paths", noctalia.expandPath(noctalia.getConfig("folder")),
    "--output", "%(title)s.%(ext)s",
    "--embed-metadata",
  }
  if not noctalia.getConfig("whole_playlist") then
    table.insert(args, "--no-playlist")
  end

  if job.mode == "audio" then
    table.insert(args, "--extract-audio")
    local format = noctalia.getConfig("audio_format")
    if format ~= "best" then
      table.insert(args, "--audio-format")
      table.insert(args, format)
    end
  else
    local quality = noctalia.getConfig("video_quality")
    if quality ~= "best" then
      table.insert(args, "--format-sort")
      table.insert(args, "res:" .. quality)
    end
    table.insert(args, "--merge-output-format")
    table.insert(args, "mp4/mkv")
  end

  -- The owner's own yt-dlp arguments come last, so they win over the ones above.
  for word in (noctalia.getConfig("extra_args") or ""):gmatch("%S+") do
    table.insert(args, word)
  end

  -- "--" keeps a link that starts with "-" from being read as an option.
  table.insert(args, "--")
  table.insert(args, job.url)
  return args
end

local function start(job)
  job.status = "running"
  job.progress = 0
  noctalia.mkdirAll(jobsDir)
  noctalia.mkdirAll(noctalia.expandPath(noctalia.getConfig("folder")))
  local argv = { "sh", "-c", RUNNER, "downloader", jobPrefix(job) }
  for _, arg in ipairs(downloadArgs(job)) do
    table.insert(argv, arg)
  end
  noctalia.runAsync(argv)
  save()
end

local function removeFiles(job)
  for _, ext in ipairs({ ".log", ".pid", ".exit" }) do
    noctalia.removeFile(jobPrefix(job) .. ext)
  end
end

local function notify(job)
  if not noctalia.getConfig("notify") then
    return
  end
  local name = job.title or job.url
  if job.status == "done" then
    noctalia.notify(noctalia.tr("notify.done.title"), name)
  elseif job.status == "failed" then
    noctalia.notifyError(noctalia.tr("notify.failed.title"), name)
  end
end

local function finish(job, exitCode)
  if exitCode == 0 then
    job.status = "done"
    job.progress = 1
  elseif job.cancelling then
    job.status = "cancelled"
  else
    job.status = "failed"
  end
  job.cancelling = nil
  job.speed = nil
  job.eta = nil
  notify(job)
  save()
end

local function runningJob()
  for _, job in ipairs(jobs) do
    if job.status == "running" then
      return job
    end
  end
  return nil
end

local function nextQueued()
  for _, job in ipairs(jobs) do
    if job.status == "queued" then
      return job
    end
  end
  return nil
end

local function findJob(id)
  for index, job in ipairs(jobs) do
    if job.id == id then
      return job, index
    end
  end
  return nil
end

local function poll()
  local job = runningJob()
  if job == nil then
    local queued = nextQueued()
    if queued and #missing == 0 then
      start(queued)
      publish()
    end
    return
  end
  if reading then
    return
  end

  reading = true
  local prefix = jobPrefix(job)
  noctalia.readFileAsync(prefix .. ".log", function(text)
    if text then
      readLog(job, text)
    end
    noctalia.readFileAsync(prefix .. ".exit", function(exitText)
      reading = false
      local exitCode = tonumber(exitText and noctalia.string.trim(exitText) or "")
      if exitCode then
        finish(job, exitCode)
      end
      publish()
    end)
  end)
end

local function cancel(job)
  if job.status == "queued" then
    job.status = "cancelled"
    save()
  elseif job.status == "running" then
    job.cancelling = true
    noctalia.readFileAsync(jobPrefix(job) .. ".pid", function(pid)
      pid = pid and noctalia.string.trim(pid)
      if pid and pid:match("^%d+$") then
        noctalia.runAsync({ "kill", pid })
      end
    end)
  end
end

local MAX_FINISHED = 30

-- Keeps the list short: the oldest finished downloads go first.
local function prune()
  local finished = 0
  for index = #jobs, 1, -1 do
    local job = jobs[index]
    if FINISHED[job.status] then
      finished += 1
      if finished > MAX_FINISHED then
        removeFiles(job)
        table.remove(jobs, index)
      end
    end
  end
end

local function add(url, mode)
  local id = tostring(math.floor(noctalia.nowMs()))
  lastMode = mode
  table.insert(jobs, { id = id, url = url, mode = mode, status = "queued", progress = 0 })
  prune()
  save()
end

-- Queues a link as video or audio. Without a link, the clipboard's text is used.
local function queueLink(payload, mode)
  local link = noctalia.string.trim(payload or noctalia.clipboardText() or "")
  if not link:match("^https?://%S+$") then
    noctalia.notifyError(noctalia.tr("notify.not_a_link.title"), link)
    return
  end
  add(link, mode)
  publish()
  poll()
end

noctalia.state.watch("downloader.command", function(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "add" and type(command.url) == "string" then
    add(command.url, command.mode == "audio" and "audio" or "video")
  elseif action == "cancel" then
    local job = findJob(command.id)
    if job then
      cancel(job)
    end
  elseif action == "retry" then
    local job = findJob(command.id)
    if job then
      add(job.url, job.mode)
    end
  elseif action == "remove" then
    local job, index = findJob(command.id)
    if job and FINISHED[job.status] then
      removeFiles(job)
      table.remove(jobs, index)
      save()
    end
  elseif action == "clear" then
    local kept = {}
    for _, job in ipairs(jobs) do
      if FINISHED[job.status] then
        removeFiles(job)
      else
        table.insert(kept, job)
      end
    end
    jobs = kept
    save()
  elseif action == "clipboard" then
    queueLink(nil, lastMode)
    return
  elseif action == "recheck" then
    checkDependencies()
  end
  publish()
  poll()
end)

-- A download that was running when Noctalia stopped either finished meanwhile (its exit
-- file exists, and poll() picks it up) or died with Noctalia.
local function recover()
  local job = runningJob()
  if job == nil or noctalia.fileExists(jobPrefix(job) .. ".exit") then
    return
  end
  noctalia.readFileAsync(jobPrefix(job) .. ".pid", function(pid)
    pid = pid and noctalia.string.trim(pid)
    if pid == nil or not pid:match("^%d+$") then
      finish(job, -1)
      publish()
      return
    end
    noctalia.runAsync({ "kill", "-0", pid }, function(result)
      if result.exitCode ~= 0 and not noctalia.fileExists(jobPrefix(job) .. ".exit") then
        finish(job, -1)
        publish()
      end
    end)
  end)
end


-- noctalia msg plugin omerfuyar/downloader:service all video <link>
-- noctalia msg plugin omerfuyar/downloader:service all audio <link>
-- Without a link, the clipboard's text is used.
function onIpc(event, payload)
  if event == "video" or event == "audio" then
    queueLink(payload, event)
  end
end

function update()
  poll()
end

function onConfigChanged()
  publish()
end

checkDependencies()
publish()
noctalia.readFileAsync(queueFile, function(text)
  local saved = text and noctalia.json.decode(text)
  if type(saved) == "table" then
    jobs = type(saved.jobs) == "table" and saved.jobs or {}
    lastMode = saved.lastMode == "audio" and "audio" or "video"
  end
  recover()
  publish()
  noctalia.setUpdateInterval(500)
end)
