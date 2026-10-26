--!nonstrict
-- Persistence in the plugin data dir (spec §10): state.json, balance.json and one ledger
-- per year in ledger/YYYY.json.
--
-- Data is never lost silently:
-- - writes are atomic (`*.tmp`, then rename onto the real file);
-- - a file that cannot be parsed is moved aside to `*.corrupt-<epoch>` and restored from
--   the latest backup that can be (lib/backups.luau), or left out; the user is warned
--   either way, and a fresh file never overwrites it (if it cannot be moved, the store
--   becomes read-only);
-- - a file from an older schema is migrated on load, after a full backup;
-- - a file written by a newer schema, or one that exists but cannot be read, makes the
--   whole store read-only rather than risk overwriting data it does not understand.

local Backups = require("./backups.luau")
local Time = require("./time.luau")
local Types = require("./types.luau")

type Balance = Types.Balance
type Day = Types.Day
type Host = Types.Host
type Ledger = Types.Ledger
type State = Types.State

local Store = {}
Store.__index = Store

Store.SCHEMA = 1

-- Schema migrations: MIGRATIONS[n] turns a document of schema n into schema n + 1 (the
-- store sets `schema`). `name` is the file, such as "ledger/2026.json".
Store.MIGRATIONS = {} :: { [number]: (doc: any, name: string) -> any }

export type Store = typeof(setmetatable(
  {} :: {
    host: Host,
    dir: string?,
    schema: number,
    migrations: { [number]: (doc: any, name: string) -> any },
    backups: Backups.Backups?,
    migrationBackedUp: boolean,
    ledgers: { [number]: Ledger },
    readOnly: boolean,
    warned: { [string]: boolean },
  },
  Store
))

-- `options` stands in for the current schema and its migrations, for tests.
function Store.new(host: Host, options: { schema: number, migrations: { [number]: (doc: any, name: string) -> any } }?): Store
  local dir, err = host.pluginDataDir()
  local self = setmetatable({
    host = host,
    dir = dir,
    schema = options and options.schema or Store.SCHEMA,
    migrations = options and options.migrations or Store.MIGRATIONS,
    backups = dir and Backups.new(host, dir) or nil,
    migrationBackedUp = false,
    ledgers = {},
    readOnly = false,
    warned = {},
  }, Store)
  if not dir then
    self.readOnly = true
    self:warn("unavailable", tostring(err))
  else
    host.mkdirAll(dir .. "/ledger")
  end
  return self
end

-- Notifies the user once per problem and file.
function Store.warn(self: Store, kind: string, name: string, params: { [string]: string }?)
  local id = kind .. ":" .. name
  if self.warned[id] then
    return
  end
  self.warned[id] = true
  local host = self.host
  local args = table.clone(params or {})
  args.file = name
  host.log(string.format("store: %s (%s)", kind, name))
  host.notifyError(host.tr("errors.store." .. kind .. ".title"), host.tr("errors.store." .. kind .. ".body", args))
end

-- read() and write() never get here without a data dir.
function Store.path(self: Store, name: string): string
  return assert(self.dir, "no plugin data dir") .. "/" .. name
end

local function parse(host: Host, text: string): any
  local doc = host.json.decode(text)
  if type(doc) == "table" and type(doc.schema) == "number" then
    return doc
  end
  return nil
end

-- The newest backed-up copy of a file that can be read, put back in place. Returns it and
-- the backup's label, or nil when no backup has one.
function Store.restore(self: Store, name: string): (any, string?)
  local host = self.host
  for _, copy in (self.backups :: Backups.Backups).copies(name) do
    local text = host.readFile(copy.path)
    local doc = text and parse(host, text)
    if doc and doc.schema <= self.schema then
      local path = self:path(name)
      local ok = host.writeFile(path .. ".tmp", text :: string)
      if not ok or not host.renameFile(path .. ".tmp", path) then
        self:warn("write", name) -- in use until the next save writes it
      end
      return doc, copy.label
    end
  end
  return nil
end

