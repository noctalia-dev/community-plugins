--!nonstrict
-- Headroom poller: the one entry that talks to the network.
--
-- It keeps one runtime per account (lib/accounts.luau), fetches whatever the
-- scheduler says is due, and publishes one normalized report to
-- noctalia.state for the bar and panel to draw. The last good numbers are
-- cached on disk so the bar has numbers right after login, and notifications
-- fire from here, once each. It also carries out the panel's account
-- commands: add, sign in, rename, remove, unhide.
--
-- Side effects, for review:
--   network  each signed-in account's usage endpoints (see providers/*)
--   reads    each account's saved sign-in (read-only); see providers/*
--   spawns   what adapters declare (Claude: claude; Antigravity: secret-tool,
--            agy), `rm -rf` on the folder of an added account being removed,
--            and a terminal running the vendor's login when signing in
--   writes   <pluginDataDir>/cache.json (numbers only, never credentials),
--            <pluginDataDir>/accounts.json (names of added accounts, hidden
--            folders) and the empty folders of added accounts

local registry = require("./providers/registry.luau")
local model = require("./lib/model.luau")
local scheduler = require("./lib/scheduler.luau")
local context = require("./lib/context.luau")
local accounts = require("./lib/accounts.luau")
local renew = require("./lib/renew.luau")
local state = require("./lib/state.luau")
local time = require("./lib/time.luau")
local notify = require("./lib/notify.luau")
local fs = require("./lib/fs.luau")

local E = model.ErrorCode
local TICK_MS = 5000
-- How often to look for new account folders and sign-in changes. Local file
-- checks; while a login terminal is open, every tick.
local CHECK_SECONDS = 30
-- How long to watch closely for a sign-in after opening a login terminal.
local LOGIN_WAIT_SECONDS = 10 * 60
-- A manual refresh skips numbers younger than this: the endpoints throttle,
-- and Claude's budget is shared with Claude Code.
local MANUAL_FLOOR_SECONDS = 15
local LABEL_MAX = 32
local CACHE_VERSION = 2

-- The version, from the manifest: the one place it is written.
local manifest = noctalia.readFile(`{noctalia.pluginDir()}/plugin.toml`) or ""
local version = manifest:match('\nversion%s*=%s*"([^"]+)"') or "dev"
local base = context.new(noctalia, `headroom-noctalia/{version}`)

local providersById = {}
for _, p in registry do
  providersById[p.id] = p
end

-- ── Accounts ───────────────────────────────────────────────────────────────

-- An account is in exactly one phase:
--   signed_out  no usable sign-in in its folder
--   loading     signed in, no numbers for this account yet
--   ready       numbers from the last fetch
--   failing     the last fetch failed; `error` says why, older numbers may remain
-- Separately, `duplicateOf` marks a folder signed in to the same account as an
-- earlier one: it is not fetched, and the panel says so.
type Runtime = {
  provider: any,
  account: accounts.Account,
  ctx: any,
  schedule: scheduler.Entry,
  phase: string,
  stamp: string?, -- the sign-in as last seen: nil when absent, else the credentials' mtime
  identity: { id: string, email: string? }?, -- who the current sign-in is, when known
  owner: string?, -- whose numbers `snapshot` and `notified` are (an identity id)
  email: string?, -- last known
  snapshot: model.Snapshot?,
  error: model.ProviderError?,
  duplicateOf: string?, -- key of the earlier account
  notified: notify.Latches,
  loginOpenedAt: number?, -- a login terminal was opened for it
}

local runtimes: { [string]: Runtime } = {}
-- Account keys per provider, in display order. Providers set to "off" have none.
local listed: { [string]: { string } } = {}
-- Disk-cache entries waiting for their account's runtime.
local cached: { [string]: any } = {}
local accountRegistry = accounts.load(base)
-- The CLI that signs accounts in, per provider; absent when it isn't installed.
local loginCommands: { [string]: string } = {}
local lastCheckAt = -math.huge

local function isOff(id: string): boolean
  return state.providerMode(id) == "off"
end

local function intervalSeconds(): number
  return math.clamp(state.config("refresh_minutes", 5), 1, 120) * 60
end

