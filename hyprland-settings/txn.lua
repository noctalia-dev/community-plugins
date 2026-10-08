-- Save and revert for hyprland-settings.lua, one transaction at a time.
-- Plain Lua (not Luau): it also runs from the systemd watchdog, after the
-- plugin may be gone. Always called under the same lock:
--
--   flock -w 10 <data>/lock lua txn.lua begin  <data> <target> <id> <seconds> [adopt]
--   flock -w 10 <data>/lock lua txn.lua keep   <data> <id>
--   flock -w 10 <data>/lock lua txn.lua revert <data> <id>
--
-- The service writes <data>/candidate.<id>.lua first. "begin" reads it once,
-- under the lock, and works only with that copy (applied.lua).
--
-- Ownership: the plugin only replaces a file it wrote itself or a missing
-- one. The owned text is applied.lua while the last transaction is
-- "confirmed"; "begin" moves it to current.lua before applied.lua is reused.
-- So "keep" is a single write (the status) and cannot leave them apart. Taking over an existing
-- hand-written file needs "adopt"; its original is kept for good as
-- original-<id>.lua.
--
-- Time is seconds since boot (/proc/uptime) plus the boot id, so clock
-- changes do not move the deadline and a reboot counts as expired.
--
-- Exit codes: 0 ok, 1 wrong id/state or expired, 2 conflict (changed from
-- outside, left alone), 3 busy, 4 syntax error, 5 watchdog failed, 6 I/O,
-- 7 target not ours (needs adopt) or edited since the last save.

local cmd, data = arg[1], arg[2]

local function fail(code, message)
  io.stderr:write(message, "\n")
  os.exit(code)
end

-- nil only when the file does not exist; any other problem stops everything.
local function read(path)
  local f, err, errno = io.open(path, "rb")
  if f == nil then
    if errno == 2 then return nil end
    fail(6, "cannot open " .. path .. ": " .. tostring(err))
  end
  local text, rerr = f:read("a")
  local ok, cerr = f:close()
  if text == nil or not ok then fail(6, "cannot read " .. path .. ": " .. tostring(rerr or cerr)) end
  return text
end

-- Write beside the destination, then rename: readers never see half a file,
-- and a symlink is never replaced because `path` is already resolved.
local function write(path, text)
  local tmp = path .. ".hs-tmp"
  local f, err = io.open(tmp, "wb")
  if f == nil then return false, err end
  local ok, werr = f:write(text)
  local cok, cerr = f:close()
  if not ok or not cok then os.remove(tmp); return false, werr or cerr end
  local rok, rerr = os.rename(tmp, path)
  if not rok then os.remove(tmp); return false, rerr end
  return true
end

local function mustWrite(path, text, what)
  local ok, err = write(path, text)
  if not ok then fail(6, "cannot write " .. what .. ": " .. tostring(err)) end
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function clock()
  local uptime = tonumber((read("/proc/uptime") or ""):match("^([%d%.]+)"))
  local boot = (read("/proc/sys/kernel/random/boot_id") or ""):match("^(%S+)")
  if uptime == nil or boot == nil then fail(6, "cannot read uptime/boot id") end
  return uptime, boot
end

local function expired(t)
  local now, boot = clock()
  return boot ~= t.boot or tonumber(t.deadline) == nil or now >= tonumber(t.deadline)
end

local function loadTxn()
  local t = {}
  for key, value in (read(data .. "/txn") or ""):gmatch("([%w_]+)=([^\n]*)") do t[key] = value end
  return t
end

