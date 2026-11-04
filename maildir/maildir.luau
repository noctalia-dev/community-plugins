function update()
   noctalia.setUpdateInterval(noctalia.getConfig("update_interval") * 1000)
   local container = barWidget.isVertical() and ui.column or ui.row

   local ms = checkMail()
   local weight = "bold"
   if ms == nil then
      ms = {text = noctalia.getConfig("nomail"), tooltip = noctalia.tr("title")}
      weight = "normal"
   end
   barWidget.setTooltip(ms.tooltip)
   barWidget.render(container({ gap = 6, align = "center" }, {
                          ui.label({ text = ms.text, fontWeight = weight }),
   }))
end

-- Number of entries in a directory (0 when the directory is missing or unlistable).
function countDir(dir)
   local entries = noctalia.listDir(dir)
   if type(entries) ~= "table" then
      return 0
   end
   return #entries
end

-- Directory mtime (nil when the directory is missing). Used as a change
-- detector: unread counts are only recomputed when a directory changed.
function dirMtime(dir)
   local info = noctalia.fileInfo(dir)
   if type(info) ~= "table" then
      return nil
   end
   return info.mtime
end

-- A maildir filename ends with a flags section such as ":2,S" or ":2,RS"
-- (legacy writers use ",2,S"). S in the flags means Seen; no flags section
-- means the message was never touched by a mail client.
function isSeen(name)
   local flags = name:match("[:,]2,([%a]*)$")
   return flags ~= nil and flags:find("S") ~= nil
end

-- Noctalia interrupts any callback that exceeds its per-call CPU budget,
-- and disables a widget after repeated overruns. Scanning a whole cur/
-- directory in one update overruns that budget on large maildirs, so each
-- update inspects at most CHUNK names and the rest waits for the next one.
-- A name check costs on the order of a microsecond; 1024 keeps an update
-- around a millisecond even on slow hardware.
local CHUNK = 1024

-- Cached per-inbox unread counts, reused while the directory mtimes hold.
-- An idle maildir therefore costs two stat calls per update instead of a
-- full rescan. root is rechecked so a changed setting drops stale caches.
local cached = {}

-- One in-flight cur/ scan at a time: names is the listDir snapshot the
-- scan started from, cursor is the next name to inspect, and mtime is the
-- directory mtime at snapshot time. When the scan reaches the end it only
-- commits its count if the mtime still matches, so a directory modified
-- mid-scan is scanned again rather than reporting stale counts.
local scan = nil

-- Advance the in-flight scan by one chunk. Returns nothing; the committed
-- count is visible to checkMail through the cache.
function advanceScan()
   if scan == nil then
      return
   end
   local last = math.min(scan.cursor + CHUNK, #scan.names)
   local unread = scan.unread
   for i = scan.cursor + 1, last do
      if not isSeen(scan.names[i]) then
         unread += 1
      end
   end
   scan.cursor = last
   scan.unread = unread
   if last < #scan.names then
      return
   end
   local entry = cached[scan.inbox]
   if entry ~= nil and entry.root == scan.root and dirMtime(scan.root .. "/cur") == scan.mtime then
      entry.curUnread = unread
      entry.curMtime = scan.mtime
   end
   scan = nil
end

function checkMail()
   local maildir = noctalia.getConfig("maildir")
   local inboxes = noctalia.getConfig("inboxes")
   if type(inboxes) ~= "table" then
      noctalia.notifyError("Maildir", "Invalid inboxes (expected a list of <inbox>:<label>)")
      return nil
   end
   advanceScan()
   local s = ""
   local t = ""
   local pending = nil
   for _, inbox_label in inboxes do
      local parts = string.split(inbox_label, ":")
      local inbox = parts[1]
      local label = parts[2]
      local root = maildir .. "/" .. inbox
      local entry = cached[inbox]
      if entry == nil or entry.root ~= root then
         entry = { root = root, newCount = 0, newMtime = nil, curUnread = 0, curMtime = nil }
         cached[inbox] = entry
      end
      local newMtime = dirMtime(root .. "/new")
      if newMtime ~= entry.newMtime then
         entry.newCount = countDir(root .. "/new")
         entry.newMtime = newMtime
      end
      local curMtime = dirMtime(root .. "/cur")
      if curMtime ~= entry.curMtime and pending == nil then
         -- cur/ changed and needs a rescan. Only one scan runs at a time,
         -- so the per-update cost stays bounded no matter how many
         -- inboxes went stale at once.
         pending = { inbox = inbox, root = root, mtime = curMtime }
      end
      local count = entry.newCount + entry.curUnread
      if count < 1 then
         continue
      end
      s = s .. label .. string.format("=%d,", count)
      t = t .. inbox .. string.format("=%d\n", count)
   end
   if scan == nil and pending ~= nil then
      -- Start the next scan. Taking the listDir snapshot is itself costly
      -- on huge directories, so the update that starts a scan does no
      -- name matching.
      local cur = noctalia.listDir(pending.root .. "/cur")
      if type(cur) == "table" then
         scan = {
            inbox = pending.inbox,
            root = pending.root,
            names = cur,
            cursor = 0,
            unread = 0,
            mtime = pending.mtime,
         }
      else
         local entry = cached[pending.inbox]
         entry.curUnread = 0
         entry.curMtime = pending.mtime
      end
   end
   if #s < 1 then
      return nil
   end
   return {text = s:sub(1,-2), tooltip = t:sub(1,-2)}
end

function onClickCallback(result)
   if result.exitCode == 0 then
      return
   end
   local cmd = noctalia.getConfig("click_command")
   local msg = "click_command \"" .. cmd .. "\" failed\nexitCode = " .. result.exitCode
   if result.stdout ~= "" then
      msg = msg .. "\nStdout: " .. result.stdout
   end
   if result.stderr ~= "" then
      msg = msg .. "\nStderr: " .. result.stderr
   end
   noctalia.notifyError("Maildir", msg)
end

function onClick()
   local cmd = noctalia.getConfig("click_command")
   if #cmd < 1 then
      noctalia.notify("Maildir", "click_command option not set")
      return
   end
   local base_cmd = cmd:match("%S+")
   if not noctalia.commandExists(base_cmd) then
      noctalia.notifyError("Maildir", "command not found: " .. base_cmd)
      return
   end
   noctalia.runAsync(cmd, onClickCallback)
end