-- Every listed runtime, as a list taken now: callers may change the lists.
local function listedRuntimes(): { Runtime }
  local out = {}
  for _, p in registry do
    for _, key in listed[p.id] or {} do
      table.insert(out, runtimes[key])
    end
  end
  return out
end

-- Errors the vendor's login fixes.
local SIGN_IN_ERRORS = { [E.Expired] = true, [E.Auth] = true }

local function forget(rt: Runtime)
  rt.snapshot, rt.owner, rt.notified, rt.error = nil, nil, {}, nil
end

-- Reads who the folder is signed in to. A different account than the one the
-- numbers belong to makes them someone else's: they go. Unknown (Claude
-- before its first fetch with a new token) leaves them alone.
local function learnIdentity(rt: Runtime)
  local spec = rt.provider.accounts
  if spec == nil or rt.stamp == nil then
    rt.identity = nil
    return
  end
  local ok, identity = pcall(spec.identity, rt.ctx)
  rt.identity = if ok and type(identity) == "table" and type(identity.id) == "string" then identity else nil
  if rt.identity == nil then
    return
  end
  rt.email = rt.identity.email or rt.email
  if rt.owner ~= nil and rt.owner ~= rt.identity.id then
    forget(rt)
    rt.phase = "loading"
  end
  rt.owner = rt.identity.id
end

local function credentialStamp(rt: Runtime): string?
  if not rt.provider.isConfigured(rt.ctx) then
    return nil
  end
  local spec = rt.provider.accounts
  local info = spec and rt.account.home and noctalia.fileInfo(`{rt.account.home}/{spec.credentials}`)
  return if info then tostring(info.mtime) else "present"
end

-- Takes in the folder's sign-in as it is now (`stamp`).
local function adoptStamp(rt: Runtime, stamp: string?)
  rt.stamp = stamp
  rt.loginOpenedAt = nil
  if stamp == nil then
    forget(rt)
    rt.identity = nil
    rt.phase = "signed_out"
    return
  end
  learnIdentity(rt)
  if rt.phase == "signed_out" or (rt.phase == "failing" and SIGN_IN_ERRORS[rt.error.code]) then
    rt.phase = if rt.snapshot then "ready" else "loading"
    rt.error = nil
  end
end

-- Notices a sign-in, sign-out, renewal or `/login` in the folder, and asks
-- for fresh numbers. Returns true when something changed.
local function checkCredentials(rt: Runtime, now: number): boolean
  local stamp = credentialStamp(rt)
  if stamp == rt.stamp then
    return false
  end
  adoptStamp(rt, stamp)
  -- A request still out was made for the old sign-in.
  scheduler.abandon(rt.schedule, now)
  return true
end

-- Marks folders signed in to an account an earlier folder already shows.
-- One that stops being a copy is fetched right away. A folder whose new token
-- is not identified yet (after a restart or a renewal) keeps its claim on the
-- account its numbers belong to; if it really switched, its own fetch says so.
local function resolveDuplicates(now: number)
  for _, p in registry do
    local seen = {}
    for _, key in listed[p.id] or {} do
      local rt = runtimes[key]
      local id = rt.stamp and rt.identity and rt.identity.id
      local claim = rt.stamp and (id or rt.owner)
      local first = id and seen[id]
      if rt.duplicateOf and not first then
        scheduler.force(rt.schedule, now)
      end
      rt.duplicateOf = first or nil
      if claim and not first and seen[claim] == nil then
        seen[claim] = key
      end
    end
  end
end

local function accountContext(p, account)
  return if p.accounts then context.forAccount(base, p.accounts, account) else base
end

local function newRuntime(p, account: accounts.Account, now: number): Runtime
  local rt: Runtime = {
    provider = p,
    account = account,
    ctx = accountContext(p, account),
    schedule = scheduler.new(),
    phase = "signed_out",
    stamp = nil,
    identity = nil,
    owner = nil,
    email = nil,
    snapshot = nil,
    error = nil,
    duplicateOf = nil,
    notified = {},
    loginOpenedAt = nil,
  }
  local entry = cached[account.key]
  local stamp = credentialStamp(rt)
  if entry then
    cached[account.key] = nil
    rt.snapshot, rt.owner, rt.notified = entry.snapshot, entry.owner, entry.notified
    rt.phase = "ready"
    -- Fetched shortly before a restart with the same sign-in: still current.
    if entry.stamp == stamp then
      scheduler.resume(rt.schedule, entry.snapshot.fetchedAt, now, intervalSeconds())
    end
  end
  adoptStamp(rt, stamp)
  return rt
