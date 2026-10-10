--!nonstrict
-- Card components: the provider card (accounts, windows, error banner, notes,
-- the add-account form), the disconnected row and the empty state, plus the
-- logo and caption used by the bar as well. Pure functions of their
-- arguments: the panel owns the state (which form is open, which removal is
-- being confirmed) and passes it in through `options`.

local theme = require("../lib/theme.luau")
local view = require("../lib/view.luau")
local time = require("../lib/time.luau")

local M = {}

local CARD_FILL = "surface_variant/0.45"
local TRACK = "on_surface/0.10"

-- Errors the vendor's login fixes.
local SIGN_IN_ERRORS = { not_configured = true, expired = true, auth = true }

-- Panel options:
--   onOpenDashboard(url)?   shows the usage-page button when given
--   onRefresh()
--   onSignIn(key), onRemove(key), onCopy(key, text)
--   adding: string?         id of the provider whose add form is open
--   onAddOpen(id), onAddCancel(), onAddChange(text), onAddSubmit(id)
--   renaming: string?       key of the account whose name is being edited
--   onRenameOpen(key), onRenameCancel(), onRenameChange(text), onRenameSubmit(key)
--   confirmingRemove: string?, copied: string?   account keys
export type Options = { [string]: any }

function M.logo(provider, size: number, opacity: number?)
  local path = theme.logo(provider)
  if path then
    return ui.image({ path = path, width = size, height = size, fit = "contain", opacity = opacity or 1 })
  end
  return ui.glyph({ name = provider.brand.glyph, size = size, color = "on_surface", opacity = opacity or 1 })
end

function M.caption(text: string, color: string?, extra)
  local props = { text = text, fontSize = 11, color = color or "on_surface_variant" }
  if extra then
    for k, v in extra do
      props[k] = v
    end
  end
  return ui.label(props)
end

local function needsSignIn(account): boolean
  return account.status == "absent" or (account.status == "error" and account.error ~= nil and SIGN_IN_ERRORS[account.error.code] == true)
end

local function signInButton(account, options, variant: string?)
  return ui.button({
    text = noctalia.tr(if account.signingIn then "accounts.sign_in_again" else "accounts.sign_in"),
    variant = variant or "outline",
    controlSize = "sm",
    tooltip = noctalia.tr("accounts.sign_in_tooltip"),
    onClick = function()
      options.onSignIn(account.key)
    end,
  })
end

local function windowRow(window, now: number, dimmed: boolean)
  local severity = view.severity(window, now)
  local paceText, paceColor, pace = view.pace(window, now)
  local resets = view.resetsIn(window, now)

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = window.label, fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = view.percent(window, view.showsRemaining()),
        fontSize = 13,
        fontWeight = "semibold",
        color = view.textColor(severity),
      }),
    }),
    ui.progress({
      progress = view.shownPercent(window) / 100,
      height = 8,
      radius = 4,
      fill = theme.meterColor(severity),
      track = TRACK,
    }),
  }

  if pace then
    -- The time track, on the same scale as the meter above it: time elapsed
    -- under a "used" meter, time remaining under a "left" one. A meter that
    -- outruns its track (used) or falls short of it (left) is burning fast.
    local remaining = view.showsRemaining()
    local fraction = if remaining then 1 - pace.elapsedFraction else pace.elapsedFraction
    table.insert(children, ui.column({
      tooltip = noctalia.tr(if remaining then "panel.remaining_tooltip" else "panel.elapsed_tooltip", {
        percent = math.floor(fraction * 100 + 0.5),
      }),
    }, {
      ui.progress({
        progress = fraction,
        height = 3,
        radius = 2,
        fill = "on_surface_variant/0.55",
        track = "on_surface/0.05",
      }),
    }))
  end

  if resets or paceText then
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      M.caption(resets or "", nil, { flexGrow = 1, maxLines = 1 }),
      M.caption(paceText or "", paceColor, { maxLines = 1 }),
    }))
  end

  return ui.column({ gap = 6, key = window.id, opacity = if dimmed then 0.6 else 1 }, children)
end

-- What failed and how to fix it; when older data is still shown below, says
-- how old it is. A sign-in problem offers the login itself; throttling offers
-- nothing, since retrying early only extends the wait.
local function errorBanner(account, now: number, options)
  local err = account.error
  local title = noctalia.tr(`error.{err.code}.title`)
  local body = err.hint or noctalia.tr(`error.{err.code}.body`)
  if account.snapshot and account.snapshot.fetchedAt then
    body = noctalia.tr("panel.showing_cached", { ago = time.ago(now - account.snapshot.fetchedAt) }) .. " " .. body
  end
  local action = if needsSignIn(account) and account.canSignIn
    then signInButton(account, options)
    elseif err.code == "rate_limited" then nil
    else ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.retry"),
      onClick = options.onRefresh,
    })
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
    ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
      M.caption(body, nil, { maxLines = 3 }),
    }),
    action,
  })
