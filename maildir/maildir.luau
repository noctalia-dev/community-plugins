-- Noctalia interrupts any callback that exceeds its per-call CPU budget
-- (25 ms of worker-thread CPU time) and disables the widget after repeated
-- overruns. A single noctalia.listDir() on a large cur/ already spends that
-- budget, because it materialises every filename into a Lua table inside
-- the callback, so no amount of chunking the later matching can help. This
-- widget therefore never walks directories in Lua: an external find/grep
-- pipeline counts new/ and unread cur/ entries in a separate process, and
-- the callback only parses two integers per inbox. Every callback costs
-- microseconds regardless of mailbox size.

-- Cached per-inbox counts, written by the counter callback and read by
-- every render. Keyed by inbox path segment, so changed settings simply
-- use new keys and stale ones are ignored.
local counts = {}

-- True while the external counter is running, so a slow counter never
-- makes an update tick pile a second copy onto it.
local counting = false

-- Notify at most once per failure streak; reset on the first success.
local failureNotified = false

-- A cold or network-mounted mailbox can take a while to walk; without an
-- explicit timeout runAsync would kill the counter after its 5 s default.
local COUNT_TIMEOUT_MS = 30000

-- A maildir filename ends with a flags section such as ":2,S" or ":2,RS"
-- (legacy writers use ",2,S"). A name is seen when its trailing
-- letters-only flags section contains S; a name with no flags section was
-- never touched by a mail client and counts as unread. The ERE below is
-- the shell twin of that rule and must stay equivalent to it.
local SEEN_ERE = "[:,]2,[A-Za-z]*S[A-Za-z]*$"

function shellQuote(s)
   return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Mirrors the host's path resolution for filesystem calls: "~" expands to
-- $HOME, absolute paths are used as-is, anything else is plugin-relative.
function resolveMaildir(path)
   path = tostring(path)
   if path:sub(1, 1) == "~" then
      return noctalia.expandPath(path)
   end
   if path:sub(1, 1) == "/" then
      return path
   end
   return noctalia.pluginDir() .. "/" .. path
end

function countCurEnabled()
   local v = noctalia.getConfig("count_cur")
   if v == nil then
      return true
   end
   return v == true or v == "true"
end

-- Reads and validates the settings; nil when inboxes is not a list.
function readConfig()
   local maildir = noctalia.getConfig("maildir")
   local inboxes = noctalia.getConfig("inboxes")
   if type(inboxes) ~= "table" then
      return nil
   end
   local list = {}
   for _, inbox_label in inboxes do
      local parts = string.split(tostring(inbox_label), ":")
      local inbox = parts[1]
      local label = parts[2] or parts[1]
      if inbox ~= nil and inbox ~= "" then
         table.insert(list, { inbox = inbox, label = label })
      end
   end
   return {
      maildir = resolveMaildir(maildir),
      inboxes = list,
      countCur = countCurEnabled(),
   }
end

-- Builds one shell command printing a "<new> <unread-cur>" line per inbox,
-- in order. Paths from settings are single-quoted; find and grep do the
-- walking out of process, and a missing directory simply yields 0. find -L
-- follows symlinks, so a symlinked maildir counts the same as a real one.
function buildCommand(cfg)
   local lines = {}
   for _, e in cfg.inboxes do
      local root = shellQuote(cfg.maildir .. "/" .. e.inbox)
      local newExpr = "$(find -L " .. root .. "/new -maxdepth 1 -type f 2>/dev/null | wc -l)"
      local curExpr = "0"
      if cfg.countCur then
         curExpr = "$(find -L " .. root .. "/cur -maxdepth 1 -type f 2>/dev/null | grep -cvE " .. shellQuote(SEEN_ERE) .. ")"
      end
      table.insert(lines, "echo " .. newExpr .. " " .. curExpr)
   end
   return table.concat(lines, "; ")
end

function render()
   local container = barWidget.isVertical() and ui.column or ui.row
   local countCur = countCurEnabled()
   local cfg = readConfig()
   local inboxes = cfg ~= nil and cfg.inboxes or {}
   local s = ""
   local t = ""
   for _, e in inboxes do
      local c = counts[e.inbox]
      local count = 0
      if c ~= nil then
         count = c.newCount + (countCur and c.curUnread or 0)
      end
      if count < 1 then
         continue
      end
      s = s .. e.label .. string.format("=%d,", count)
      t = t .. e.inbox .. string.format("=%d\n", count)
   end
   if #s < 1 then
      barWidget.setTooltip(noctalia.tr("title"))
      barWidget.render(container({ gap = 6, align = "center" }, {
                             ui.label({ text = tostring(noctalia.getConfig("nomail")), fontWeight = "normal" }),
      }))
      return
   end
   barWidget.setTooltip(t:sub(1, -2))
   barWidget.render(container({ gap = 6, align = "center" }, {
                         ui.label({ text = s:sub(1, -2), fontWeight = "bold" }),
   }))
end

-- Parses the counter output ("<new> <unread>" per line, same order as the
-- inboxes baked into the command) into the cache, then re-renders so fresh
-- counts appear without waiting for the next tick.
function onCountDone(inboxes, result)
   counting = false
   if type(result) ~= "table" or result.exitCode ~= 0 then
      if not failureNotified then
         failureNotified = true
         local detail = "exitCode = " .. tostring(type(result) == "table" and result.exitCode or "?")
         if type(result) == "table" and result.stderr ~= nil and result.stderr ~= "" then
            detail = detail .. "\nStderr: " .. result.stderr
         end
         noctalia.notifyError("Maildir", "unread counter failed\n" .. detail)
      end
      return
   end
   failureNotified = false
   local lines = string.split(result.stdout or "", "\n")
   for i, e in inboxes do
      local newCount, curUnread = string.match(tostring(lines[i]), "^(%d+)%s+(%d+)")
      if newCount ~= nil then
         counts[e.inbox] = { newCount = tonumber(newCount), curUnread = tonumber(curUnread) }
      end
   end
   render()
end

function update()
   noctalia.setUpdateInterval(noctalia.getConfig("update_interval") * 1000)
   if not counting then
      local cfg = readConfig()
      if cfg == nil then
         noctalia.notifyError("Maildir", "Invalid inboxes (expected a list of <inbox>:<label>)")
      elseif #cfg.inboxes > 0 then
         counting = true
         local ok = noctalia.runAsync(buildCommand(cfg), function(result)
            onCountDone(cfg.inboxes, result)
         end, COUNT_TIMEOUT_MS)
         if not ok then
            counting = false
            if not failureNotified then
               failureNotified = true
               noctalia.notifyError("Maildir", "could not start the unread counter")
            end
         end
      end
   end
   render()
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
