--!nonstrict
-- Accounts: the sign-ins Headroom shows for each provider.
--
-- A provider whose CLI keeps its sign-in in a config folder (Claude Code reads
-- CLAUDE_CONFIG_DIR, Codex reads CODEX_HOME) can have several accounts, one
-- per folder:
--   default  the folder the CLI uses when nothing says otherwise
--   added    a folder Headroom created under its data dir; the vendor's own
--            login command, run in a terminal, signs in there
--   found    another folder next to the default one (~/.claude-work) that
--            you already run the CLI with yourself
-- Headroom never writes a credential. It only creates and deletes the folders
-- of accounts it added; removing a found account hides it, and the default
-- account can't be removed.
--
-- Providers without a config folder (Antigravity) have just the default.
--
-- The registry (<data dir>/accounts.json) holds the added accounts' names,
-- the names given to the default and found accounts, and the hidden folders.
-- Only the service writes it.

local fs = require("./fs.luau")

local M = {}

export type Account = {
  key: string, -- "<provider>" for the default, "<provider>:<folder>" for the others
  provider: string,
  kind: string, -- "default" | "added" | "found"
  home: string?, -- the config folder; nil for providers without one
  label: string?, -- the name given; else found: the folder suffix, default: nil
  id: string?, -- added accounts only: the registry id, also the folder name
}

export type Registry = {
  version: number,
  added: { [string]: { { id: string, label: string } } },
  labels: { [string]: { [string]: string } }, -- provider -> folder -> name (default and found accounts)
  hidden: { [string]: { [string]: boolean } },
}

local VERSION = 1
local ID_PATTERN = "^[a-z0-9][a-z0-9-]*$"

local function registryPath(): string?
  local dir = noctalia.pluginDataDir()
  return if dir then `{dir}/accounts.json` else nil
end

-- The folder an added account lives in.
function M.addedHome(providerId: string, id: string): string?
  local dir = noctalia.pluginDataDir()
  return if dir then `{dir}/accounts/{providerId}/{id}` else nil
end

function M.load(ctx): Registry
  local registry = { version = VERSION, added = {}, labels = {}, hidden = {} }
  local path = registryPath()
  local doc = if path and ctx.fileExists(path) then ctx.readJson(path) else nil
  if type(doc) ~= "table" or doc.version ~= VERSION then
    return registry
  end
  for providerId, list in (if type(doc.added) == "table" then doc.added else {}) do
    local valid = {}
    for _, entry in (if type(list) == "table" then list else {}) do
      if type(entry) == "table" and type(entry.id) == "string" and entry.id:match(ID_PATTERN) and type(entry.label) == "string" then
        table.insert(valid, { id = entry.id, label = entry.label })
      end
    end
    registry.added[providerId] = valid
  end
  for providerId, homes in (if type(doc.hidden) == "table" then doc.hidden else {}) do
    if type(homes) == "table" then
      registry.hidden[providerId] = homes
    end
  end
  for providerId, names in (if type(doc.labels) == "table" then doc.labels else {}) do
    local valid = {}
    for home, label in (if type(names) == "table" then names else {}) do
      if type(home) == "string" and type(label) == "string" then
        valid[home] = label
      end
    end
    registry.labels[providerId] = valid
  end
  return registry
end

function M.save(registry: Registry)
  local path = registryPath()
  local text = path and noctalia.json.encode(registry)
  if text then
    fs.writeAtomic(path, text)
  end
end

-- The folder the CLI uses when nothing says otherwise: its environment
-- variable if set, else its default.
function M.defaultHome(spec, ctx): string
  local fromEnv = ctx.env(spec.env)
  if fromEnv ~= nil and fromEnv ~= "" then
    return fromEnv
  end
  return ctx.expandPath(spec.default)
end

