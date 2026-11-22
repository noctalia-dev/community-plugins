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

-- The kernel counts CPU time in ticks of 1/100 s for every program (USER_HZ).
local TICKS_PER_SECOND = 100
-- How many CPU readings the details view keeps for its graph.
local HISTORY = 60
-- Looking up an app's icon takes a few milliseconds, and a callback has 25: each update
-- starts lookups only while it has used less than this.
local ICON_MS = 6

local pageSize = 4096
local myUid = nil
local userNames = {} -- uid -> name, from /etc/passwd
local scan = nil -- the read under way: { pids, next, flying, retry, processes, seen, byPid, nowMs, elapsed }
local watching = false
local lastReadMs = 0
local previous = {} -- by pid: { ticks, start, uid, args, name }, from the last read
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
    ready = noctalia.commandExists("kill"),
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
    seconds = uptime and math.max(uptime - (tonumber(process.start) or 0) / TICKS_PER_SECOND, 0) or nil,
    memoryShare = memTotal and memTotal > 0 and process.memory / memTotal or nil,
    read = io and io[1],
    written = io and io[2],
    readRate = readRate,
    writeRate = writeRate,
    command = extra.command ~= "" and extra.command or process.args,
  }
end

-- One process from its stat line, and from its status and command line, which only a new
-- process needs. nil when it is gone or is a kernel thread (pid 2 and its children). The name
-- in stat sits in parentheses and may hold spaces and parentheses, so the fields after it are
-- counted from its last ")".
local function parseStat(pid, stat)
  local name, rest = (stat or ""):match("^%d+ %((.*)%) (.*)$")
  if rest == nil then
    return nil
  end
  local f = string.split(rest, " ")
  -- f[1] is field 3 of stat: the state. The others follow in stat's order.
  local ppid = tonumber(f[2])
  if pid == 2 or ppid == 2 then
    return nil
  end
  return {
    pid = pid,
    ppid = ppid,
    state = f[1],
    start = f[20],
    ticks = (tonumber(f[12]) or 0) + (tonumber(f[13]) or 0),
    memory = (tonumber(f[22]) or 0) * pageSize,
    threads = tonumber(f[18]),
    name = name,
  }
end

-- Fills in the owner and command line of a new process, from its status and cmdline files.
local function describe(process, status, cmdline)
  local uid = tonumber(((status or ""):match("\nUid:%s*(%d+)")))
  local args = noctalia.string.trim(((cmdline or ""):gsub("[%z\t\n]", " ")):sub(1, 200))
  process.uid, process.args = uid, args
  -- The kernel cuts names at 15 characters; the program's file name is then used.
  if #process.name == 15 then
    local program = (args:match("^(%S+)") or ""):match("([^/]+)$")
    if program and program:sub(1, 15) == process.name then
      process.name = program
    end
  end
end

-- The details view's extras: bytes read and written, and the whole command line.
local function readExtras(pid)
  local io = noctalia.readFile(`/proc/{pid}/io`)
  local readBytes, written = (io or ""):match("read_bytes:%s*(%d+)"), (io or ""):match("write_bytes:%s*(%d+)")
  local command = (noctalia.readFile(`/proc/{pid}/cmdline`) or ""):gsub("[%z\t\n]", " "):sub(1, 4000)
  return {
    io = readBytes and { tonumber(readBytes), tonumber(written) or 0 } or nil,
    command = noctalia.string.trim(command),
  }
end

-- Publishes a finished read.
local function finishScan()
  local nowMs, elapsed = scan.nowMs, scan.elapsed
  local processes, seen, byPid = scan.processes, scan.seen, scan.byPid
  scan = nil
  lastReadMs = nowMs
  -- Processes that are gone are forgotten.
  for pid in pairs(ending) do
    if seen[pid] == nil then
      ending[pid] = nil
      denied[pid] = nil
    end
  end
  previous = seen
  local details = nil
  if detail then
    local uptime = tonumber(((noctalia.readFile("/proc/uptime") or ""):match("^(%S+)")))
    local memTotal = (tonumber(((noctalia.readFile("/proc/meminfo") or ""):match("MemTotal:%s*(%d+)"))) or 0) * 1024
    details = detailsOf(byPid[detail.pid], readExtras(detail.pid), uptime, memTotal, elapsed)
  end
  publish(processes, details)
end

-- Adds one process to the read under way.
local function add(process)
  local before = previous[process.pid]
  if before and before.start == process.start then
    process.cpu = math.max(process.ticks - before.ticks, 0) / TICKS_PER_SECOND / scan.elapsed * 100
  else
    process.cpu = 0
  end
  local pid = process.pid
  scan.seen[pid] = { ticks = process.ticks, start = process.start, uid = process.uid, args = process.args, name = process.name }
  local ask = ending[pid]
  if ask and ask.start ~= process.start then
    ending[pid] = nil
    ask = nil
  end
  process.ticks = nil
  process.user = process.uid and (userNames[process.uid] or tostring(process.uid)) or ""
  process.ending = ask ~= nil
  process.stuck = ask ~= nil and scan.nowMs - ask.sentMs >= STUCK_MS
  process.denied = denied[pid] == true
  scan.byPid[pid] = process
  table.insert(scan.processes, process)
  if icons[process.name] == nil then
    iconsWanted[process.name] = true
  end