end

-- Rebuilds every provider's account list: new folders get a runtime, removed
-- ones lose theirs (a provider turned off keeps its data for when it is back).
-- Returns true when any list changed.
local function syncAccounts(now: number): boolean
  local changed = false
  local present = {}
  for _, p in registry do
    local keys = {}
    loginCommands[p.id] = p.accounts and renew.findCommand(base, p.accounts.command, p.accounts.fallbacks or {}) or nil
    if not isOff(p.id) then
      local list = accounts.list(p, base, accountRegistry, function(home)
        return p.isConfigured(accountContext(p, { kind = "found", home = home }))
      end)
      for _, account in list do
        present[account.key] = true
        local rt = runtimes[account.key]
        if rt == nil then
          runtimes[account.key] = newRuntime(p, account, now)
        else
          rt.account = account -- picks up a new name
        end
        table.insert(keys, account.key)
      end
    end
    if table.concat(keys, "\n") ~= table.concat(listed[p.id] or {}, "\n") then
      changed = true
    end
    listed[p.id] = keys
  end
  for key, rt in runtimes do
    if not present[key] and not isOff(rt.provider.id) then
      runtimes[key] = nil
    end
  end
  return changed
end

-- An added account is named for the account it was added for, once known.
local function nameAddedAccounts()
  local named = false
  for _, rt in runtimes do
    local id = rt.identity and rt.identity.id
    local names = accountRegistry.names
    if rt.account.kind == "added" and id and rt.duplicateOf == nil
      and (names[rt.provider.id] == nil or names[rt.provider.id][id] == nil)
    then
      names[rt.provider.id] = names[rt.provider.id] or {}
      names[rt.provider.id][id] = rt.account.label
      named = true
    end
  end
  if named then
    accounts.save(accountRegistry)
  end
end

-- The name an account goes by: the one given to its sign-in (so after
-- `/login` it follows the account), else its folder's; nil for an unnamed
-- default.
local function labelOf(rt: Runtime): string?
  local id = (rt.identity and rt.identity.id) or rt.owner
  return id and (accountRegistry.names[rt.provider.id] or {})[id] or rt.account.label
end

local function nameOf(rt: Runtime): string
  return labelOf(rt) or noctalia.tr("accounts.default")
end

-- The shell command that starts the provider's CLI as this account, for the
-- panel's copy button: CLAUDE_CONFIG_DIR='/path' claude
local function launchCommand(rt: Runtime): string?
  local spec = rt.provider.accounts
  if spec == nil or rt.account.kind == "default" or rt.account.home == nil then
    return nil
  end
  return `{spec.env}={accounts.quote(rt.account.home)} {spec.command}`
end

-- ── Cache ──────────────────────────────────────────────────────────────────

local function cachePath(): string?
  local dir = noctalia.pluginDataDir()
  return if dir then `{dir}/cache.json` else nil
end

local lastCacheText: string? = nil

local function saveCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local doc = { version = CACHE_VERSION, accounts = {} }
  for key, entry in cached do
    doc.accounts[key] = entry
  end
  for key, rt in runtimes do
    if rt.snapshot then
      doc.accounts[key] = { snapshot = rt.snapshot, owner = rt.owner, stamp = rt.stamp, notified = rt.notified }
    end
  end
  local text = noctalia.json.encode(doc)
  if text and text ~= lastCacheText and fs.writeAtomic(path, text) then
    lastCacheText = text
  end
end

local function loadCache()
  local path = cachePath()
  local doc = if path and noctalia.fileExists(path) then base.readJson(path) else nil
  if type(doc) ~= "table" or doc.version ~= CACHE_VERSION or type(doc.accounts) ~= "table" then
    return
  end
  for key, entry in doc.accounts do
    local snapshot = type(entry) == "table" and entry.snapshot
    if type(snapshot) == "table" and type(snapshot.windows) == "table" and type(snapshot.fetchedAt) == "number" then
      cached[key] = {
        snapshot = snapshot,
        owner = if type(entry.owner) == "string" then entry.owner else nil,
        stamp = if type(entry.stamp) == "string" then entry.stamp else nil,
        notified = if type(entry.notified) == "table" then entry.notified else {},
      }
    end
  end
