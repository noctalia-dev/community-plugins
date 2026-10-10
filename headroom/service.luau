--!nonstrict
-- Headroom poller: the one entry that talks to the network.
--
-- Every tick it walks each provider's accounts (lib/accounts.luau), fetches
-- whatever the scheduler says is due, and publishes one normalized report to
-- noctalia.state for the bar and panel to draw. The last good snapshots are
-- cached on disk so the bar shows numbers immediately after login instead of an
-- empty state (stale-while-revalidate), and threshold notifications fire from
-- here exactly once per crossing. It also carries out the panel's account
-- commands: add, sign in, rename, remove.
--
-- Side effects, for review:
--   network  each signed-in account's usage endpoint (see providers/*)
--   reads    each account's saved sign-in (read-only); see providers/*
--   spawns   what adapters declare (Claude: claude; Antigravity: secret-tool,
--            agy), `rm -rf` on the folder of an added account being removed,
--            and a terminal running the vendor's login when signing in
--   writes   <pluginDataDir>/cache.json (snapshots only, never credentials),
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
-- How often to notice sign-ins, sign-outs and new account folders. Local file
-- checks, but some providers scan PATH, so not on every tick.
local SIGN_IN_CHECK_SECONDS = 30
-- After opening a login terminal, how long to watch for the sign-in on every tick.
local SIGN_IN_WAIT_SECONDS = 10 * 60
local LABEL_MAX = 32

local base = context.new(noctalia, `headroom-noctalia/{state.VERSION}`)

local providersById = {}
for _, p in registry do
  providersById[p.id] = p
end

-- ── Per-account runtime state ──────────────────────────────────────────────

type Runtime = {
  provider: any,
  account: accounts.Account,
  ctx: any,
  schedule: scheduler.Entry,
  configured: boolean,
  checkedAt: number, -- last isConfigured() check
  identity: { id: string, email: string? }?,
  snapshot: model.Snapshot?,
  error: model.ProviderError?,
  stale: boolean, -- snapshot is from the disk cache, or older than the current error
  notified: { [string]: number }, -- window id -> resetsAt we already warned about
  signingInSince: number?, -- a login terminal was opened for this account
  duplicateOf: string?, -- signed in to the same account as this earlier one (its key); not fetched
}

local runtimes: { [string]: Runtime } = {}
-- Account keys per provider, in display order. Providers set to "off" have none.
local listed: { [string]: { string } } = {}
-- Disk-cache entries waiting for their account's runtime.
local cached: { [string]: any } = {}
local accountRegistry = accounts.load(base)
-- The CLI that signs accounts in, per provider; absent when it isn't
-- installed. Looked up with the account lists, since it scans PATH.
local loginCommands: { [string]: string } = {}
local lastRefreshAt: number? = nil
local lastSyncAt = -math.huge

local function isOff(id: string): boolean
  return state.providerMode(id) == "off"
end

local function intervalSeconds(): number
  return math.clamp(state.config("refresh_minutes", 5), 1, 120) * 60
end

local function eachListed(fn: (Runtime) -> ())
  for _, p in registry do
    for _, key in listed[p.id] or {} do
      fn(runtimes[key])
    end
  end
end

-- ── Cache ──────────────────────────────────────────────────────────────────

local function cachePath(): string?
  local dir = noctalia.pluginDataDir()
  return if dir then `{dir}/cache.json` else nil
end

local function saveCache()
  local path = cachePath()
  if path == nil then
    return
  end
  local doc = { version = 1, providers = {} }
  for key, entry in cached do
    doc.providers[key] = entry
  end
  for key, rt in runtimes do
    if rt.snapshot then
      doc.providers[key] = { snapshot = rt.snapshot, notified = rt.notified }
    end
  end
  local text = noctalia.json.encode(doc)
  if text then
    fs.writeAtomic(path, text)
  end
end

local function loadCache()
  local path = cachePath()
  if path == nil or not noctalia.fileExists(path) then
    return
  end
  local doc = base.readJson(path)
  if type(doc) ~= "table" or doc.version ~= 1 or type(doc.providers) ~= "table" then
    return
  end
  for key, entry in doc.providers do
    if type(entry) == "table" and type(entry.snapshot) == "table" and type(entry.snapshot.windows) == "table" then
      cached[key] = entry
    end
  end
end

-- ── Accounts ───────────────────────────────────────────────────────────────

local function accountContext(p, account)
  return if p.accounts then context.forAccount(base, p.accounts, account) else base
end