end

local function notesBlock(notes)
  local rows = {}
  for i, note in notes do
    table.insert(rows, ui.row({ align = "center", key = `note{i}` }, {
      M.caption(note.label, nil, { flexGrow = 1 }),
      ui.label({ text = note.value, fontSize = 11, fontWeight = "medium", color = "on_surface" }),
    }))
  end
  return ui.column({ gap = 4 }, rows)
end

-- One line on the account's state: plan, refreshing, cached, waiting.
local function accountStatus(account): string?
  local snapshot = account.snapshot
  if account.status == "absent" then
    return noctalia.tr(if account.signingIn then "accounts.waiting" else "accounts.not_signed_in")
  elseif account.busy then
    return noctalia.tr("status.refreshing")
  end
  local plan = snapshot and snapshot.plan or nil
  if account.stale and snapshot and account.status ~= "error" then
    return (if plan then plan .. " · " else "") .. noctalia.tr("status.cached")
  end
  return plan
end

-- An account signed in to the same account as an earlier one: two folders,
-- one set of limits. Says so instead of showing the numbers twice.
local function duplicateNotice(account, options)
  local children = {
    ui.glyph({ name = "copy", size = 18, color = theme.severityColor("warn") }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({
        text = noctalia.tr("accounts.duplicate_title", { account = account.duplicateOf }),
        fontSize = 12,
        fontWeight = "semibold",
        color = "on_surface",
      }),
      M.caption(noctalia.tr("accounts.duplicate_body"), nil, { maxLines = 3 }),
    }),
  }
  if account.canSignIn then
    table.insert(children, signInButton(account, options))
  end
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "on_surface/0.06" }, children)
end

-- Banner, meters and notes for one account.
local function accountBody(account, now: number, options): { any }
  if account.duplicateOf then
    return { duplicateNotice(account, options) }
  end
  local body = {}
  local snapshot = account.snapshot
  local dimmed = account.status == "error"
  if account.status == "error" and account.error then
    table.insert(body, errorBanner(account, now, options))
  end
  if account.status == "absent" then
    return body
  end
  if snapshot and #snapshot.windows > 0 then
    for _, window in snapshot.windows do
      table.insert(body, windowRow(window, now, dimmed))
    end
    if snapshot.notes and #snapshot.notes > 0 then
      table.insert(body, ui.separator({ color = "outline/0.25" }))
      table.insert(body, notesBlock(snapshot.notes))
    end
  elseif account.status == "loading" then
    table.insert(body, M.caption(noctalia.tr("status.fetching")))
  end
  return body
end