end

-- Noctalia reads only a few files at once off the main thread, so a read keeps POOL files
-- in flight and starts the next as each one comes in.
local POOL = 4

-- Asks for a file; when Noctalia is busy, the next update tick asks again.
local function ask(path, onResult)
  if not noctalia.readFileAsync(path, onResult) then
    table.insert(scan.retry, { path, onResult })
  end
end

-- Reads one process, then calls done. A new process also needs its status and command line.
local function readOne(pid, done)
  local current = scan
  ask(`/proc/{pid}/stat`, function(stat)
    local process = scan == current and parseStat(pid, stat) or nil
    local before = process and previous[pid]
    if process and before and before.start == process.start then
      -- A process keeps its owner and command line, so they are read once.
      process.uid, process.args, process.name = before.uid, before.args, before.name
      add(process)
    elseif process then
      ask(`/proc/{pid}/status`, function(status)
        ask(`/proc/{pid}/cmdline`, function(cmdline)
          if scan == current then
            describe(process, status, cmdline)
            add(process)
          end
          done(current)
        end)
      end)
      return
    end
    done(current)
  end)
end

-- Starts reads until POOL are in flight; publishes once every process is in.
local function pump()
  while scan.flying < POOL and scan.next <= #scan.pids do
    local pid = scan.pids[scan.next]
    scan.next += 1
    scan.flying += 1
    readOne(pid, function(current)
      if scan ~= current then
        return
      end
      scan.flying -= 1
      if scan.flying == 0 and scan.next > #scan.pids then
        finishScan()
      else
        pump()
      end
    end)
  end
end

-- Reads every process in /proc. The files are read off the main thread; each answer is one
-- short callback.
local function read()
  if scan then
    return
  end
  local nowMs = noctalia.nowMs()
  local pids = {}
  for _, name in ipairs(noctalia.listDir("/proc") or {}) do
    local pid = tonumber(name)
    if pid then
      table.insert(pids, pid)
    end
  end
  scan = {
    pids = pids,
    next = 1,
    flying = 0,
    retry = {},
    processes = {},
    seen = {},
    byPid = {},
    nowMs = nowMs,
    elapsed = math.max((nowMs - lastReadMs) / 1000, 0.5),
  }
  if #pids == 0 then
    finishScan()
  else
    pump()
  end
end

-- signal is "TERM" to ask a process to end, "KILL" to end it at once. The process must still
-- be the one the panel showed: the same start time, read again just before, so a pid that
-- ended and was given to another process meanwhile gets nothing.
local function signal(pid, name, elevate)
  local before = previous[pid]
  local now = parseStat(pid, (noctalia.readFile(`/proc/{pid}/stat`)))
  if before == nil or now == nil or now.start ~= before.start then
    return
  end
  ending[pid] = { sentMs = noctalia.nowMs(), start = before.start, force = name == "KILL" }
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
  if scan then
    local retry = scan.retry
    scan.retry = {}
    for _, entry in ipairs(retry) do
      ask(entry[1], entry[2])
    end
  end
  if not watching then
    return
  end
  if noctalia.nowMs() - lastReadMs >= interval() then
    read()
  elseif scan == nil and next(iconsWanted) then
    lookUpIcons()
  end
end

function onConfigChanged()
  noctalia.setUpdateInterval(math.min(interval(), 500))
end

-- This user's id, and the page size: the kernel gives memory in pages, and this process's
-- own memory in both pages and kB, which gives the page size.
noctalia.readFileAsync("/proc/self/status", function(status)
  myUid = tonumber(((status or ""):match("\nUid:%s*(%d+)")))
  local rssKb = tonumber(((status or ""):match("\nVmRSS:%s*(%d+)")))
  local pages = tonumber(((noctalia.readFile("/proc/self/statm") or ""):match("^%d+ (%d+)")))
  if rssKb and pages and pages > 0 then
    -- A power of two, as page sizes are, near the ratio of the two.
    pageSize = 2 ^ math.floor(math.log(rssKb * 1024 / pages, 2) + 0.5)
  end
  publish({})
end)
noctalia.readFileAsync("/etc/passwd", function(text)
  for line in (text or ""):gmatch("[^\n]+") do
    local name, uid = line:match("^([^:]+):[^:]*:(%d+):")
    if name then
      userNames[tonumber(uid)] = name
    end
  end
end)
noctalia.setUpdateInterval(math.min(interval(), 500))
