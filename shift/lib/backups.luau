--!nonstrict
-- Backups of the data files (spec §10.1, §10.3, D28): every data file, copied as is into
-- one directory per backup.
--
--   backups/daily/2026-10-24/      the first tick of each workday, 30 most recent kept
--   backups/monthly/2026-10/       the first daily backup of each month, 12 most recent
--   backups/migration/2026-10-24-schema-1/   before a schema migration, never pruned
--
-- The host can remove files but not directories, so the retention reuses the oldest
-- backup directory for the new one instead of deleting it. A backup is written into
-- `<name>.tmp` and renamed when complete: a directory without the suffix is always a
-- whole backup, and a leftover `.tmp` (Noctalia stopped meanwhile) is reused next time.

local Types = require("./types.luau")

type Host = Types.Host

export type Backups = {
  -- Takes the backup of a workday unless it exists, and the month's on its first one.
  daily: (date: string) -> boolean,
  -- Full backup before migrating files of schema `schema`.
  beforeMigration: (date: string, schema: number) -> boolean,
  -- Backed-up copies of a data file, newest first: daily backups, then monthly ones.
  -- `label` names the backup (its date or month).
  copies: (name: string) -> { { label: string, path: string } },
}

local Backups = {}

Backups.KEEP = { daily = 30, monthly = 12 }

local TMP = ".tmp"

local function isTmp(name: string): boolean
  return string.sub(name, -#TMP) == TMP
end

-- `dir` is the plugin data dir.
function Backups.new(host: Host, dir: string): Backups
  local root = dir .. "/backups"

  local function log(message: string, err: string?)
    host.log(string.format("backups: %s: %s", message, tostring(err)))
  end

  -- Entries of a directory, sorted; none when it is missing.
  local function list(path: string): { string }
    local names = host.listDir(path)
    local sorted = table.clone(names or {})
    table.sort(sorted)
    return sorted
  end

  -- The data files, relative to `dir`: state, balance and every yearly ledger.
  local function dataFiles(): { string }
    local names = {}
    for _, name in { "state.json", "balance.json" } do
      if host.fileExists(dir .. "/" .. name) then
        table.insert(names, name)
      end
    end
    for _, name in list(dir .. "/ledger") do
      if string.match(name, "^%d%d%d%d%.json$") then
        table.insert(names, "ledger/" .. name)
      end
    end
    return names
  end

  -- A `.tmp` directory to write the backup `name` into: a leftover one, the oldest
  -- backup once `keep` are kept, or a new one.
  local function slot(base: string, name: string, keep: number?): string?
    local target = base .. "/" .. name .. TMP
    if host.fileExists(target) then
      return target
    end
    local done, leftover = {}, nil
    for _, entry in list(base) do
      if isTmp(entry) then
        leftover = leftover or entry
      else
        table.insert(done, entry)
      end
    end
    local reused = leftover or (keep and #done >= keep and done[1])
    if reused then
      local ok, err = host.renameFile(base .. "/" .. reused, target)
      if not ok then
        log("cannot reuse " .. base .. "/" .. reused, err)
        return nil
      end
      return target
    end
    local ok, err = host.mkdirAll(target)
    if not ok then
      log("cannot create " .. target, err)
      return nil
    end
    return target
  end

  -- Copies the data files into `base/name`, through its `.tmp` directory.
  local function take(base: string, name: string, keep: number?): boolean
    local target = slot(base, name, keep)
    if not target then
      return false
    end
    host.mkdirAll(target .. "/ledger")
    local names, kept = dataFiles(), {}
    for _, file in names do
      kept[file] = true
      local text, readErr = host.readFile(dir .. "/" .. file)
      local ok, err = text ~= nil, readErr
      if text then
        ok, err = host.writeFile(target .. "/" .. file, text)
      end
      if not ok then
        log("cannot copy " .. file, err)
        return false
      end
    end
    -- What a reused directory held and today's data does not have.
    for _, sub in { "", "/ledger" } do
      for _, entry in list(target .. sub) do
        local file = if sub == "" then entry else "ledger/" .. entry
        if file ~= "ledger" and not kept[file] then
          host.removeFile(target .. "/" .. file)
        end
      end
    end
    local ok, err = host.renameFile(target, base .. "/" .. name)
    if not ok then
      log("cannot complete " .. base .. "/" .. name, err)
    end
    return ok
  end

  local backups = {}

  function backups.daily(date: string): boolean
    for _, kind in { "daily", "monthly" } do
      host.mkdirAll(root .. "/" .. kind)
    end
    if not host.fileExists(root .. "/daily/" .. date) and not take(root .. "/daily", date, Backups.KEEP.daily) then
      return false
    end
    local month = string.sub(date, 1, 7)
    if not host.fileExists(root .. "/monthly/" .. month) then
      return take(root .. "/monthly", month, Backups.KEEP.monthly)
    end
    return true
  end

  function backups.beforeMigration(date: string, schema: number): boolean
    local name = string.format("%s-schema-%d", date, schema)
    host.mkdirAll(root .. "/migration")
    -- Taken earlier today, before a migration that did not complete: still the original.
    return host.fileExists(root .. "/migration/" .. name) or take(root .. "/migration", name, nil)
  end

  function backups.copies(name: string): { { label: string, path: string } }
    local found = {}
    for _, kind in { "daily", "monthly" } do
      local entries = list(root .. "/" .. kind)
      for i = #entries, 1, -1 do
        local path = string.format("%s/%s/%s/%s", root, kind, entries[i], name)
        if not isTmp(entries[i]) and host.fileExists(path) then
          table.insert(found, { label = entries[i], path = path })
        end
      end
    end
    return found
  end

  return backups
end

return Backups