end

-- ── Publishing ─────────────────────────────────────────────────────────────

local function hiddenCount(p): number
  local n = 0
  for home in accountRegistry.hidden[p.id] or {} do
    if noctalia.fileExists(home) then
      n += 1
    end
  end
  return n
end

local function publish()
  local views = {}
  for _, p in registry do
    if not isOff(p.id) then
      local canSignIn = loginCommands[p.id] ~= nil
      local accountViews = {}
      for _, key in listed[p.id] or {} do
        local rt = runtimes[key]
        -- A found folder signed in to an account already shown is left out;
        -- one Headroom added stays, marked, so the panel can say so.
        if not (rt.duplicateOf and rt.account.kind == "found") then
          local first = rt.duplicateOf and runtimes[rt.duplicateOf]
          table.insert(accountViews, {
            key = key,
            kind = rt.account.kind,
            -- A copy goes by its folder's name; the account's belongs to the first.
            name = if first then (rt.account.label or noctalia.tr("accounts.default")) else nameOf(rt),
            label = labelOf(rt),
            email = rt.email,
            home = rt.account.home,
            launch = launchCommand(rt),
            phase = rt.phase,
            snapshot = if rt.phase == "signed_out" then nil else rt.snapshot,
            error = rt.error,
            busy = scheduler.isBusy(rt.schedule),
            signingIn = rt.loginOpenedAt ~= nil,
            canSignIn = canSignIn,
            duplicateOf = first and nameOf(first) or nil,
          })
        end
      end
      table.insert(views, {
        id = p.id,
        name = p.name,
        brand = p.brand,
        hint = p.signInHint(base),
        canAdd = canSignIn,
        hidden = hiddenCount(p),
        accounts = accountViews,
      })
    end
  end
  noctalia.state.set(state.REPORT, { interval = intervalSeconds(), providers = views })
end

-- ── Fetching ───────────────────────────────────────────────────────────────

local function withHint(rt: Runtime, err: model.ProviderError): model.ProviderError
  if SIGN_IN_ERRORS[err.code] then
    err.hint = if rt.account.kind == "default" then rt.provider.signInHint(rt.ctx) else noctalia.tr("accounts.hint")
  end
  return err
end

local function sendNotifications(rt: Runtime)
  local _, critical = state.thresholds()
  local enabled = state.config("notify", true)
  local name = if #(listed[rt.provider.id] or {}) <= 1 then rt.provider.name else `{rt.provider.name} · {nameOf(rt)}`
  local messages = notify.messages(name, rt.snapshot, rt.notified, {
    critical = critical,
    enabled = enabled,
    credits = enabled and state.config("notify_reset_credits", true),
    interval = intervalSeconds(),
    now = base.now(),
    tr = noctalia.tr,
    trp = noctalia.trp,
    duration = time.duration,
  })
  for _, message in messages do
    noctalia.notify(message.title, message.body)
  end
end

local function applyReply(rt: Runtime, snapshot: model.Snapshot?, err: model.ProviderError?)
  -- The fetch may have told us whose token this is (Claude).
  learnIdentity(rt)
  if err and err.code == E.NotConfigured then
    -- A sign-in file with nothing usable in it (an API-key-only Codex):
    -- nothing to show, and not a problem to report.
    rt.phase, rt.error = "signed_out", nil
  elseif err then
    rt.phase, rt.error = "failing", withHint(rt, err)
    noctalia.log(`[headroom] {rt.account.key}: {err.code}{if err.detail then " (" .. err.detail .. ")" else ""}`)
  else
    rt.phase, rt.error, rt.snapshot = "ready", nil, snapshot
    sendNotifications(rt)
    saveCache()
  end
  resolveDuplicates(base.now())
  nameAddedAccounts()
end

