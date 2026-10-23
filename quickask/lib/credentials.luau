--!nonstrict
-- Never persist, log, or forward subprocess output to the UI.
local M = {}

function M.lookup(callback)
  if not noctalia.commandExists("secret-tool") then
    callback(nil, noctalia.tr("credentials.missing-command"))
    return
  end

  local started = noctalia.runAsync({
    "secret-tool", "lookup", "application", "quickask", "provider", "opencode-go",
  }, function(result)
    local raw = result.stdout
    result.stdout = nil
    result.stderr = nil
    if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then
      raw = nil
      callback(nil, noctalia.tr("credentials.unreadable"))
      return
    end
    local key = type(raw) == "string" and raw:match("^%s*(.-)%s*$") or ""
    raw = nil
    if key == "" then
      callback(nil, noctalia.tr("credentials.missing"))
    elseif key:find("[%c%s]") then
      key = nil
      callback(nil, noctalia.tr("credentials.invalid"))
    else
      callback(key, nil)
      key = nil
    end
  end)
  if not started then
    callback(nil, noctalia.tr("credentials.startup"))
  end
end

return M
