--!nonstrict
-- Card components: the provider card (accounts, windows, error banner, notes,
-- reset credits, the add-account form), the disconnected row and the empty
-- state, plus the logo and caption the bar uses too. Pure functions of their
-- arguments: the panel owns its state (which form is open, which removal is
-- being confirmed) and passes it in through `options`.

local theme = require("../lib/theme.luau")
local view = require("../lib/view.luau")
local time = require("../lib/time.luau")

local M = {}

local CARD_FILL = "surface_container/0.45"
local TRACK = "on_surface/0.10"
local DIVIDER = "outline_variant/0.25"

-- Errors the vendor's login fixes.
local SIGN_IN_ERRORS = { expired = true, auth = true }

-- Panel options:
--   now, interval           the clock and the refresh interval (seconds)
--   onOpenDashboard(url)?   shows the usage-page button when given
--   onRefresh()
--   onSignIn(key), onRemove(key), onCopy(key, text), onUnhide(providerId)
--   mode                    the panel's mode (panel.luau): which form is open,
--                           which removal is being confirmed
--   copied: string?         key of the account whose command was just copied
--   onAddOpen(id), onAddCancel(), onAddChange(text), onAddSubmit(id)
--   onRenameOpen(key, label), onRenameCancel(), onRenameChange(text), onRenameSubmit(key)
export type Options = { [string]: any }

function M.logo(provider, size: number, opacity: number?)
  local brand = provider.brand
  if brand.logo then
    return ui.image({ path = brand.logo, width = size, height = size, fit = "contain", opacity = opacity or 1 })
  end
  return ui.glyph({ name = brand.glyph, size = size, color = "on_surface", opacity = opacity or 1 })
end

function M.caption(text: string, color: string?, extra)
  local props = { text = text, fontSize = 11, color = color or "on_surface_variant" }
  for k, v in extra or {} do
    props[k] = v
  end
  return ui.label(props)
end

local function needsSignIn(account): boolean
  return account.phase == "signed_out" or (account.phase == "failing" and SIGN_IN_ERRORS[account.error.code] == true)
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

local function ghostButton(glyph: string, tooltip: string, onClick)
  return ui.button({ glyph = glyph, variant = "ghost", controlSize = "sm", tooltip = tooltip, onClick = onClick })
end

-- A meter with the share of the window's time that has passed marked on it,
-- on the same scale: elapsed under "used", remaining under "left". A fill
-- past the mark (used) or short of it (left) is burning too fast.
local function windowRow(window, now: number, dimmed: boolean)
  local severity = view.severity(window, now)
  local paceText, paceColor, pace = view.pace(window, now)
  local resets = view.resetsIn(window, now)
  local remaining = view.showsRemaining()
  local marker = pace and (if remaining then 1 - pace.elapsedFraction else pace.elapsedFraction)

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = window.label, fontSize = 13, color = "on_surface", flexGrow = 1, maxLines = 1 }),
      ui.label({
        text = view.percent(window, remaining),
        fontSize = 13,
        fontWeight = "semibold",
        color = view.textColor(severity),
      }),
    }),
    ui.column({
      tooltip = if marker
        then noctalia.tr(if remaining then "panel.remaining_tooltip" else "panel.elapsed_tooltip", {
          percent = math.floor(marker * 100 + 0.5),
        })
        else nil,
    }, {
      ui.progress({
        progress = view.shownPercent(window) / 100,
        height = 8,
        radius = 4,
        fill = theme.meterColor(severity),
        track = TRACK,
        marker = marker,
        markerColor = "on_surface/0.7",
      }),
    }),
  }

  if resets or paceText then
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      M.caption(resets or "", nil, { flexGrow = 1, maxLines = 1 }),
      M.caption(paceText or "", paceColor, { maxLines = 1 }),
    }))
  end

  return ui.column({ gap = 6, key = window.id, opacity = if dimmed then 0.6 else 1 }, children)