local function readIdentity(rt: Runtime)
  local spec = rt.provider.accounts
  if spec == nil or not rt.configured then
    rt.identity = nil
    return
  end
  local ok, identity = pcall(spec.identity, rt.ctx)
  rt.identity = if ok and type(identity) == "table" and type(identity.id) == "string" then identity else nil
end

-- Re-checks whether the account is signed in. Returns true when that changed.
local function checkSignIn(rt: Runtime, now: number): boolean
  rt.checkedAt = now
  local configured = rt.provider.isConfigured(rt.ctx)
  if configured == rt.configured then
    return false
  end
  rt.configured = configured
  readIdentity(rt)
  if configured then
    rt.signingInSince = nil
    scheduler.force(rt.schedule, now) -- signed in since the last check
  else
    rt.error = nil
  end
  return true
end

local function newRuntime(p, account: accounts.Account): Runtime
  local rt = {
    provider = p,
    account = account,
    ctx = accountContext(p, account),
    schedule = scheduler.new(),
    configured = false,
    checkedAt = -math.huge,
    identity = nil,
    snapshot = nil,
    error = nil,
    stale = false,
    notified = {},
    signingInSince = nil,
    duplicateOf = nil,
  }
  checkSignIn(rt, base.now())
  local entry = cached[account.key]
  if entry then
    cached[account.key] = nil
    rt.snapshot = entry.snapshot
    rt.stale = true
    rt.notified = if type(entry.notified) == "table" then entry.notified else {}
    -- Data fetched shortly before a restart or reload is still current: wait
    -- out the rest of its interval instead of fetching it again.
    local fetchedAt = entry.snapshot.fetchedAt
    if type(fetchedAt) == "number" then
      rt.schedule.nextAt = math.min(fetchedAt, base.now()) + intervalSeconds()
    end
  end
  return rt
end

-- Rebuilds every provider's account list: new folders get a runtime, removed
-- ones lose theirs. A found folder signed in to an account already listed is
-- a copy, and stays out; an added one stays, marked, so the panel can say so.
-- Returns true when any list changed.
local function syncAccounts(): boolean
  local changed = false
  local present = {}
  for _, p in registry do
    local keys = {}
    loginCommands[p.id] = p.accounts and renew.findCommand(base, p.accounts.command, p.accounts.fallbacks or {}) or nil
    if not isOff(p.id) then
      local seen = {}
      local list = accounts.list(p, base, accountRegistry, function(home)
        return p.isConfigured(accountContext(p, { kind = "found", home = home }))
      end)
      for _, account in list do
        present[account.key] = true
        local rt = runtimes[account.key]
        if rt == nil then
          rt = newRuntime(p, account)
          runtimes[account.key] = rt
        end
        rt.account = account -- picks up a new name
        if rt.configured and rt.identity == nil then
          readIdentity(rt) -- the CLI may write the profile after the sign-in
        end
        local id = rt.identity and rt.identity.id
        local first = id and seen[id]
        if account.kind == "found" and first then
          continue
        end
        if (first or nil) ~= rt.duplicateOf then
          rt.duplicateOf = first or nil
          changed = true
        end
        if id and not first then
          seen[id] = account.key
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
    -- A provider turned off keeps its data for when it is turned back on.
    if not present[key] and not isOff(rt.provider.id) then
      runtimes[key] = nil
    end
  end
  return changed
end

local function displayName(rt: Runtime): string
  if #(listed[rt.provider.id] or {}) <= 1 then
    return rt.provider.name
  end
  return `{rt.provider.name} · {rt.account.label or noctalia.tr("accounts.default")}`
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

-- ── Publishing ─────────────────────────────────────────────────────────────

local function statusOf(rt: Runtime): string
  if not rt.configured then
    return "absent"
  elseif rt.error ~= nil then
    return "error"
  elseif rt.snapshot == nil then
    return "loading"
  end
  return "ok"
end

local function publish()
  local now = base.now()
  local views = {}
  for _, p in registry do
    if not isOff(p.id) then
      local canSignIn = loginCommands[p.id] ~= nil
      local accountViews = {}
      for _, key in listed[p.id] or {} do
        local rt = runtimes[key]
        table.insert(accountViews, {
          key = key,
          kind = rt.account.kind,
          label = rt.account.label,
          email = rt.identity and rt.identity.email,
          home = rt.account.home,
          launch = launchCommand(rt),
          status = statusOf(rt),
          snapshot = rt.snapshot,
          error = rt.error,
          stale = rt.stale,
          busy = scheduler.isBusy(rt.schedule, now),
          signingIn = rt.signingInSince ~= nil,
          canSignIn = canSignIn,
          duplicateOf = rt.duplicateOf and runtimes[rt.duplicateOf] and (runtimes[rt.duplicateOf].account.label or noctalia.tr("accounts.default")),
        })
      end
      table.insert(views, {
        id = p.id,
        name = p.name,
        brand = p.brand,
        hint = p.signInHint(runtimes[p.id].ctx),
        canAdd = canSignIn,
        accounts = accountViews,
      })
    end
  end
  noctalia.state.set(state.REPORT, { lastRefreshAt = lastRefreshAt, providers = views })
