--!nonstrict
-- Accounts live in the Secret Service (gnome-keyring) through secret-tool: one item per
-- account, attributes { application, id }, the secret a JSON object with every field.
-- secret-tool prints attributes to stderr and secrets to stdout, so keeping the metadata
-- inside the secret is what lets one `search` read everything back unambiguously.
--
-- The loaded list is published to the plugin's shared state; every entry renders from it.

local M = {}

M.APP = "lycorisnd-twofa"
M.STATE_KEY = "accounts"
M.PANEL_ID = "lycorisnd/twofa:panel"

local function publish(value)
  noctalia.state.set(M.STATE_KEY, value)
end

function M.current()
  return noctalia.state.get(M.STATE_KEY) or { status = "loading", accounts = {} }
end

local function sortKey(a)
  return (a.issuer ~= "" and a.issuer or a.account):lower() .. "\0" .. a.account:lower()
end

local function parse(stdout: string)
  local accounts = {}
  for json in stdout:gmatch("\nsecret = ([^\n]*)") do
    local a = noctalia.json.decode(json)
    -- The id ends up in a file path and in secret-tool arguments: accept only our own
    -- hex ids, never something like "../x" from a hand-edited item.
    if
      type(a) == "table"
      and type(a.secret) == "string"
      and type(a.id) == "string"
      and a.id:match("^[0-9a-f]+$")
      and #a.id <= 32
    then
      a.issuer = type(a.issuer) == "string" and a.issuer or ""
      a.account = type(a.account) == "string" and a.account or ""
      a.digits = math.clamp(tonumber(a.digits) or 6, 6, 8)
      a.period = math.max(tonumber(a.period) or 30, 1)
      table.insert(accounts, a)
    end
  end
  table.sort(accounts, function(x, y)
    return sortKey(x) < sortKey(y)
  end)
  return accounts
end

-- Reload from the keyring (unlocking it if needed) and publish.
function M.reload(onDone)
  noctalia.runAsync({ "secret-tool", "search", "--all", "--unlock", "application", M.APP }, function(r)
    if r.exitCode ~= 0 and r.stdout == "" and r.stderr ~= "" then
      publish({ status = "error", error = noctalia.string.trim(r.stderr), accounts = M.current().accounts })
    else
      publish({ status = "ok", accounts = parse("\n" .. r.stdout) })
    end
    if onDone then
      onDone()
    end
  end, 30000)
end

local function newId(): string
  return string.format("%x%06x", noctalia.nowMs(), math.random(0, 0xFFFFFF))
end

local function label(a): string
  local name = a.issuer ~= "" and a.issuer or a.account
  if a.issuer ~= "" and a.account ~= "" then
    name ..= " (" .. a.account .. ")"
  end
  return "2FA: " .. name
end

-- The secret goes through a 0600 file in $XDG_RUNTIME_DIR (a per-user tmpfs) and stdin,
-- never argv, so it does not show up in the process list.
local STORE_SH = [[secret-tool store --label="$1" application "$2" id "$3" < "$4"; rc=$?; rm -f "$4"; exit $rc]]

local function storeOne(a, onDone)
  local dir = noctalia.getenv("XDG_RUNTIME_DIR")
  if not dir or dir == "" then
    onDone(false, "XDG_RUNTIME_DIR is not set")
    return
  end
  local record = {
    id = a.id or newId(),
    issuer = a.issuer,
    account = a.account,
    secret = a.secret,
    digits = a.digits or 6,
    period = a.period or 30,
  }
  local json = noctalia.json.encode(record)
  local tmp = ("%s/lycorisnd-twofa-%s"):format(dir, record.id)
  local ok, err = noctalia.writeFile(tmp, json)
  if not ok then
    onDone(false, err)
    return
  end
  local started = noctalia.runAsync({ "sh", "-c", STORE_SH, "sh", label(record), M.APP, record.id, tmp }, function(r)
    -- The script removes the file itself; this covers a timeout that killed it first.
    if noctalia.fileExists(tmp) then
      noctalia.removeFile(tmp)
    end
    onDone(r.exitCode == 0, noctalia.string.trim(r.stderr))
  end, 30000)
  if not started then
    noctalia.removeFile(tmp)
    onDone(false, "could not start secret-tool")
  end
end

-- Store new accounts, skipping ones whose secret is already present. Calls
-- onDone(added, duplicates, failed, firstError) after reloading.
function M.add(list, onDone)
  local known = {}
  for _, a in M.current().accounts do
    known[a.secret] = true
  end
  local queue, duplicates = {}, 0
  for _, a in list do
    if known[a.secret] then
      duplicates += 1
    else
      known[a.secret] = true
      table.insert(queue, a)
    end
  end
  local added, failed, firstErr = 0, 0, nil
  local function step(i)
    if i > #queue then
      M.reload(function()
        onDone(added, duplicates, failed, firstErr)
      end)
      return
    end
    storeOne(queue[i], function(ok, err)
      if ok then
        added += 1
      else
        failed += 1
        firstErr = firstErr or err
      end
      step(i + 1)
    end)
  end
  step(1)
end

function M.remove(id: string, onDone)
  noctalia.runAsync({ "secret-tool", "clear", "application", M.APP, "id", id }, function(r)
    M.reload(function()
      onDone(r.exitCode == 0)
    end)
  end, 30000)
end

-- Rename keeps the id: store the edited record over the old one (same attributes).
function M.rename(account, issuer: string, name: string, onDone)
  local edited = table.clone(account)
  edited.issuer, edited.account = issuer, name
  storeOne(edited, function(ok)
    M.reload(function()
      onDone(ok)
    end)
  end)
end

return M