-- Every account of provider `p`, in display order: the default, the added ones
-- in the order they were added, then the found ones by name. `signedIn(home)`
-- says whether a folder holds a login; a found folder is only listed if it does.
function M.list(p, ctx, registry: Registry, signedIn: (string) -> boolean): { Account }
  local spec = p.accounts
  if spec == nil then
    return { { key = p.id, provider = p.id, kind = "default" } }
  end
  local defaultHome = M.defaultHome(spec, ctx)
  local labels = registry.labels[p.id] or {}
  local out = { { key = p.id, provider = p.id, kind = "default", home = defaultHome, label = labels[defaultHome] } }

  for _, entry in registry.added[p.id] or {} do
    local home = M.addedHome(p.id, entry.id)
    if home then
      table.insert(out, { key = `{p.id}:{home}`, provider = p.id, kind = "added", home = home, label = entry.label, id = entry.id })
    end
  end

  local hidden = registry.hidden[p.id] or {}
  local names = noctalia.listDir(ctx.expandPath("~")) or {}
  table.sort(names)
  for _, name in names do
    local suffix = if name:sub(1, #spec.siblingPrefix) == spec.siblingPrefix then name:sub(#spec.siblingPrefix + 1) else nil
    local home = ctx.expandPath(`~/{name}`)
    if suffix and suffix ~= "" and home ~= defaultHome and not hidden[home] and signedIn(home) then
      table.insert(out, { key = `{p.id}:{home}`, provider = p.id, kind = "found", home = home, label = labels[home] or suffix })
    end
  end
  return out
end

-- A registry id for a new account named `label`: lowercase, dashes, unique.
function M.newId(registry: Registry, providerId: string, label: string): string
  local base = label:lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if base == "" then
    base = "account"
  end
  local taken = {}
  for _, entry in registry.added[providerId] or {} do
    taken[entry.id] = true
  end
  local id, n = base, 2
  while taken[id] do
    id = `{base}-{n}`
    n += 1
  end
  return id
end

function M.add(registry: Registry, providerId: string, id: string, label: string)
  registry.added[providerId] = registry.added[providerId] or {}
  table.insert(registry.added[providerId], { id = id, label = label })
end

-- Names an account. An empty name gives the default and found accounts their
-- usual name back; added accounts always keep one.
function M.rename(registry: Registry, account: Account, label: string): boolean
  if account.kind == "added" then
    if label == "" then
      return false
    end
    for _, entry in registry.added[account.provider] or {} do
      if entry.id == account.id then
        entry.label = label
        return true
      end
    end
    return false
  elseif account.home == nil then
    return false
  end
  registry.labels[account.provider] = registry.labels[account.provider] or {}
  registry.labels[account.provider][account.home] = if label == "" then nil else label
  return true
end

-- Forgets an account: an added one leaves the registry (the caller deletes its
-- folder), a found one is hidden. Returns false for the default.
function M.forget(registry: Registry, account: Account): boolean
  if account.kind == "added" then
    local list = registry.added[account.provider] or {}
    for i, entry in list do
      if entry.id == account.id then
        table.remove(list, i)
        return true
      end
    end
    return false
  elseif account.kind == "found" and account.home then
    registry.hidden[account.provider] = registry.hidden[account.provider] or {}
    registry.hidden[account.provider][account.home] = true
    return true
  end
  return false
end

-- True when `home` is an added account's folder, safe to delete.
function M.isAddedHome(account: Account): boolean
  local expected = account.id and M.addedHome(account.provider, account.id)
  return account.kind == "added" and expected ~= nil and account.home == expected and account.id:match(ID_PATTERN) ~= nil
end

-- Single-quotes a word for sh.
function M.quote(word: string): string
  return "'" .. word:gsub("'", "'\\''") .. "'"
end

-- argv prefixed so the CLI uses this account's folder. The default account
-- runs as is: the CLI finds its folder the usual way.
function M.inHome(spec, account: Account, argv: { string }): { string }
  if spec == nil or account.kind == "default" or account.home == nil then
    return argv
  end
  return { "env", `{spec.env}={account.home}`, table.unpack(argv) }
end

-- The shell command that signs an account in, for noctalia.runInTerminal: the
-- vendor's login command in the account's folder, then a pause so the result
-- stays readable. `intro` and `done` are already-translated lines.
function M.loginCommand(spec, account: Account, command: string, intro: string, done: string): string
  local words = {}
  for _, word in M.inHome(spec, account, { command, table.unpack(spec.login) }) do
    table.insert(words, M.quote(word))
  end
  return table.concat({
    `printf '%s\\n\\n' {M.quote(intro)}`,
    table.concat(words, " "),
    `printf '\\n%s ' {M.quote(done)}`,
    "read -r _",
  }, "; ")
end

return M