local function saveTxn(t)
  local lines = {}
  for _, key in ipairs({ "id", "target", "had_old", "status", "deadline", "boot" }) do
    if t[key] ~= nil then
      local value = tostring(t[key])
      if value:find("\n") then fail(6, "newline in " .. key) end
      lines[#lines + 1] = key .. "=" .. value
    end
  end
  mustWrite(data .. "/txn", table.concat(lines, "\n") .. "\n", "txn")
end

local function unit(id)
  return "hyprland-settings-revert-" .. id
end

local function stopTimer(id)
  os.execute("systemctl --user stop " .. shellQuote(unit(id) .. ".timer") .. " >/dev/null 2>&1")
end

-- "prepared" = journal written, file maybe not replaced yet; "pending" = replaced.
local function open(id)
  local t = loadTxn()
  if (t.status ~= "pending" and t.status ~= "prepared") or t.id ~= id then
    print(t.status or "none")
    os.exit(1)
  end
  return t
end

if cmd == "begin" then
  local target, id, seconds, adopt = arg[3], arg[4], tonumber(arg[5]), arg[6] == "adopt"
  if not (target and id and id:match("^[%w%-]+$") and seconds) then
    fail(1, "usage: begin <data> <target> <id> <seconds> [adopt]")
  end
  local last = loadTxn()
  if last.status == "pending" or last.status == "prepared" then fail(3, "busy") end

  local p = io.popen("readlink -f -- " .. shellQuote(target))
  local real = p and p:read("l")
  if p then p:close() end
  if real == nil or real == "" then fail(6, "cannot resolve " .. target) end

  local candidate = read(data .. "/candidate." .. id .. ".lua") or fail(6, "no candidate for " .. id)
  if last.status == "confirmed" then
    mustWrite(data .. "/current.lua", read(data .. "/applied.lua") or fail(6, "applied copy missing"), "current")
    last.status = "settled" -- current.lua now holds it; applied.lua is free
    saveTxn(last)
  end
  local current = read(data .. "/current.lua")
  mustWrite(data .. "/applied.lua", candidate, "applied copy")
  if not os.execute("luac -p " .. shellQuote(data .. "/applied.lua") .. " >&2") then fail(4, "syntax error") end
  os.remove(data .. "/candidate." .. id .. ".lua")

  local old = read(real)
  -- An empty file holds nothing to lose: the README tells users to create one.
  if old ~= nil and old ~= current and old:match("%S") then
    if not adopt then
      fail(7, current == nil and ("not written by this plugin: " .. real)
        or ("edited since the last save: " .. real))
    end
    mustWrite(data .. "/original-" .. id .. ".lua", old, "original")
  end
  if old ~= nil then mustWrite(data .. "/backup.lua", old, "backup") end

  local t = { id = id, target = real, had_old = old ~= nil and "1" or "0", status = "prepared" }
  saveTxn(t)

  -- Armed before the file changes: if anything dies from here on, the
  -- watchdog still reverts. It fires 5 s after the visible countdown.
  local script = arg[0]:sub(1, 1) == "/" and arg[0] or (os.getenv("PWD") .. "/" .. arg[0])
  local armed = os.execute(table.concat({
    "systemd-run --user --quiet --collect",
    "--unit=" .. shellQuote(unit(id)),
    "--on-active=" .. (seconds + 5),
    "flock -w 10", shellQuote(data .. "/lock"),
    "lua", shellQuote(script), "revert", shellQuote(data), shellQuote(id),
  }, " "))
  if not armed then
    t.status = "aborted"; saveTxn(t)
    fail(5, "watchdog not armed, nothing changed")
  end

  local ok, err = write(real, candidate)
  if not ok then
    t.status = "aborted"; saveTxn(t); stopTimer(id)
    fail(6, "cannot replace " .. real .. ": " .. tostring(err))
  end
  -- The countdown starts when the file is in place.
  local now, boot = clock()
  t.status, t.deadline, t.boot = "pending", string.format("%.2f", now + seconds), boot
  saveTxn(t)
  print(t.deadline)

elseif cmd == "keep" then
  local id = arg[3]
  local t = open(id)
  if t.status ~= "pending" or expired(t) then print("expired"); os.exit(1) end
  if read(t.target) ~= read(data .. "/applied.lua") then fail(2, "changed from outside: " .. t.target) end
  t.status = "confirmed"
  saveTxn(t)
  stopTimer(id)
  print("confirmed")

elseif cmd == "revert" then
  -- Idempotent: decides from the bytes on disk, so a crash halfway through
  -- (before or after replacing, before or after restoring) is safe to repeat.
  local id = arg[3]
  local t = open(id)
  local now = read(t.target)
  local backup = t.had_old == "1" and (read(data .. "/backup.lua") or fail(6, "backup missing")) or nil
  if now == backup then
    -- not replaced yet, or already restored
  elseif now == read(data .. "/applied.lua") then
    if backup ~= nil then
      local ok, err = write(t.target, backup)
      if not ok then fail(6, "cannot restore, backup kept: " .. tostring(err)) end
    else
      local ok, err = os.remove(t.target)
      if not ok then fail(6, "cannot remove: " .. tostring(err)) end
    end
  else
    if backup ~= nil then mustWrite(data .. "/backup-" .. id .. ".lua", backup, "conflict backup") end
    t.status = "conflict"; saveTxn(t); stopTimer(id)
    fail(2, "changed from outside, left alone: " .. t.target)
  end
  t.status = "reverted"
  saveTxn(t)
  stopTimer(id)
  print("reverted")

else
  fail(1, "usage: txn.lua begin|keep|revert <data> ...")
end