-- Name, state and the account's own actions: sign in, copy the command that
-- starts the CLI as it, remove (asks again before acting).
local function accountHeader(provider, account, options)
  local details = {}
  if account.email then
    table.insert(details, account.email)
  end
  if account.kind == "default" then
    table.insert(details, noctalia.tr("accounts.default_tooltip", { provider = provider.name }))
  elseif account.home then
    table.insert(details, account.home)
  end

  local name = account.label or noctalia.tr("accounts.default")
  if options.renaming == account.key then
    local function submit()
      options.onRenameSubmit(account.key)
    end
    return ui.row({ align = "center", gap = 6 }, {
      ui.input({
        key = `rename-{account.key}`,
        value = account.label or "",
        placeholder = noctalia.tr("accounts.default"),
        controlSize = "sm",
        focus = true,
        flexGrow = 1,
        onChange = options.onRenameChange,
        onSubmit = function(text)
          options.onRenameChange(text)
          submit()
        end,
      }),
      ui.button({ glyph = "check", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("accounts.rename_save"), onClick = submit }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("accounts.cancel"), onClick = options.onRenameCancel }),
    })
  end

  local status = accountStatus(account)
  local children = {
    ui.row({ gap = 6, align = "center", flexGrow = 1, tooltip = if #details > 0 then table.concat(details, "\n") else nil }, {
      ui.label({ text = name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      M.caption(status or " ", nil, { visible = status ~= nil, maxLines = 1, flexGrow = 1 }),
    }),
  }

  if account.status == "absent" and account.canSignIn then
    table.insert(children, signInButton(account, options))
  end
  table.insert(children, ui.button({
    glyph = "pencil",
    variant = "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr("accounts.rename_tooltip"),
    onClick = function()
      options.onRenameOpen(account.key, account.label or "")
    end,
  }))
  if account.launch then
    local copied = options.copied == account.key
    table.insert(children, ui.button({
      glyph = if copied then "check" else "terminal-2",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr(if copied then "accounts.copied" else "accounts.copy_tooltip", { provider = provider.name }),
      onClick = function()
        options.onCopy(account.key, account.launch)
      end,
    }))
  end
  if account.kind ~= "default" then
    local hides = account.kind == "found"
    local confirming = options.confirmingRemove == account.key
    table.insert(children, ui.button({
      glyph = if confirming then nil else (if hides then "eye-off" else "trash"),
      text = if confirming then noctalia.tr(if hides then "accounts.hide_confirm" else "accounts.remove_confirm") else nil,
      variant = if confirming then "destructive" else "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr(if hides then "accounts.hide_tooltip" else "accounts.remove_tooltip"),
      onClick = function()
        options.onRemove(account.key)
      end,
    }))
  end
  return ui.row({ align = "center", gap = 6 }, children)
end

local function addForm(provider, options)
  local function submit()
    options.onAddSubmit(provider.id)
  end
  return ui.column({ key = `add-{provider.id}`, gap = 8, padding = 12, radius = 10, fill = "primary/0.08" }, {
    ui.label({ text = noctalia.tr("accounts.add_title", { provider = provider.name }), fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
    ui.row({ gap = 6, align = "center" }, {
      ui.input({
        key = `add-input-{provider.id}`,
        placeholder = noctalia.tr("accounts.name_placeholder"),
        controlSize = "sm",
        focus = true,
        flexGrow = 1,
        onChange = options.onAddChange,
        onSubmit = function(text)
          options.onAddChange(text)
          submit()
        end,
      }),
      ui.button({ text = noctalia.tr("accounts.sign_in"), variant = "primary", controlSize = "sm", onClick = submit }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("accounts.cancel"),
        onClick = options.onAddCancel,
      }),
    }),
    M.caption(noctalia.tr("accounts.add_help", { provider = provider.name }), nil, { maxLines = 4 }),
  })
end

-- A provider with its accounts. With one account the card reads as before:
-- the plan under the name, then the meters. With several, each account gets
-- a header of its own.
function M.providerCard(provider, now: number, options: Options)
  local accounts = provider.accounts
  local single = #accounts == 1 and accounts[1].kind == "default"

  local subtitle = if single
    then accountStatus(accounts[1])
    else noctalia.tr("accounts.count", { n = #accounts })
  local headerChildren = {
    M.logo(provider, 22),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = provider.name, fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
      M.caption(subtitle or " ", nil, { visible = subtitle ~= nil }),
    }),
  }
  if provider.canAdd and options.adding ~= provider.id then
    table.insert(headerChildren, ui.button({
      glyph = "user-plus",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("accounts.add_tooltip", { provider = provider.name }),
      onClick = function()
        options.onAddOpen(provider.id)
      end,
    }))
  end
  if provider.brand.dashboard and options.onOpenDashboard then
    table.insert(headerChildren, ui.button({
      glyph = "external-link",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("panel.open_dashboard", { provider = provider.name }),
      onClick = function()
        options.onOpenDashboard(provider.brand.dashboard)
      end,
    }))
  end

  local body = { ui.row({ align = "center", gap = 10 }, headerChildren) }
  if options.adding == provider.id then
    table.insert(body, addForm(provider, options))
  end

  if single then
    for _, node in accountBody(accounts[1], now, options) do
      table.insert(body, node)
    end
  else
    for i, account in accounts do
      if i > 1 then
        table.insert(body, ui.separator({ color = "outline/0.25" }))
      end
      local section = { accountHeader(provider, account, options) }
      for _, node in accountBody(account, now, options) do
        table.insert(section, node)
      end
      table.insert(body, ui.column({ key = account.key, gap = 10 }, section))
    end
  end

  return ui.column({ key = provider.id, gap = 12, padding = 14, radius = 14, fill = CARD_FILL }, body)
end

-- A provider whose only account isn't signed in.
function M.disconnectedRow(provider, options: Options)
  local account = provider.accounts[1]
  local children = {
    M.logo(provider, 18, 0.5),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr("panel.not_connected", { provider = provider.name }), fontSize = 12, color = "on_surface_variant" }),
      M.caption(if account.signingIn then noctalia.tr("accounts.waiting") else provider.hint, "on_surface_variant/0.8", { maxLines = 2 }),
    }),
  }
  if account.canSignIn then
    table.insert(children, signInButton(account, options))
  end
  return ui.row({ key = `off-{provider.id}`, align = "center", gap = 10, padding = 10, radius = 12, border = "outline/0.25", borderWidth = 1 }, children)
end

function M.emptyState()
  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center", padding = 24 }, {
    ui.glyph({ name = "gauge", size = 40, color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.empty_title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = noctalia.tr("panel.empty_body"), fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

return M
