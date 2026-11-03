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
      local dir = maildir .. "/" .. inbox .. "/new"
      local entries = noctalia.listDir(dir)
      if type(entries) ~= "table" then
         continue
      end
      if #entries < 1 then
         continue
      end
      s = s .. label .. string.format("=%d,", #entries)
      t = t .. inbox .. string.format("=%d\n", #entries)
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
