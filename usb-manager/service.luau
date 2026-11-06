--!nonstrict
-- USB Manager service — the [[service]] entry.
--
-- Everything the plugin shows is read straight from the kernel and the udev
-- database, without spawning anything:
--   /sys/block/*               disks, partitions, sizes, removable flag, I/O
--   /run/udev/data/b<maj:min>  bus, vendor/model, filesystem type and label
--   /proc/self/mountinfo       what is mounted where (matched by maj:min)
--   /proc/swaps                swap partitions, never offered for removal
--   sysfs of the USB device    link speed and USB version
-- The scan runs every few seconds and publishes a snapshot only when
-- something changed. Actions need privileges the shell does not have, so they
-- go through udisks2 (udisksctl, plus gdbus for Drive.Eject, which udisksctl
-- lacks), exactly like a file manager does.
--
-- State channel:
--   usbm.snapshot  (service → entries) JSON: drives, pending actions, time
--   usbm.cmd       (entries → service) JSON: { n, action, dev, … }

local snapshot = nil
local lastEncoded = nil
local lastCmdNonce = nil
local firstScan = true
local known = {} -- drive name -> { title, mounted } at the last full scan
local lastWritten = {} -- drive name -> sectors written at the previous scan
local released = {} -- drive name -> true while a safe removal released it
local pending = {} -- device path -> action in progress
local scanning = false

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function notifyEnabled()
  return noctalia.getConfig("notifications") ~= false
end

local function notify(body)
  if notifyEnabled() then
    noctalia.notify(tr("title"), body)
  end
end

local function notifyError(body)
  -- errors are always shown: the user asked for the action
  noctalia.notifyError(tr("title"), body)
end

-- ── Small readers ────────────────────────────────────────────────────────────

local function read(path)
  local content = noctalia.readFile(path)
  if content == nil then
    return nil
  end
  return noctalia.string.trim(content)
end

local function readNumber(path)
  return tonumber(read(path) or "") or 0
end

-- udev escapes unsafe bytes as \xNN in the *_ENC properties
local function decodeUdev(value)
  return (value:gsub("\\x(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- mountinfo escapes space, tab, newline and backslash as octal
local function decodeMount(value)
  return (value:gsub("\\(%d%d%d)", function(oct)
    return string.char(tonumber(oct, 8))
  end))
end

local function udevProps(majmin)
  local props = {}
  local content = noctalia.readFile(`/run/udev/data/b{majmin}`)
  if content == nil then
    return props
  end
  for line in content:gmatch("[^\n]+") do
    local key, value = line:match("^E:([%w_]+)=(.*)$")
    if key then
      props[key] = value
    end
  end
  return props
end

local function prettyName(value)
  local text = (value or ""):gsub("_", " ")
  text = text:gsub("%s+", " ")
  return noctalia.string.trim(text)
end

-- ── Mounts and swaps ─────────────────────────────────────────────────────────

-- maj:min -> list of { path, fsType, options }
local function readMounts(content)
  local mounts = {}
  for line in content:gmatch("[^\n]+") do
    local majmin, mountPoint, rest = line:match("^%d+ %d+ (%d+:%d+) %S+ (%S+) (.*)$")
    if majmin then
      local fsType = rest:match(" %- (%S+) ")
      local options = rest:match("^(%S+)")
      mounts[majmin] = mounts[majmin] or {}
      table.insert(mounts[majmin], {
        path = decodeMount(mountPoint),
        fsType = fsType or "",
        readOnly = options ~= nil and options:match("^ro[,]?") ~= nil,
      })
    end
  end
  return mounts
end

local function readSwaps()
  local swaps = {}
  local content = noctalia.readFile("/proc/swaps") or ""
  for line in content:gmatch("[^\n]+") do
    local dev = line:match("^/dev/(%S+)")
    if dev then
      swaps[dev] = true
    end
  end
  return swaps
end

-- Mount points that belong to the running system: a drive holding one of
-- these is never listed, whatever bus it sits on.
local function isSystemMount(path)
  return path == "/" or path == "/home" or path == "/usr" or path == "/var"
    or path:match("^/boot") ~= nil or path:match("^/efi") ~= nil
end

-- ── Devices ──────────────────────────────────────────────────────────────────

-- The USB device the disk hangs off, found by walking up the sysfs tree from
-- the SCSI/MMC device until a directory has idVendor. ".." after a sysfs
-- symlink is resolved by the kernel on the physical path, so no readlink is
-- needed.
local function usbInfo(name)
  local base = `/sys/block/{name}/device`
  local path = base
  for _ = 1, 8 do
    path ..= "/.."
    if noctalia.fileExists(path .. "/idVendor") then
      local speed = readNumber(path .. "/speed")
      local version = read(path .. "/version") or ""
      return { speed = speed, version = noctalia.string.trim(version) }
    end
  end
  return nil
end

local function busOf(name, props)
  if props.ID_BUS == "usb" or props.ID_USB_DRIVER ~= nil
    or (props.ID_PATH or ""):find("-usb-", 1, true) then
    return "usb"
  end
  if name:match("^mmcblk") then
    -- only SD cards: eMMC is the laptop's own storage
    local kind = read(`/sys/block/{name}/device/type`)
    if kind == "SD" then
      return "sd"
    end
    return nil
  end
  if name:match("^sr%d") then
    return "optical"
  end
  return nil
end

local function isCandidateName(name)
  return not (name:match("^loop") or name:match("^ram") or name:match("^zram")
    or name:match("^dm%-") or name:match("^md") or name:match("^nbd")
    or name:match("boot%d+$") or name:match("rpmb$"))
end

-- A filesystem (or LUKS container) living on `name`, which is a partition or
-- a whole disk without a partition table.
local function volumeOf(name, sysPath, mounts, swaps)
  local majmin = read(sysPath .. "/dev")
  if majmin == nil then
    return nil
  end
  local props = udevProps(majmin)
  local fsType = props.ID_FS_TYPE or ""
  local usage = props.ID_FS_USAGE or ""
  if fsType == "" or swaps[name] or fsType == "swap" then
    return nil
  end
  if usage ~= "filesystem" and usage ~= "crypto" then
    return nil
  end

  local volume = {
    name = name,
    dev = `/dev/{name}`,
    label = props.ID_FS_LABEL_ENC and decodeUdev(props.ID_FS_LABEL_ENC) or (props.ID_FS_LABEL or ""),
    fsType = fsType,
    size = readNumber(sysPath .. "/size") * 512,
    luks = fsType == "crypto_LUKS",
    unlocked = false,
    mounts = mounts[majmin] or {},
  }

  if volume.luks then
    -- an unlocked container has the dm device mapping it as a holder
    for _, holder in noctalia.listDir(sysPath .. "/holders") or {} do
      if holder:match("^dm%-") then
        local clearPath = `/sys/block/{holder}`
        local clearMajmin = read(clearPath .. "/dev")
        local clearProps = clearMajmin and udevProps(clearMajmin) or {}
        volume.unlocked = true
        volume.clear = {
          name = holder,
          dev = `/dev/{holder}`,
          label = clearProps.ID_FS_LABEL_ENC and decodeUdev(clearProps.ID_FS_LABEL_ENC) or (clearProps.ID_FS_LABEL or ""),
          fsType = clearProps.ID_FS_TYPE or "",
          mounts = clearMajmin and mounts[clearMajmin] or {},
        }
        break
      end
    end
  end

  -- the mounted filesystem is the volume itself, or the cleartext device
  local mounted = volume.luks and volume.clear and volume.clear.mounts or volume.mounts
  if #mounted > 0 then
    volume.mountPoint = mounted[1].path
    volume.readOnly = mounted[1].readOnly
  end
  return volume
end

local function scanDrive(name, mounts, swaps)
  local sysPath = `/sys/block/{name}`
  local majmin = read(sysPath .. "/dev")
  if majmin == nil then
    return nil
  end
  local props = udevProps(majmin)
  local bus = busOf(name, props)
  local removable = readNumber(sysPath .. "/removable") == 1
  if bus == nil and not removable then
    return nil
  end
  if props.UDISKS_IGNORE == "1" then
    return nil
  end

  local size = readNumber(sysPath .. "/size") * 512
  local drive = {
    name = name,
    dev = `/dev/{name}`,
    bus = bus or "other",
    vendor = prettyName(props.ID_VENDOR or read(sysPath .. "/device/vendor")),
    model = prettyName(props.ID_MODEL or read(sysPath .. "/device/model")),
    serial = props.ID_SERIAL_SHORT or "",
    size = size,
    removableMedia = removable,
    noMedia = size == 0,
    readOnly = readNumber(sysPath .. "/ro") == 1,
    volumes = {},
  }
  if bus == "usb" then
    drive.usb = usbInfo(name)
  elseif bus == "sd" then
    -- SD cards report their product name in the MMC device, no vendor string
    drive.vendor = ""
    drive.model = prettyName(read(sysPath .. "/device/name"))
  end
  -- power off cuts the USB port; media ejection is for card readers and
  -- optical drives, which keep their device when the medium is out
  drive.canPowerOff = bus == "usb"
  drive.canEject = removable and not drive.noMedia

  -- partitions are the sub-directories named after the disk (sdc1, mmcblk0p1)
  local entries = noctalia.listDir(sysPath) or {}
  table.sort(entries)
  local system = false
  for _, entry in entries do
    if entry:sub(1, #name) == name and noctalia.fileExists(`{sysPath}/{entry}/partition`) then
      if swaps[entry] then
        system = true
      end
      local volume = volumeOf(entry, `{sysPath}/{entry}`, mounts, swaps)
      if volume then
        table.insert(drive.volumes, volume)
      end
    end
  end
  if #drive.volumes == 0 and not drive.noMedia then
    -- a filesystem on the whole disk (superfloppy layout, optical media)
    local volume = volumeOf(name, sysPath, mounts, swaps)
    if volume then
      table.insert(drive.volumes, volume)
    end
  end

  for _, volume in drive.volumes do
    if volume.mountPoint and isSystemMount(volume.mountPoint) then
      system = true
    end
  end
  if system then
    return nil
  end

  -- ATA bridges often repeat the vendor at the start of the model
  local modelHasVendor = drive.vendor ~= ""
    and drive.model:lower():sub(1, #drive.vendor) == drive.vendor:lower()
  drive.title = (drive.vendor ~= "" and not modelHasVendor) and `{drive.vendor} {drive.model}` or drive.model
  if noctalia.string.trim(drive.title) == "" then
    drive.title = drive.dev
  end
  return drive
end

-- ── Scan and publish ─────────────────────────────────────────────────────────

local function publish()
  local encoded = noctalia.json.encode({
    drives = snapshot and snapshot.drives or {},
    pending = pending,
  })
  if encoded ~= lastEncoded then
    lastEncoded = encoded
    noctalia.state.set("usbm.snapshot", encoded)
  end
end

local runAction -- forward declaration, used by auto-mount

local function autoMount(drive)
  if noctalia.getConfig("auto_mount") ~= true then
    return
  end
  for _, volume in drive.volumes do
    if not volume.luks and not volume.mountPoint then
      runAction({ action = "mount", dev = volume.dev })
    end
  end
end

-- Disks that are not removable never become removable: they are classified
-- once per device instance. diskseq is a counter the kernel bumps for every
-- new block device, so a name reused by the next drive is not mistaken for
-- the previous one.
local classified = {} -- name -> { seq, candidate }

local function classify(name)
  local sysPath = `/sys/block/{name}`
  local seq = read(sysPath .. "/diskseq") or ""
  local cached = classified[name]
  if cached and cached.seq == seq then
    return cached.candidate
  end
  local majmin = read(sysPath .. "/dev")
  if majmin == nil then
    return false
  end
  -- udev writes its database entry a moment after the kernel creates the
  -- device: until then nothing is cached, so the next tick looks again
  if not noctalia.fileExists(`/run/udev/data/b{majmin}`) then
    return false
  end
  local props = udevProps(majmin)
  local candidate = props.UDISKS_IGNORE ~= "1"
    and (busOf(name, props) ~= nil or readNumber(sysPath .. "/removable") == 1)
  classified[name] = { seq = seq, candidate = candidate }
  return candidate
end

-- What a full scan depends on, read cheaply: the device list, the mount
-- table, swaps, and for removable disks their size (media changes), their
-- partitions and holders (LUKS), and the udev entries (labels, formats).
local function signature(names, mountinfo)
  local parts = { table.concat(names, " "), mountinfo, noctalia.readFile("/proc/swaps") or "" }
  for _, name in names do
    if classified[name] and classified[name].candidate then
      local sysPath = `/sys/block/{name}`
      table.insert(parts, name)
      table.insert(parts, classified[name].seq)
      table.insert(parts, read(sysPath .. "/size") or "")
      local diskInfo = noctalia.fileInfo(`/run/udev/data/b{read(sysPath .. "/dev") or ""}`)
      table.insert(parts, diskInfo and tostring(diskInfo.mtime) or "-")
      -- an unlocked LUKS container adds a dm-N device, which already shows
      -- in the device list; holders are listed for partitions anyway
      local entries = noctalia.listDir(sysPath) or {}
      table.sort(entries)
      for _, entry in entries do
        if entry:sub(1, #name) == name then
          table.insert(parts, entry)
          local majmin = read(`{sysPath}/{entry}/dev`)
          if majmin then
            local info = noctalia.fileInfo(`/run/udev/data/b{majmin}`)
            table.insert(parts, info and tostring(info.mtime) or "-")
          end
          for _, holder in noctalia.listDir(`{sysPath}/{entry}/holders`) or {} do
            table.insert(parts, holder)
          end
        end
      end
    end
  end
  return table.concat(parts, "\n")
end

local lastSignature = nil

local function fullScan(names, mountinfo)
  local mounts = readMounts(mountinfo)
  local swaps = readSwaps()
  local drives = {}
  local present = {}
  for _, name in names do
    if classified[name] and classified[name].candidate then
      local drive = scanDrive(name, mounts, swaps)
      if drive then
        table.insert(drives, drive)
        present[name] = drive
      end
    end
  end

  -- Arrivals and removals are not notified: the widget shows them, and the
  -- desktop usually announces USB devices already. The one removal worth a
  -- notification is a drive pulled while a volume was still mounted.
  for name, drive in present do
    local mounted = false
    for _, volume in drive.volumes do
      if volume.mountPoint then
        mounted = true
      end
    end
    if known[name] == nil and not firstScan then
      autoMount(drive)
    end
    known[name] = { title = drive.title, mounted = mounted }
    if not mounted then
      released[name] = nil -- seen released: a later remount counts again
    end
  end
  for name, last in known do
    if present[name] == nil then
      known[name] = nil
      lastWritten[name] = nil
      local wasReleased = released[name]
      released[name] = nil
      if last.mounted and not wasReleased then
        notifyError(tr("notify.unsafe", { name = last.title }))
      end
    end
  end
  firstScan = false
  snapshot = { drives = drives }
end

-- What changes without any event: write activity (requests in flight or
-- sectors written since the last tick) and the free space of mounted
-- volumes, which Noctalia samples itself.
local function refreshLive()
  for _, drive in snapshot and snapshot.drives or {} do
    local stat = read(`/sys/block/{drive.name}/stat`) or ""
    local fields = {}
    for value in stat:gmatch("%d+") do
      table.insert(fields, tonumber(value))
    end
    local written = fields[7] or 0
    local inFlight = fields[9] or 0
    drive.busy = inFlight > 0 or (lastWritten[drive.name] ~= nil and written ~= lastWritten[drive.name])
    lastWritten[drive.name] = written

    for _, volume in drive.volumes do
      volume.total, volume.free, volume.used = nil, nil, nil
      if volume.mountPoint then
        local stats = noctalia.diskStats(volume.mountPoint)
        if stats and stats.totalBytes and stats.totalBytes > 0 then
          volume.total = stats.totalBytes
          volume.free = stats.availableBytes or stats.freeBytes or 0
          volume.used = stats.totalBytes - (stats.freeBytes or 0)
        end
      end
    end
  end
end

-- One tick: a handful of small sysfs/procfs reads. The expensive part (udev
-- database, partitions, mounts) only runs when the signature changed, or
-- when `force` asks for it after an action.
local function scan(force)
  if scanning then
    return
  end
  scanning = true
  local names = noctalia.listDir("/sys/block") or {}
  table.sort(names)
  local candidates = {}
  for _, name in names do
    if isCandidateName(name) and classify(name) then
      table.insert(candidates, name)
    end
  end
  for name in classified do
    if not table.find(names, name) then
      classified[name] = nil
    end
  end
  local mountinfo = noctalia.readFile("/proc/self/mountinfo") or ""
  local sig = signature(names, mountinfo)
  if force or sig ~= lastSignature then
    lastSignature = sig
    fullScan(candidates, mountinfo)
  end
  refreshLive()
  publish()
  scanning = false
end

-- ── Actions (udisks2) ────────────────────────────────────────────────────────

-- Device paths come from the snapshot, but they arrive through the state
-- channel, so only plain kernel names are accepted before they reach argv.
local function validDev(dev)
  return type(dev) == "string" and dev:match("^/dev/[%w%-]+$") ~= nil
end

local function findDrive(dev)
  for _, drive in snapshot and snapshot.drives or {} do
    if drive.dev == dev then
      return drive
    end
  end
  return nil
end

local function findVolume(dev)
  for _, drive in snapshot and snapshot.drives or {} do
    for _, volume in drive.volumes do
      if volume.dev == dev or (volume.clear and volume.clear.dev == dev) then
        return volume, drive
      end
    end
  end
  return nil
end

-- "Error unmounting /dev/sdc1: GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy:
-- Error unmounting /dev/sdc1: target is busy" → a short, translated reason
local function cleanError(stderr, fallback)
  local text = noctalia.string.trim(stderr or "")
  if text:find("DeviceBusy", 1, true) or text:find("target is busy", 1, true) then
    return tr("error.busy")
  end
  if text:find("NotAuthorized", 1, true) then
    return tr("error.not-authorized")
  end
  if text:find("No key available", 1, true) or text:find("passphrase", 1, true) then
    return tr("error.passphrase")
  end
  local reason = text:match("GDBus%.Error:[%w%.]+: (.+)$") or text
  reason = reason:gsub("^Error [%w ]+ /dev/[%w%-]+: ", "")
  reason = noctalia.string.trim((reason:gsub("\n.*", "")))
  return reason ~= "" and reason or fallback
end

local function setPending(dev, action)
  pending[dev] = action
  publish()
end

local function clearPending(dev)
  pending[dev] = nil
  scan(true)
end

-- Runs argv lists one after the other, stopping at the first failure.
local function runSteps(steps, done)
  local index = 0
  local function nextStep()
    index += 1
    local step = steps[index]
    if step == nil then
      done(true, nil)
      return
    end
    local launched = noctalia.runAsync(step, function(result)
      if result.exitCode ~= 0 or result.timedOut then
        done(false, result.timedOut and tr("error.timeout") or result.stderr)
      else
        nextStep()
      end
    end)
    if not launched then
      done(false, tr("error.no-udisks"))
    end
  end
  nextStep()
end

-- Steps that leave every filesystem of the drive unmounted and every LUKS
-- container locked.
local function releaseSteps(drive)
  local steps = {}
  for _, volume in drive.volumes do
    if volume.luks then
      if volume.unlocked then
        if volume.mountPoint and volume.clear then
          table.insert(steps, { "udisksctl", "unmount", "-b", volume.clear.dev })
        end
        table.insert(steps, { "udisksctl", "lock", "-b", volume.dev })
      end
    elseif volume.mountPoint then
      table.insert(steps, { "udisksctl", "unmount", "-b", volume.dev })
    end
  end
  return steps
end

local function openFolder(path)
  local cmd = noctalia.string.trim(noctalia.getConfig("file_manager") or "")
  if cmd == "" then
    noctalia.runAsync({ "xdg-open", path })
  else
    local quoted = path:gsub("'", "'\\''")
    noctalia.runAsync(`{cmd} '{quoted}'`)
  end
end

local function mountVolume(dev, title)
  setPending(dev, "mount")
  noctalia.runAsync({ "udisksctl", "mount", "-b", dev }, function(result)
    if result.exitCode ~= 0 then
      notifyError(tr("error.mount", { name = title, reason = cleanError(result.stderr, dev) }))
    else
      local path = (result.stdout or ""):match(" at (.-)%.?%s*$")
      if path and noctalia.getConfig("open_after_mount") == true then
        openFolder(path)
      end
    end
    clearPending(dev)
  end)
end

local function unlockVolume(dev, passphrase, title)
  if type(passphrase) ~= "string" or passphrase == "" then
    return
  end
  local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
  if runtime == nil or runtime == "" then
    notifyError(tr("error.unlock", { name = title, reason = "XDG_RUNTIME_DIR" }))
    return
  end
  -- The passphrase goes through a key file on the runtime tmpfs (owner-only,
  -- removed as soon as udisksctl returns) instead of argv, where any process
  -- could read it.
  local keyFile = `{runtime}/usb-manager-key-{noctalia.nowMs()}-{math.random(100000, 999999)}`
  local ok = noctalia.writeFile(keyFile, passphrase)
  if not ok then
    notifyError(tr("error.unlock", { name = title, reason = keyFile }))
    return
  end
  setPending(dev, "unlock")
  local launched = noctalia.runAsync({ "udisksctl", "unlock", "-b", dev, "--key-file", keyFile }, function(result)
    noctalia.removeFile(keyFile)
    if result.exitCode ~= 0 then
      notifyError(tr("error.unlock", { name = title, reason = cleanError(result.stderr, dev) }))
      clearPending(dev)
      return
    end
    local clear = (result.stdout or ""):match("as (/dev/[%w%-]+)")
    pending[dev] = nil
    if clear and validDev(clear) then
      mountVolume(clear, title)
    else
      scan(true)
    end
  end)
  if not launched then
    noctalia.removeFile(keyFile)
    clearPending(dev)
    notifyError(tr("error.no-udisks"))
  end
end

-- Power off for USB drives (the port goes dark, the drive can be pulled),
-- media eject for card readers and optical drives, otherwise just release.
local function safeRemove(drive, done)
  local steps = releaseSteps(drive)
  local how = drive.canPowerOff and "power-off" or (drive.canEject and "eject" or "release")
  if how == "power-off" then
    table.insert(steps, { "udisksctl", "power-off", "-b", drive.dev })
  end
  setPending(drive.dev, "remove")
  -- Power-off makes the drive vanish before the next full scan sees it
  -- unmounted: remember the release so it is not reported as unsafe.
  released[drive.name] = true
  runSteps(steps, function(ok, err)
    if not ok then
      released[drive.name] = nil
      notifyError(tr("error.remove", { name = drive.title, reason = cleanError(err, drive.dev) }))
      clearPending(drive.dev)
      if done then
        done(false)
      end
      return
    end
    local function finish(success, reason)
      if success then
        notify(tr("notify.safe", { name = drive.title }))
      else
        notifyError(tr("error.remove", { name = drive.title, reason = reason }))
      end
      clearPending(drive.dev)
      if done then
        done(success)
      end
    end
    if how ~= "eject" then
      finish(true)
      return
    end
    -- udisksctl has no eject verb: find the drive object, then call
    -- Drive.Eject over the system bus
    noctalia.runAsync({ "udisksctl", "info", "-b", drive.dev }, function(info)
      local object = (info.stdout or ""):match("Drive:%s+'([^']+)'")
      if info.exitCode ~= 0 or object == nil or not object:match("^/org/freedesktop/UDisks2/drives/[%w_]+$") then
        finish(false, cleanError(info.stderr, drive.dev))
        return
      end
      noctalia.runAsync({
        "gdbus", "call", "--system",
        "--dest", "org.freedesktop.UDisks2",
        "--object-path", object,
        "--method", "org.freedesktop.UDisks2.Drive.Eject", "{}",
      }, function(result)
        finish(result.exitCode == 0, cleanError(result.stderr, drive.dev))
      end)
    end)
  end)
end

function runAction(cmd)
  local action = cmd.action
  if action == "refresh" then
    scan(true)
    return
  end
  if action == "remove_all" then
    local drives = {}
    for _, drive in snapshot and snapshot.drives or {} do
      table.insert(drives, drive)
    end
    if #drives == 0 then
      return
    end
    local index = 0
    local function nextDrive()
      index += 1
      if drives[index] then
        safeRemove(drives[index], nextDrive)
      end
    end
    nextDrive()
    return
  end
  if action == "mount_all" then
    for _, drive in snapshot and snapshot.drives or {} do
      for _, volume in drive.volumes do
        if not volume.luks and not volume.mountPoint and pending[volume.dev] == nil then
          mountVolume(volume.dev, drive.title)
        end
      end
    end
    return
  end

  if not validDev(cmd.dev) or pending[cmd.dev] then
    return
  end
  if action == "remove" then
    local drive = findDrive(cmd.dev)
    if drive then
      safeRemove(drive)
    end
    return
  end

  local volume, drive = findVolume(cmd.dev)
  if volume == nil then
    return
  end
  if action == "mount" then
    mountVolume(cmd.dev, drive.title)
  elseif action == "unmount" then
    setPending(cmd.dev, "unmount")
    noctalia.runAsync({ "udisksctl", "unmount", "-b", cmd.dev }, function(result)
      if result.exitCode ~= 0 then
        notifyError(tr("error.unmount", { name = drive.title, reason = cleanError(result.stderr, cmd.dev) }))
      end
      clearPending(cmd.dev)
    end)
  elseif action == "unlock" then
    unlockVolume(cmd.dev, cmd.passphrase, drive.title)
  elseif action == "lock" then
    local steps = {}
    if volume.mountPoint and volume.clear then
      table.insert(steps, { "udisksctl", "unmount", "-b", volume.clear.dev })
    end
    table.insert(steps, { "udisksctl", "lock", "-b", volume.dev })
    setPending(cmd.dev, "lock")
    runSteps(steps, function(ok, err)
      if not ok then
        notifyError(tr("error.lock", { name = drive.title, reason = cleanError(err, cmd.dev) }))
      end
      clearPending(cmd.dev)
    end)
  elseif action == "open" then
    if volume.mountPoint then
      openFolder(volume.mountPoint)
    end
  end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

noctalia.state.watch("usbm.cmd", function(encoded)
  if encoded == nil then
    return
  end
  local cmd = noctalia.json.decode(encoded)
  if type(cmd) ~= "table" or cmd.n == lastCmdNonce then
    return
  end
  lastCmdNonce = cmd.n
  if cmd.passphrase ~= nil then
    -- the channel keeps its last value: do not leave the passphrase in it
    noctalia.state.set("usbm.cmd", noctalia.json.encode({ n = cmd.n, action = "consumed" }))
  end
  runAction(cmd)
end)

function update()
  local seconds = math.clamp(tonumber(noctalia.getConfig("scan_interval")) or 2, 1, 30)
  noctalia.setUpdateInterval(seconds * 1000)
  scan()
end

function onConfigChanged()
  scan(true)
end

-- noctalia msg plugin rylos/usb-manager:service all <event> [/dev/…]
local IPC_EVENTS = {
  refresh = false,
  mount_all = false,
  remove_all = false,
  mount = true,
  unmount = true,
  lock = true,
  open = true,
  remove = true,
}

function onIpc(event, payload)
  local needsDev = IPC_EVENTS[event]
  if needsDev == nil then
    noctalia.log(`unknown IPC event '{event}'`)
    return
  end
  if needsDev then
    -- accept "sdc1" as well as "/dev/sdc1"
    local dev = noctalia.string.trim(payload or "")
    if dev ~= "" and dev:sub(1, 5) ~= "/dev/" then
      dev = "/dev/" .. dev
    end
    runAction({ action = event, dev = dev })
  else
    runAction({ action = event })
  end
end