end

-- ── Notifications ──────────────────────────────────────────────────────────

local function sendNotifications(rt: Runtime, previous: model.Snapshot?)
  local enabled = state.config("notify", true)
  local _, critical = state.thresholds()
  local messages = notify.messages(displayName(rt), previous, rt.snapshot, rt.notified, {
    critical = critical,
    low = enabled,
    reset = enabled,
    now = base.now(),
    tr = noctalia.tr,
    duration = time.duration,
  })
  for _, message in messages do
    noctalia.notify(message.title, message.body)
  end
end

-- ── Fetching ───────────────────────────────────────────────────────────────

local function withHint(rt: Runtime, err: model.ProviderError): model.ProviderError
  if err.code == E.NotConfigured or err.code == E.Expired or err.code == E.Auth then
    err.hint = if rt.account.kind == "default" then rt.provider.signInHint(rt.ctx) else noctalia.tr("accounts.hint")
  end
  return err
end

-- Starts a fetch; the reply publishes when it lands. The caller publishes the
-- "busy" state once for every fetch it started.
local function fetchAccount(rt: Runtime, now: number)
  local p = rt.provider
  local generation = scheduler.start(rt.schedule, now)
  local ok, thrown = pcall(p.fetch, rt.ctx, function(snapshot, err)
    local finishedAt = base.now()
    if not scheduler.finish(rt.schedule, generation, finishedAt, intervalSeconds(), err) then
      return -- superseded by a newer request
    end
    lastRefreshAt = finishedAt
    if err then
      rt.error = withHint(rt, err)
      rt.stale = rt.snapshot ~= nil
      noctalia.log(`[headroom] {rt.account.key}: {err.code}{if err.detail then " (" .. err.detail .. ")" else ""}`)
    else
      local previous = rt.snapshot
      rt.snapshot = snapshot
      rt.error = nil
      rt.stale = false
      sendNotifications(rt, previous)
      saveCache()
    end
    publish()
  end)
  if not ok then
    -- A bug in an adapter must not take the other accounts down with it.
    noctalia.log(`[headroom] {rt.account.key}: adapter error: {thrown}`)
    rt.error = model.err(E.Parse, "adapter error")
    scheduler.finish(rt.schedule, generation, base.now(), intervalSeconds(), rt.error)
  end
end

local function tick(recheckSignIn: boolean?)
  local now = base.now()
  local changed = false
  if recheckSignIn or now - lastSyncAt >= SIGN_IN_CHECK_SECONDS then
    lastSyncAt = now
    changed = syncAccounts()
  end
  local resync = false
  eachListed(function(rt)
    local waiting = rt.signingInSince ~= nil
    if waiting and now - rt.signingInSince >= SIGN_IN_WAIT_SECONDS then
      rt.signingInSince = nil
      changed = true
    end
    if (recheckSignIn or waiting or now - rt.checkedAt >= SIGN_IN_CHECK_SECONDS) and checkSignIn(rt, now) then
      changed = true
      if rt.configured and rt.provider.accounts then
        syncAccounts() -- it may be signed in to an account already shown
      end
    elseif waiting and rt.configured then
      -- Signing in again over an existing sign-in: the new one shows as a
      -- different identity.
      local before = rt.identity and rt.identity.id
      readIdentity(rt)
      if rt.identity and rt.identity.id ~= before then
        rt.signingInSince = nil
        rt.error = nil
        scheduler.force(rt.schedule, now)
        resync = true
      end
    end
    if rt.configured and rt.duplicateOf == nil and scheduler.isDue(rt.schedule, now) then
      fetchAccount(rt, now)
      changed = true
    end
  end)
  if resync then
    syncAccounts() -- it may no longer be a duplicate; the next tick fetches it
    changed = true
  end
  if changed then
    publish()
  end
end

