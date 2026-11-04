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

-- A maildir filename ends with a flags section such as ":2,S" or ":2,RS"
-- (legacy writers use ",2,S"). S in the flags means Seen; no flags section
-- means the message was never touched by a mail client.
function isSeen(name)
   local flags = name:match("[:,]2,([%a]*)$")
   return flags ~= nil and flags:find("S") ~= nil
end

function checkMail()
   local maildir = noctalia.getConfig("maildir")
   local inboxes = noctalia.getConfig("inboxes")
   if type(inboxes) ~= "table" then
      noctalia.notifyError("Maildir", "Invalid inboxes (expected a list of <inbox>:<label>)")
      return nil
   end
   local s = ""
   local t = ""
   for _, inbox_label in inboxes do
      local parts = string.split(inbox_label, ":")
      local inbox = parts[1]
      local label = parts[2]
      local root = maildir .. "/" .. inbox
      local count = countDir(root .. "/new")
      local cur = noctalia.listDir(root .. "/cur")
      if type(cur) == "table" then
         for _, name in cur do
            if not isSeen(name) then
               count += 1
            end
         end
      end
      if count < 1 then
         continue
      end
      s = s .. label .. string.format("=%d,", count)
      t = t .. inbox .. string.format("=%d\n", count)
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
