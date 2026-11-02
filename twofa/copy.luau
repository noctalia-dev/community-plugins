--!nonstrict
-- Copies an account's current code and says how long it stays valid.
--
-- wl-copy --sensitive offers the x-kde-passwordManagerHint type, which keeps the code out of
-- Noctalia's (and other managers') persistent clipboard history; noctalia.copyToClipboard
-- offers a single type and cannot carry that hint, so it is only the fallback.

local totp = require("./totp.luau")

local M = {}

local function copyText(text: string)
  if noctalia.commandExists("wl-copy") then
    -- wl-copy forks a server that outlives the call; detach its stdio so the async run
    -- completes at once instead of waiting on (and timing out) the inherited pipes.
    local sh = [[printf %s "$1" | setsid -f wl-copy --sensitive >/dev/null 2>&1]]
    noctalia.runAsync({ "sh", "-c", sh, "sh", text }, function(r)
      if r.exitCode ~= 0 then
        noctalia.copyToClipboard(text, "text/plain")
      end
    end, 5000)
  else
    noctalia.copyToClipboard(text, "text/plain")
  end
end

function M.code(a)
  local tr = noctalia.tr
  local code, left = totp.code(a, os.time())
  if not code then
    noctalia.notifyError(tr("notify.title"), tr("notify.bad_secret"))
    return
  end
  copyText(code)
  local name = a.issuer ~= "" and a.issuer or a.account
  noctalia.notify(tr("notify.title"), tr("notify.copied", { name = name, n = left }))
end

-- After importing from the clipboard: the selection still holds the otpauth link (a
-- secret), so replace it with nothing.
function M.clear()
  if noctalia.commandExists("wl-copy") then
    noctalia.runAsync({ "sh", "-c", "exec setsid -f wl-copy --clear </dev/null >/dev/null 2>&1" }, nil, 5000)
  end
end

return M
