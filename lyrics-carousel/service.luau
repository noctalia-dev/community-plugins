--!nonstrict
-- Event bridge between Noctalia and the external lyrics window.
--
-- Noctalia does not expose a direct theme callback to plugin entries. The
-- global `colors_changed` hook dispatches an IPC event here after the Kitty
-- template has been written; this service forwards it to the Python process
-- as SIGUSR2. There is no polling and no need to reopen the window.

local function runControl(command)
  local dir = noctalia.pluginDir()
  if dir == nil or dir == "" then
    noctalia.log("lyrics-carousel: plugin directory unavailable")
    return
  end
  noctalia.runAsync(
    { "python3", dir .. "/bin/window-control.py", command },
    function(result)
      if result == nil or result.exitCode ~= 0 then
        local detail = ""
        if type(result) == "table" then
          detail = tostring(result.stderr or result.stdout or "")
        end
        noctalia.log(
          "lyrics-carousel: window-control " .. command .. " failed"
            .. (detail ~= "" and (": " .. detail) or "")
        )
      end
    end
  )
end

function onIpc(event, _payload)
  if event == "colors-changed" or event == "theme-applied" then
    runControl("theme")
  elseif event == "reload-window" then
    runControl("reload")
  elseif event == "stop-window" then
    runControl("stop")
  end
end