-- A copy of the context whose callbacks report a throw as a failed fetch, so
-- an adapter tripping over an unexpected response fails visibly instead of
-- leaving the request hanging.
local function guarded(ctx, fail: (string) -> ())
  local function wrap(callback)
    return function(...)
      local ok, thrown = pcall(callback, ...)
      if not ok then
        fail(tostring(thrown))
      end
    end
  end
  local out = table.clone(ctx)
  out.getJson = function(url, headers, done)
    ctx.getJson(url, headers, wrap(done))
  end
  out.postJson = function(url, headers, body, done, classify)
    ctx.postJson(url, headers, body, wrap(done), classify)
  end
  out.run = function(argv, timeoutMs, done)
    ctx.run(argv, timeoutMs, wrap(done))
  end
  return out
end

-- Starts a fetch; the reply publishes when it lands.
local function fetchAccount(rt: Runtime, now: number)
  local generation = scheduler.start(rt.schedule, now)
  local function reply(snapshot, err)
    if scheduler.finish(rt.schedule, generation, base.now(), intervalSeconds(), err) then
      applyReply(rt, snapshot, err)
      publish()
    end
  end
  local function fail(message: string)
    noctalia.log(`[headroom] {rt.account.key}: adapter error: {message}`)
    reply(nil, model.err(E.Parse, "adapter error"))
  end
  local ok, thrown = pcall(rt.provider.fetch, guarded(rt.ctx, fail), reply)
  if not ok then
    fail(tostring(thrown))
  end
end

local function isFetchable(rt: Runtime): boolean
  return rt.stamp ~= nil and rt.duplicateOf == nil
end

-- Numbers for a window whose reset time has passed say nothing about now:
-- fetch soon after, rather than an interval later.
local function pastReset(rt: Runtime, now: number): boolean
  local snapshot = rt.snapshot
  if rt.phase ~= "ready" or snapshot == nil or now - snapshot.fetchedAt < 60 then
    return false
  end
  for _, w in snapshot.windows do
    if w.resetsAt and w.resetsAt <= now and w.resetsAt > snapshot.fetchedAt then
      return true
    end
  end
  return false
end

local function tick(full: boolean?)
  local now = base.now()
  local changed = false
  local checkAll = full or now - lastCheckAt >= CHECK_SECONDS
  if checkAll then
    lastCheckAt = now
    changed = syncAccounts(now)
  end
  for _, rt in listedRuntimes() do
    if rt.loginOpenedAt and now - rt.loginOpenedAt >= LOGIN_WAIT_SECONDS then
      rt.loginOpenedAt = nil
      changed = true
    end
    if (checkAll or rt.loginOpenedAt) and checkCredentials(rt, now) then
      changed = true
    end
    local lost = scheduler.expired(rt.schedule, now)
    if lost and scheduler.finish(rt.schedule, rt.schedule.generation, now, intervalSeconds(), lost) then
      applyReply(rt, nil, lost)
      changed = true
    end
    if pastReset(rt, now) then
      scheduler.force(rt.schedule, now)
    end
  end
  if changed then
    resolveDuplicates(now)
  end
  for _, rt in listedRuntimes() do
    if isFetchable(rt) and scheduler.isDue(rt.schedule, now) then
      fetchAccount(rt, now)
      changed = true
    end
  end
  if changed then
    publish()
  end
end

-- A refresh request. Without `maxAge` (refresh button, R, IPC) every account
-- is fetched now, unless its numbers are seconds old or the vendor is
-- throttling it. With `maxAge` (opening the panel), only accounts whose good
-- numbers are older than that are; one that is failing keeps its backoff.
local function refresh(maxAge: number?)
  local now = base.now()
  for _, rt in listedRuntimes() do
    local age = if rt.snapshot then now - rt.snapshot.fetchedAt else math.huge
    local wanted = if maxAge == nil then age >= MANUAL_FLOOR_SECONDS else rt.phase ~= "failing" and age >= maxAge
    if wanted then
      scheduler.force(rt.schedule, now)
    end
  end
  tick(true)
end

-- ── Account commands ───────────────────────────────────────────────────────

-- At most LABEL_MAX characters, cut on a character boundary.
local function cleanLabel(label: string): string
  label = noctalia.string.trim(label)
  if utf8.len(label) == nil then
    return ""
  end
  local cut = utf8.offset(label, LABEL_MAX + 1)
  return if cut then label:sub(1, cut - 1) else label
