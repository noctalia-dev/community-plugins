--!nonstrict
-- Loads the accounts from the keyring at startup and on `reload`, and publishes them to
-- the shared state the widget, panel and launcher render from. Also runs the screen QR
-- scan: the panel closes itself first (so it does not cover the code) and hands the scan
-- to this long-lived entry, which reports the result as a notification.

local store = require("./store.luau")
local totp = require("./totp.luau")

local tr = noctalia.tr

-- slurp selects the area, grim captures it into the per-user tmpfs, zbarimg decodes every
-- QR code in it; the image (which holds the secrets) is removed whatever happens.
local SCAN_SH = [[
f="$1"
trap 'rm -f "$f"' EXIT
umask 077
area=$(slurp) || exit 2
grim -g "$area" "$f" || exit 3
zbarimg -q --raw "$f"
]]

local function importText(text, emptyKey)
  local list, skipped, err = totp.parseAny(text)
  if #list == 0 then
    noctalia.notifyError(tr("notify.title"), tr(text == "" and emptyKey or ("import." .. (err or "nothing_found"))))
    return
  end
  store.add(list, function(added, duplicates, failed, storeErr)
    if failed > 0 then
      noctalia.notifyError(tr("notify.title"), tr("import.store_failed", { error = storeErr or "?" }))
    else
      noctalia.notify(tr("notify.title"), tr("import.result", { added = added, duplicates = duplicates, skipped = skipped }))
    end
  end)
end

local function scan()
  local dir = noctalia.getenv("XDG_RUNTIME_DIR")
  if not dir or dir == "" then
    noctalia.notifyError(tr("notify.title"), "XDG_RUNTIME_DIR is not set")
    return
  end
  local shot = ("%s/lycorisnd-twofa-qr-%d.png"):format(dir, math.floor(noctalia.nowMs()))
  noctalia.runAsync({ "sh", "-c", SCAN_SH, "sh", shot }, function(r)
    -- The trap removes the capture; this covers a timeout that killed the script first.
    if noctalia.fileExists(shot) then
      noctalia.removeFile(shot)
    end
    if r.exitCode == 2 then
      return -- selection cancelled
    end
    importText(r.stdout, "import.no_qr")
  end, 120000)
end

-- A file of otpauth:// lines (GNOME Authenticator / FreeOTP+ plain-text export) or
-- Google Authenticator otpauth-migration:// links.
local function importFile(path)
  local text, err = noctalia.readFile(noctalia.expandPath(path or ""))
  if not text then
    noctalia.notifyError(tr("notify.title"), tr("import.read_failed", { error = err or "?" }))
    return
  end
  importText(text, "import.nothing_found")
end

-- The panel bumps "scan" to a fresh timestamp; a value left over from before a reload
-- must not start a scan on its own.
local lastScan = noctalia.state.get("scan")
noctalia.state.watch("scan", function(value)
  if value and value ~= lastScan then
    lastScan = value
    scan()
  end
end)

function onIpc(event, payload)
  if event == "reload" then
    store.reload()
  elseif event == "scan" then
    scan()
  elseif event == "import" then
    importFile(payload)
  else
    noctalia.log(("unknown command '%s'"):format(tostring(event)))
  end
end

store.reload()
