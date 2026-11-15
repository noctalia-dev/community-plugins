--!nonstrict
-- Process Manager service: while the panel is open, reads every process as often as the
-- interval setting says, works out each one's CPU use since the last read, and ends
-- processes when asked: first politely, then by force when one does not stop. Another
-- user's process is ended with pkexec, or with sudo in a terminal, as the admin setting says.
--
-- Publishes "processes.model" and takes commands on "processes.command".

-- A process that still runs this long after End is shown as not responding.
local STUCK_MS = 3000

-- One line per process, without kernel threads (pid 2 and its children):
-- pid, ppid, state, CPU ticks, start time, resident pages, uid, user, name, command line,
-- separated by tabs. The name in /proc/<pid>/stat sits in parentheses and may hold spaces
-- and parentheses, so the fields after it are counted from its last ")".
local READ = [=[
ps -eo pid=,uid=,user=,args= | awk '{ pid = $1; uid = $2; user = $3; $1 = $2 = $3 = ""; sub(/^ +/, ""); print pid "\t" uid "\t" user "\t" $0 }' >"$1"
cat /proc/[0-9]*/stat 2>/dev/null | awk -v owners="$1" '
  BEGIN { FS = "\t"; while ((getline line < owners) > 0) { split(line, o, "\t"); uid[o[1]] = o[2]; user[o[1]] = o[3]; args[o[1]] = o[4] } FS = " " }
  {
    first = index($0, "("); last = 0
    for (i = length($0); i > first; i--) if (substr($0, i, 1) == ")") { last = i; break }
    pid = substr($0, 1, first - 2); name = substr($0, first + 1, last - first - 1)
    split(substr($0, last + 2), f, " ")
    if (pid == 2 || f[2] == 2 || !(pid in uid)) next
    print pid "\t" f[2] "\t" f[1] "\t" (f[12] + f[13]) "\t" f[20] "\t" f[22] "\t" uid[pid] "\t" user[pid] "\t" name "\t" args[pid]
  }'
rm -f "$1"
]=]

local dataDir = noctalia.pluginDataDir() or "/tmp"
local tempFile = dataDir .. "/owners.tsv"
local ticksPerSecond = 100
local pageSize = 4096
local myUid = nil
local watching = false
local reading = false
local lastReadMs = 0
local previous = {} -- by pid: { ticks, start }
local ending = {} -- by pid: { sentMs, start, force }
local denied = {} -- by pid: true when ending it needs an administrator

-- Milliseconds between reads, from the settings.
local function interval()
  return math.max(tonumber(noctalia.getConfig("interval")) or 2000, 250)
end

local function adminInTerminal()
  return noctalia.getConfig("admin") == "terminal"
end

local function publish(processes)
  noctalia.state.set("processes.model", {
    ready = noctalia.commandExists("ps") and noctalia.commandExists("kill"),
    canElevate = adminInTerminal() or noctalia.commandExists("pkexec"),
    myUid = myUid,
    processes = processes,
  })
end

local function read()
  if reading then
    return
  end
  reading = true
  local nowMs = noctalia.nowMs()
  local elapsed = math.max((nowMs - lastReadMs) / 1000, 0.5)
  noctalia.runAsync({ "sh", "-c", READ, "process-manager", tempFile }, function(result)
    reading = false
    lastReadMs = nowMs
    local processes, seen = {}, {}
    for _, line in ipairs((result.stdout or ""):split("\n")) do
      local f = line:split("\t")
      local pid = tonumber(f[1])
      if pid and #f >= 10 then
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
        local name, args = f[9], f[10]
        if #name == 15 then
          local program = (args:match("^(%S+)") or ""):match("([^/]+)$")
          if program and program:sub(1, 15) == name then
            name = program
          end
        end
        table.insert(processes, {
          pid = pid,
          ppid = tonumber(f[2]),
          state = f[3],
          cpu = cpu,
          memory = (tonumber(f[6]) or 0) * pageSize,
          uid = tonumber(f[7]),
          user = f[8],
          name = name,
          args = args,
          ending = ask ~= nil,
          stuck = ask ~= nil and nowMs - ask.sentMs >= STUCK_MS,
          denied = denied[pid] == true,
        })
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
    publish(processes)
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
  elseif (action == "end" or action == "force") and type(command.pids) == "table" then
    for _, pid in ipairs(command.pids) do
      if type(pid) == "number" and pid > 1 then
        signal(pid, action == "force" and "KILL" or "TERM", command.elevate == true)
      end
    end
  end
end)


function update()
  if watching and noctalia.nowMs() - lastReadMs >= interval() then
    read()
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
noctalia.mkdirAll(dataDir)
noctalia.setUpdateInterval(math.min(interval(), 500))
