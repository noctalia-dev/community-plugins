--!nonstrict
-- Process Manager service: while the panel is open, reads every process as often as the
-- interval setting says, works out each one's CPU use since the last read, and reads more
-- about the one process the details view shows. Ends processes when asked: first politely,
-- then by force when one does not stop. Another user's process is ended with pkexec, or with
-- sudo in a terminal, as the admin setting says.
--
-- Publishes "processes.model" and takes commands on "processes.command".

-- A process that still runs this long after End is shown as not responding.
local STUCK_MS = 3000

-- One line per process, without kernel threads (pid 2 and its children):
-- pid, ppid, state, CPU ticks, start time, resident pages, threads, uid, user, name and the
-- start of the command line, separated by tabs. ps gives the owners and command lines, and
-- /proc/<pid>/stat the rest; both go through one awk, so nothing is written to disk. The
-- name in /proc/<pid>/stat sits in parentheses and may hold spaces and parentheses, so the
-- fields after it are counted from its last ")".
-- With a pid as $1, also "@@io" with its bytes read and written, and "@@cmd" with its whole
-- command line, for the details view. Last, "@@sys" with the uptime and total memory in kB.
local READ = [=[
{ ps -eo pid=,uid=,user=,args=; echo @@stat; cat /proc/[0-9]*/stat 2>/dev/null; } | awk '
  !stat && $0 == "@@stat" { stat = 1; next }
  !stat {
    pid = $1; uid[pid] = $2; user[pid] = $3
    $1 = $2 = $3 = ""; sub(/^ +/, ""); gsub(/\t/, " ")
    args[pid] = substr($0, 1, 200)
    next
  }
  {
    first = index($0, "("); last = 0
    for (i = length($0); i > first; i--) if (substr($0, i, 1) == ")") { last = i; break }
    pid = substr($0, 1, first - 2); name = substr($0, first + 1, last - first - 1)
    split(substr($0, last + 2), f, " ")
    if (pid == 2 || f[2] == 2 || !(pid in uid)) next
    print pid "\t" f[2] "\t" f[1] "\t" (f[12] + f[13]) "\t" f[20] "\t" f[22] "\t" f[18] "\t" uid[pid] "\t" user[pid] "\t" name "\t" args[pid]
  }'
if [ -n "$1" ]; then
  printf '@@io'
  awk '$1 == "read_bytes:" || $1 == "write_bytes:" { printf "\t%s", $2 }' "/proc/$1/io" 2>/dev/null
  printf '\n@@cmd\t'
  tr '\0\t\n' '   ' <"/proc/$1/cmdline" 2>/dev/null | head -c 4000
  echo
fi
printf '@@sys\t%s\t%s\n' "$(cut -d' ' -f1 /proc/uptime)" "$(awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo)"
]=]

-- How many CPU readings the details view keeps for its graph.
local HISTORY = 60
-- Looking up an app's icon takes a few milliseconds, and a callback has 25: each update
-- starts lookups only while it has used less than this.
local ICON_MS = 6

local ticksPerSecond = 100
local pageSize = 4096
local myUid = nil
local watching = false
local reading = false
local lastReadMs = 0
local previous = {} -- by pid: { ticks, start }
local ending = {} -- by pid: { sentMs, start, force }
local denied = {} -- by pid: true when ending it needs an administrator
-- The process the details view shows: its pid, start time, CPU readings and last bytes read
-- and written, to work out the rates.
local detail = nil
local icons = {} -- app icon path by name, or false when there is none
local iconsWanted = {} -- names still to look up

-- Milliseconds between reads, from the settings.
local function interval()
  return math.max(tonumber(noctalia.getConfig("interval")) or 2000, 250)
end

local function adminInTerminal()
  return noctalia.getConfig("admin") == "terminal"
end

local function publish(processes, details)
  noctalia.state.set("processes.model", {
    ready = noctalia.commandExists("ps") and noctalia.commandExists("kill"),
    canElevate = adminInTerminal() or noctalia.commandExists("pkexec"),
    myUid = myUid,
    processes = processes,
    details = details,
  })
end

-- The details of the process the details view shows, from this read.
local function detailsOf(process, extra, uptime, memTotal, elapsed)
  if process == nil or process.start ~= detail.start then
    return { pid = detail.pid, gone = true }
  end
  table.insert(detail.history, math.min(process.cpu / 100, 1))
  while #detail.history > HISTORY do
    table.remove(detail.history, 1)
  end
  local io = extra.io
  local readRate, writeRate = nil, nil
  if io and detail.io then
    readRate = math.max(io[1] - detail.io[1], 0) / elapsed
    writeRate = math.max(io[2] - detail.io[2], 0) / elapsed
  end
  detail.io = io
  return {
    pid = detail.pid,
    history = table.clone(detail.history),
    threads = process.threads,
    seconds = uptime and math.max(uptime - (tonumber(process.start) or 0) / ticksPerSecond, 0) or nil,
    memoryShare = memTotal and memTotal > 0 and process.memory / memTotal or nil,
    read = io and io[1],
    written = io and io[2],
    readRate = readRate,
    writeRate = writeRate,
    command = extra.command ~= "" and extra.command or process.args,
  }
end