-- A refresh request. Without `maxAge` (refresh button, R, IPC) every account
-- is fetched now, except one the API throttled: asking again before its wait
-- is over only extends it. With `maxAge` (opening the panel), only accounts
-- whose last good data is older than `maxAge` are fetched, and an account in
-- backoff after a failure keeps its backoff.
local function refresh(maxAge: number?)
  local now = base.now()
  eachListed(function(rt)
    local throttled = rt.error ~= nil and rt.error.code == E.RateLimited and not scheduler.isDue(rt.schedule, now)
    local wanted = if maxAge == nil
      then not throttled
      else rt.error == nil and (rt.stale or rt.snapshot == nil or now - (rt.snapshot.fetchedAt or 0) >= maxAge)
    if wanted then
      scheduler.force(rt.schedule, now)
    end
  end)
  tick(true)
end

-- ── Account commands ───────────────────────────────────────────────────────

-- Opens a terminal running the vendor's login in the account's folder. The
-- CLI writes the sign-in; the next ticks notice it.
local function signIn(rt: Runtime)
  local p = rt.provider
  local command = loginCommands[p.id]
  if command == nil then
    return
  end
  local intro = noctalia.tr("accounts.login_intro", {
    provider = p.name,
    account = rt.account.label or noctalia.tr("accounts.default"),
  })
  local shell = accounts.loginCommand(p.accounts, rt.account, command, intro, noctalia.tr("accounts.login_done"))
  if not noctalia.runInTerminal(shell) then
    noctalia.notifyError(noctalia.tr("accounts.no_terminal_title"), noctalia.tr("accounts.no_terminal_body"))
    return
  end
  rt.signingInSince = base.now()
  publish()
end

local function addAccount(providerId: string, label: string)
  local p = providersById[providerId]
  if p == nil or p.accounts == nil or isOff(p.id) or loginCommands[p.id] == nil then
    return
  end
  label = noctalia.string.trim(label):sub(1, LABEL_MAX)
  if label == "" then
    label = noctalia.tr("accounts.unnamed", { n = #(listed[p.id] or {}) + 1 })
  end
  local id = accounts.newId(accountRegistry, p.id, label)
  local home = accounts.addedHome(p.id, id)
  local made = home and noctalia.mkdirAll(home)
  if not made then
    noctalia.log(`[headroom] {p.id}: could not create an account folder`)
    return
  end
  accounts.add(accountRegistry, p.id, id, label)
  accounts.save(accountRegistry)
  syncAccounts()
  local rt = runtimes[`{p.id}:{home}`]
  if rt then
    signIn(rt)
  end
  publish()
end

local function renameAccount(rt: Runtime, label: string)
  label = noctalia.string.trim(label):sub(1, LABEL_MAX)
  if not accounts.rename(accountRegistry, rt.account, label) then
    return
  end
  accounts.save(accountRegistry)
  syncAccounts()
  publish()
end

local function removeAccount(rt: Runtime)
  local account = rt.account
  if account.kind == "added" then
    if not accounts.isAddedHome(account) then
      return
    end
    -- Headroom made this folder; it holds this account's sign-in and whatever
    -- the CLI wrote there since.
    noctalia.runAsync({ "rm", "-rf", "--", account.home })
  end
  if not accounts.forget(accountRegistry, account) then
    return
  end
  accounts.save(accountRegistry)
  runtimes[account.key] = nil
  cached[account.key] = nil
  syncAccounts()
  saveCache()
  publish()
end

local function onCommand(command)
  if type(command) ~= "table" then
    return
  end
  local action = command.action
  if action == "refresh" then
    refresh(tonumber(command.maxAge))
  elseif action == "add" and type(command.provider) == "string" then
    addAccount(command.provider, if type(command.label) == "string" then command.label else "")
  elseif (action == "sign_in" or action == "rename" or action == "remove") and type(command.key) == "string" then
    local rt = runtimes[command.key]
    if rt == nil then
      return
    elseif action == "sign_in" then
      signIn(rt)
    elseif action == "rename" then
      renameAccount(rt, if type(command.label) == "string" then command.label else "")
    else
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
  -- A provider may have been turned on or off.
  syncAccounts()
  -- A new interval applies from now on; reschedule so a shorter one takes effect.
  local now = base.now()
  eachListed(function(rt)
    if rt.error == nil and rt.snapshot ~= nil then
      rt.schedule.nextAt = math.min(rt.schedule.nextAt, now + intervalSeconds())
    end
  end)
  publish()
end

noctalia.state.watch(state.COMMAND, onCommand)

loadCache()
noctalia.setUpdateInterval(TICK_MS)
tick(true)
publish() -- even with nothing signed in, so surfaces leave their "starting" state