-- Brings an older document to the current schema, after a full backup (once per run:
-- the files are still all as they were). nil when it cannot be done safely.
function Store.migrate(self: Store, name: string, doc: any): any
  if not self.migrationBackedUp then
    local date = os.date("%Y-%m-%d", self.host.nowMs() // 1000) :: string
    if not (self.backups and self.backups.beforeMigration(date, doc.schema)) then
      self.readOnly = true
      self:warn("migration", name)
      return nil
    end
    self.migrationBackedUp = true
  end
  for version = doc.schema, self.schema - 1 do
    local step = self.migrations[version]
    if not step then
      self.readOnly = true
      self:warn("migration", name)
      return nil
    end
    doc = step(doc, name)
    doc.schema = version + 1
  end
  return doc
end

-- Reads a JSON document; nil when it is missing or had to be set aside.
function Store.read(self: Store, name: string): any
  if not self.dir then
    return nil
  end
  local host, path = self.host, self:path(name)
  if not host.fileExists(path) then
    return nil
  end
  local text = host.readFile(path)
  if text == nil then
    self.readOnly = true
    self:warn("unreadable", name)
    return nil
  end
  local doc = parse(host, text)
  if not doc then
    if not host.renameFile(path, string.format("%s.corrupt-%d", path, host.nowMs() // 1000)) then
      -- Still in place: writing would destroy the only copy someone could repair.
      self.readOnly = true
      self:warn("corrupt_stuck", name)
      return nil
    end
    local restored, label = self:restore(name)
    if not restored then
      self:warn("corrupt", name)
      return nil
    end
    self:warn("restored", name, { date = label :: string })
    doc = restored
  end
  if doc.schema > self.schema then
    self.readOnly = true
    self:warn("newer", name)
    return nil
  end
  if doc.schema < self.schema then
    return self:migrate(name, doc)
  end
  return doc
end

-- Writes a JSON document atomically. Returns false when nothing was written.
function Store.write(self: Store, name: string, doc: any): boolean
  if self.readOnly then
    return false
  end
  local host, path = self.host, self:path(name)
  local text, encodeErr = host.json.encode(doc, true)
  local ok, err = false, encodeErr
  if text then
    ok, err = host.writeFile(path .. ".tmp", text)
    if ok then
      ok, err = host.renameFile(path .. ".tmp", path)
    end
  end
  if not ok then
    host.log(string.format("store: cannot write %s: %s", name, tostring(err)))
    self:warn("write", name)
  end
  return ok
end

-- Documents ------------------------------------------------------------------

-- Live state; a new one when there is none yet.
function Store.loadState(self: Store): State
  return self:read("state.json") or { schema = self.schema }
end

function Store.saveState(self: Store, state: State): boolean
  return self:write("state.json", state)
end

-- Takes the day's backup (spec §10.1) unless it exists.
function Store.backup(self: Store, date: string): boolean
  return self.backups ~= nil and self.backups.daily(date)
end

-- Tracking metadata; nil on first run.
function Store.loadBalance(self: Store): Balance?
  return self:read("balance.json")
end

function Store.saveBalance(self: Store, balance: Balance): boolean
  return self:write("balance.json", balance)
end

local function ledgerName(year: number): string
  return string.format("ledger/%d.json", year)
end

function Store.ledger(self: Store, year: number): Ledger
  local ledger = self.ledgers[year]
  if not ledger then
    ledger = self:read(ledgerName(year)) or { schema = self.schema, days = {} }
    self.ledgers[year] = ledger
  end
  return ledger
end

-- Record of a workday, or nil when nothing was recorded. With `create`, an empty record
-- built by `create()` is added to the (unsaved) ledger when missing.
function Store.day(self: Store, dateKey: string, create: (() -> Day)?): Day?
  local days = self:ledger(Time.year(dateKey)).days
  if days[dateKey] == nil and create then
    days[dateKey] = create()
  end
  return days[dateKey]
end

-- Replaces the record of a workday (unsaved until saveLedger).
function Store.setDay(self: Store, dateKey: string, day: Day)
  self:ledger(Time.year(dateKey)).days[dateKey] = day
end

function Store.saveLedger(self: Store, year: number): boolean
  return self:write(ledgerName(year), self:ledger(year))
end

return Store