local function read()
  if reading then
    return
  end
  reading = true
  local nowMs = noctalia.nowMs()
  local elapsed = math.max((nowMs - lastReadMs) / 1000, 0.5)
  local detailPid = detail and tostring(detail.pid) or ""
  noctalia.runAsync({ "sh", "-c", READ, "process-manager", detailPid }, function(result)
    reading = false
    lastReadMs = nowMs
    local processes, seen, byPid = {}, {}, {}
    local extra, uptime, memTotal = {}, nil, nil
    for _, line in ipairs((result.stdout or ""):split("\n")) do
      local f = line:split("\t")
      local pid = tonumber(f[1])
      if pid and #f >= 11 then
        local ticks, start = tonumber(f[4]) or 0, f[5]
        local before = previous[pid]
        local cpu = 0
        if before and before.start == start then
          cpu = math.max(ticks - before.ticks, 0) / ticksPerSecond / elapsed * 100
        end
        seen[pid] = { ticks = ticks, start = start }
        local ask = ending[pid]
        if ask and ask.start ~= start then
          ending[pid] = nil
          ask = nil
        end
        -- The kernel cuts names at 15 characters; the program's file name is then used.
        local name, args = f[10], f[11]
        if #name == 15 then
          local program = (args:match("^(%S+)") or ""):match("([^/]+)$")
          if program and program:sub(1, 15) == name then
            name = program
          end
        end
        local process = {
          pid = pid,
          ppid = tonumber(f[2]),
          state = f[3],
          start = start,
          cpu = cpu,
          memory = (tonumber(f[6]) or 0) * pageSize,
          threads = tonumber(f[7]),
          uid = tonumber(f[8]),
          user = f[9],
          name = name,
          args = args,
          ending = ask ~= nil,
          stuck = ask ~= nil and nowMs - ask.sentMs >= STUCK_MS,
          denied = denied[pid] == true,
        }
        byPid[pid] = process
        table.insert(processes, process)
        if icons[name] == nil then
          iconsWanted[name] = true
        end
      elseif f[1] == "@@io" then
        extra.io = #f >= 3 and { tonumber(f[2]) or 0, tonumber(f[3]) or 0 } or nil
      elseif f[1] == "@@cmd" then
        extra.command = noctalia.string.trim(f[2] or "")
      elseif f[1] == "@@sys" then
        uptime = tonumber(f[2])
        memTotal = (tonumber(f[3]) or 0) * 1024
      end
    end
    -- Processes that are gone are forgotten.
    for pid in pairs(ending) do
      if seen[pid] == nil then
        ending[pid] = nil
        denied[pid] = nil
      end
    end
    previous = seen
    local details = nil
    if detail and tostring(detail.pid) == detailPid then
      details = detailsOf(byPid[detail.pid], extra, uptime, memTotal, elapsed)
    end
    publish(processes, details)
  end, 10000)
end

-- signal is "TERM" to ask a process to end, "KILL" to end it at once.
local function signal(pid, name, elevate)
  local before = previous[pid]
  ending[pid] = { sentMs = noctalia.nowMs(), start = before and before.start, force = name == "KILL" }
  if elevate and adminInTerminal() then
    -- The pid is a number, so the command needs no quoting.
    noctalia.runInTerminal(string.format("sudo kill -%s %d", name, pid))
    return
  end
  local argv = { "kill", "-" .. name, tostring(pid) }
  if elevate then
    argv = { "pkexec", "kill", "-" .. name, tostring(pid) }
  end
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 and not elevate and (result.stderr or ""):find("not permitted") then
      denied[pid] = true
      ending[pid] = nil
    end
    read()
  end, 60000)
end

noctalia.state.watch("processes.command", function(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "open" then
    watching = true
    read()
  elseif action == "close" then
    watching = false
    detail = nil
  elseif action == "details" then
    -- A pid opens the details view on that process; none closes it.
    local pid = command.pid
    local before = type(pid) == "number" and previous[pid] or nil
    detail = before and { pid = pid, start = before.start, history = {} } or nil
    read()
  elseif (action == "end" or action == "force") and type(command.pids) == "table" then
    for _, pid in ipairs(command.pids) do
      if type(pid) == "number" and pid > 1 then
        signal(pid, action == "force" and "KILL" or "TERM", command.elevate == true)
      end
    end
  end
end)


-- Looks up the icons of new app names, a few at a time, and publishes them once found.
local function lookUpIcons()
  local started = os.clock()
  local found = false
  for name in pairs(iconsWanted) do
    if (os.clock() - started) * 1000 >= ICON_MS then
      break
    end
    iconsWanted[name] = nil
    icons[name] = noctalia.appIconPath(name, 24) or false
    found = found or icons[name] ~= false
  end
  if found then
    noctalia.state.set("processes.icons", table.clone(icons))
  end
end

function update()
  if not watching then
    return
  end
  if noctalia.nowMs() - lastReadMs >= interval() then
    read()
  elseif next(iconsWanted) then
    lookUpIcons()
  end
end

function onConfigChanged()
  noctalia.setUpdateInterval(math.min(interval(), 500))
end

noctalia.runAsync({ "sh", "-c", "getconf CLK_TCK; getconf PAGESIZE; id -u" }, function(result)
  local values = {}
  for value in (result.stdout or ""):gmatch("%d+") do
    table.insert(values, tonumber(value))
  end
  ticksPerSecond = values[1] or ticksPerSecond
  pageSize = values[2] or pageSize
  myUid = values[3]
  publish({})
end)
noctalia.setUpdateInterval(math.min(interval(), 500))