end

-- What failed and how to fix it; when older numbers are still shown below,
-- says how old they are. A sign-in problem offers the login itself;
-- throttling offers nothing, since retrying early only extends the wait.
local function errorBanner(account, options)
  local err = account.error
  local body = err.hint or noctalia.tr(`error.{err.code}.body`)
  if account.snapshot then
    body = noctalia.tr("panel.showing_cached", { ago = time.ago(options.now - account.snapshot.fetchedAt) }) .. " " .. body
  end
  local action = if needsSignIn(account) and account.canSignIn
    then signInButton(account, options)
    elseif err.code == "rate_limited" then nil
    else ghostButton("refresh", noctalia.tr("panel.retry"), options.onRefresh)
  return ui.row({ gap = 10, align = "center", padding = 10, radius = 10, fill = "error/0.12" }, {
    ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = noctalia.tr(`error.{err.code}.title`), fontSize = 12, fontWeight = "semibold", color = "on_surface" }),
      M.caption(body, nil, { maxLines = 3 }),
    }),
    action,
  })
end

local function factRow(key: string, label: string, value: string, valueColor: string?, tooltip: string?)
  return ui.row({ align = "center", gap = 8, key = key, tooltip = tooltip }, {
    M.caption(label, nil, { flexGrow = 1, maxLines = 1 }),
    ui.label({ text = value, fontSize = 11, fontWeight = "medium", color = valueColor or "on_surface", maxLines = 1 }),
  })
end

-- Resets the account can spend whenever it chooses: the count and the
-- soonest expiry, every credit in the tooltip.
local function creditsRow(snapshot, now: number)
  local count, expires, soon = view.creditSummary(snapshot, now)
  local lines = {}
  for _, credit in snapshot.resetCredits do
    local name = credit.label or noctalia.trp("resets.unnamed", credit.count)
    table.insert(lines, if credit.expiresAt then `{name} · {view.expiry(credit.expiresAt, now)}` else name)
  end
  return factRow(
    "credits",
    noctalia.tr("resets.label"),
    if expires then `{count} · {expires}` else count,
    if soon then theme.severityColor("warn") else nil,
    table.concat(lines, "\n")
  )
end

-- At the limit with a reset in hand: say so where it matters.
local function resetHint(provider, options)
  return ui.row({ key = "reset-hint", align = "center", gap = 8, padding = 8, radius = 8, fill = "primary/0.10" }, {
    ui.glyph({ name = "restore", size = 16, color = "primary" }),
    M.caption(noctalia.tr("resets.hint"), "on_surface", { flexGrow = 1, maxLines = 2 }),
    if provider.brand.dashboard and options.onOpenDashboard
      then ghostButton("external-link", noctalia.tr("panel.open_dashboard", { provider = provider.name }), function()
        options.onOpenDashboard(provider.brand.dashboard)
      end)
      else nil,
  })
end

-- One line on the account's state: plan, refreshing, cached, waiting.
local function accountStatus(account, options): string?
  if account.phase == "signed_out" then
    return noctalia.tr(if account.signingIn then "accounts.waiting" else "accounts.not_signed_in")
  elseif account.busy then
    return noctalia.tr("status.refreshing")
  end
  local snapshot = account.snapshot
  local plan = snapshot and snapshot.plan or nil
  if snapshot and account.phase ~= "failing" and view.isStale(account, options.interval, options.now) then
    local ago = noctalia.tr("panel.updated", { ago = time.ago(options.now - snapshot.fetchedAt) })
    return if plan then `{plan} · {ago}` else ago
  end
  return plan
end