end

-- Opens a terminal running the vendor's login in the account's folder. The
-- CLI writes the sign-in; the next ticks notice it.
local function signIn(rt: Runtime)
  local p = rt.provider
  local command = loginCommands[p.id]
  if command == nil then
    return
  end
  local intro = noctalia.tr("accounts.login_intro", { provider = p.name, account = nameOf(rt) })
  local shell = accounts.loginCommand(p.accounts, rt.account, command, intro, noctalia.tr("accounts.login_done"))
  if not noctalia.runInTerminal(shell) then
    noctalia.notifyError(noctalia.tr("accounts.no_terminal_title"), noctalia.tr("accounts.no_terminal_body"))
    return
  end
  rt.loginOpenedAt = base.now()
  publish()
end

local function addAccount(providerId: string, label: string)
  local p = providersById[providerId]
  if p == nil or p.accounts == nil or isOff(p.id) or loginCommands[p.id] == nil then
    return
  end
  label = cleanLabel(label)
  if label == "" then
    label = noctalia.tr("accounts.unnamed", { n = #(listed[p.id] or {}) + 1 })
  end
  local id = accounts.newId(accountRegistry, p.id, label)
  local home = accounts.addedHome(p.id, id)
  if not (home and noctalia.mkdirAll(home)) then
    noctalia.log(`[headroom] {p.id}: could not create an account folder`)
    return
  end
  accounts.add(accountRegistry, p.id, id, label)
  accounts.save(accountRegistry)
  syncAccounts(base.now())
  local rt = runtimes[`{p.id}:{home}`]
  if rt then
    signIn(rt)
  end
  publish()
end

local function renameAccount(rt: Runtime, label: string)
  if accounts.rename(accountRegistry, rt.account, cleanLabel(label), (rt.identity and rt.identity.id) or rt.owner) then
    accounts.save(accountRegistry)
    syncAccounts(base.now())
    publish()
  end
end

local function removeAccount(rt: Runtime)
  local account = rt.account
  local deletes = account.kind == "added" and accounts.isAddedHome(account)
  if (account.kind == "added" and not deletes) or not accounts.forget(accountRegistry, account) then
    return
  end
  accounts.save(accountRegistry)
  if deletes then
    -- Headroom made this folder; it holds this account's sign-in and whatever
    -- the CLI wrote there since.
    noctalia.runAsync({ "rm", "-rf", "--", account.home })
  end
  runtimes[account.key] = nil
  cached[account.key] = nil
  syncAccounts(base.now())
  resolveDuplicates(base.now())
  saveCache()
  publish()
end

local function unhideAccounts(providerId: string)
  if accountRegistry.hidden[providerId] then
    accountRegistry.hidden[providerId] = nil
    accounts.save(accountRegistry)
    tick(true)
    publish()
  end
end

local function onCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  local label = if type(command.label) == "string" then command.label else ""
  if action == "refresh" then
    refresh(tonumber(command.maxAge))
  elseif action == "add" and type(command.provider) == "string" then
    addAccount(command.provider, label)
  elseif action == "unhide" and type(command.provider) == "string" then
    unhideAccounts(command.provider)
  elseif type(command.key) == "string" and runtimes[command.key] then
    local rt = runtimes[command.key]
    if action == "sign_in" then
      signIn(rt)
    elseif action == "rename" then
      renameAccount(rt, label)
    elseif action == "remove" then
      removeAccount(rt)
    end
  end
end

-- ── Host callbacks ─────────────────────────────────────────────────────────

function update()
  tick()
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  end
end

function onConfigChanged()
  -- A provider may have been turned on or off, or the interval changed.
  local now = base.now()
  syncAccounts(now)
  resolveDuplicates(now)
  for _, rt in listedRuntimes() do
    scheduler.cap(rt.schedule, now, intervalSeconds())
  end
  tick()
  publish()
end

noctalia.state.watch(state.COMMAND, onCommand)

loadCache()
noctalia.setUpdateInterval(TICK_MS)
tick(true)
publish() -- even with nothing signed in, so surfaces leave their "starting" state