-- Banner, meters, notes and reset credits for one account.
local function accountBody(provider, account, options): { any }
  local body = {}
  local now = options.now
  local snapshot = account.snapshot
  if account.phase == "failing" then
    table.insert(body, errorBanner(account, options))
  end
  if snapshot and #snapshot.windows > 0 then
    local dimmed = view.isStale(account, options.interval, now)
    local exhausted = false
    for _, window in snapshot.windows do
      table.insert(body, windowRow(window, now, dimmed))
      exhausted = exhausted or (window.limitReached and not view.isPastReset(window, now))
    end
    local hasCredits = view.creditCount(snapshot) > 0
    if exhausted and hasCredits and (snapshot.resetsUsable == nil or snapshot.resetsUsable > 0) then
      table.insert(body, resetHint(provider, options))
    end
    local facts = {}
    for i, note in snapshot.notes or {} do
      table.insert(facts, factRow(`note{i}`, note.label, note.value))
    end
    if hasCredits then
      table.insert(facts, creditsRow(snapshot, now))
    end
    if #facts > 0 then
      table.insert(body, ui.separator({ color = DIVIDER }))
      table.insert(body, ui.column({ gap = 4 }, facts))
    end
  elseif account.phase == "loading" then
    table.insert(body, M.caption(noctalia.tr("status.fetching")))
  end
  return body
end

-- Remove an added account (deletes its folder) or hide a found one; asks
-- again before acting.
local function removeButton(account, options)
  local hides = account.kind == "found"
  local confirming = options.mode.kind == "confirming" and options.mode.key == account.key
  return ui.button({
    glyph = if confirming then nil else (if hides then "eye-off" else "trash"),
    text = if confirming then noctalia.tr(if hides then "accounts.hide_confirm" else "accounts.remove_confirm") else nil,
    variant = if confirming then "destructive" else "ghost",
    controlSize = "sm",
    tooltip = noctalia.tr(if hides then "accounts.hide_tooltip" else "accounts.remove_tooltip"),
    onClick = function()
      options.onRemove(account.key)
    end,
  })
end

local function renameRow(account, options)
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
    ghostButton("check", noctalia.tr("accounts.rename_save"), submit),
    ghostButton("x", noctalia.tr("accounts.cancel"), options.onRenameCancel),
  })
end

-- Name, state and the account's own actions: sign in, rename, copy the
-- command that starts the CLI as it, remove.
local function accountHeader(provider, account, options)
  if options.mode.kind == "renaming" and options.mode.key == account.key then
    return renameRow(account, options)
  end
  local details = {}
  if account.email then
    table.insert(details, account.email)
  end
  if account.kind == "default" then
    table.insert(details, noctalia.tr("accounts.default_tooltip", { provider = provider.name }))
  elseif account.home then
    table.insert(details, account.home)
  end

  local status = accountStatus(account, options)
  local children = {
    ui.row({ gap = 6, align = "center", flexGrow = 1, tooltip = if #details > 0 then table.concat(details, "\n") else nil }, {
      ui.label({ text = account.name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      M.caption(status or " ", nil, { visible = status ~= nil, maxLines = 1, flexGrow = 1 }),
    }),
  }
  if account.phase == "signed_out" and account.canSignIn then
    table.insert(children, signInButton(account, options))
  end
  table.insert(children, ghostButton("pencil", noctalia.tr("accounts.rename_tooltip"), function()
    options.onRenameOpen(account.key, account.label or "")
  end))
  if account.launch then
    local copied = options.copied == account.key
    table.insert(children, ghostButton(
      if copied then "check" else "terminal-2",
      noctalia.tr(if copied then "accounts.copied" else "accounts.copy_tooltip", { provider = provider.name }),
      function()
        options.onCopy(account.key, account.launch)
      end
    ))
  end
  if account.kind ~= "default" then
    table.insert(children, removeButton(account, options))
  end
  return ui.row({ align = "center", gap = 6 }, children)
end

-- A folder signed in to the same account as an earlier one: one line under
-- the folder's own name instead of the same numbers twice. Signing in with
-- another account or removing it fixes it.
local function duplicateRow(account, options)
  local children = {
    ui.glyph({ name = "copy", size = 14, color = "on_surface_variant" }),
    ui.row({
      gap = 6,
      align = "center",
      flexGrow = 1,
      tooltip = noctalia.tr("accounts.duplicate_body", { account = account.duplicateOf })
        .. (if account.home then "\n" .. account.home else ""),
    }, {
      ui.label({ text = account.name, fontSize = 13, fontWeight = "semibold", color = "on_surface", maxLines = 1 }),
      M.caption(noctalia.tr("accounts.duplicate_title", { account = account.duplicateOf }), nil, { maxLines = 1, flexGrow = 1 }),
    }),
  }
  if account.canSignIn then
    table.insert(children, signInButton(account, options, "ghost"))
  end
  if account.kind ~= "default" then
    table.insert(children, removeButton(account, options))
  end
  return ui.row({ key = account.key, align = "center", gap = 6 }, children)
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
      ghostButton("x", noctalia.tr("accounts.cancel"), options.onAddCancel),
    }),
    M.caption(noctalia.tr("accounts.add_help", { provider = provider.name }), nil, { maxLines = 4 }),
  })
end

-- A provider with its accounts. With one account the card reads simply: the
-- plan under the name, then the meters. With several, each account gets a
-- header of its own.
function M.providerCard(provider, options: Options)
  local accounts = provider.accounts
  local single = #accounts == 1 and accounts[1].kind == "default"
  local adding = options.mode.kind == "adding" and options.mode.provider == provider.id

  local subtitle = if single then accountStatus(accounts[1], options) else noctalia.trp("accounts.count", #accounts)
  local header = {
    M.logo(provider, 22),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = provider.name, fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
      M.caption(subtitle or " ", nil, { visible = subtitle ~= nil }),
    }),
  }
  if provider.canAdd and not adding then
    table.insert(header, ghostButton("user-plus", noctalia.tr("accounts.add_tooltip", { provider = provider.name }), function()
      options.onAddOpen(provider.id)
    end))
  end
  if provider.brand.dashboard and options.onOpenDashboard then
    table.insert(header, ghostButton("external-link", noctalia.tr("panel.open_dashboard", { provider = provider.name }), function()
      options.onOpenDashboard(provider.brand.dashboard)
    end))
  end

  local body = { ui.row({ align = "center", gap = 10 }, header) }
  if adding then
    table.insert(body, addForm(provider, options))
  end

  if single then
    for _, node in accountBody(provider, accounts[1], options) do
      table.insert(body, node)
    end
  else
    for i, account in accounts do
      if i > 1 then
        table.insert(body, ui.separator({ color = DIVIDER }))
      end
      if account.duplicateOf then
        table.insert(body, duplicateRow(account, options))
      else
        local section = { accountHeader(provider, account, options) }
        for _, node in accountBody(provider, account, options) do
          table.insert(section, node)
        end
        table.insert(body, ui.column({ key = account.key, gap = 10 }, section))
      end
    end
  end

  if provider.hidden > 0 then
    table.insert(body, ui.row({ key = "hidden", align = "center", gap = 6 }, {
      M.caption(noctalia.trp("accounts.hidden", provider.hidden), nil, { flexGrow = 1 }),
      ui.button({
        text = noctalia.tr("accounts.unhide"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          options.onUnhide(provider.id)
        end,
      }),
    }))
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
  return ui.row({ key = `off-{provider.id}`, align = "center", gap = 10, padding = 10, radius = 12, border = DIVIDER, borderWidth = 1 }, children)
end

function M.emptyState()
  return ui.column({ gap = 10, align = "center", justify = "center", padding = 24 }, {
    ui.glyph({ name = "gauge", size = 40, color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.empty_title"), fontSize = 15, fontWeight = "semibold", color = "on_surface" }),
    ui.label({ text = noctalia.tr("panel.empty_body"), fontSize = 12, color = "on_surface_variant", textAlign = "center", maxLines = 4 }),
  })
end

return M
