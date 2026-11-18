--!nonstrict
-- Headroom panel: one card per signed-in provider, with every usage window of
-- each of its accounts, and the controls to add, sign in and remove accounts.
-- Presentation only; refreshes and account changes are requested from the
-- service through shared state.

local state = require("./lib/state.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")
local cards = require("./ui/cards.luau")

-- How long a removal waits for its second click, and a copy shows its check.
local CONFIRM_SECONDS = 5
local COPIED_SECONDS = 2
-- Opening the panel fetches anything older than this, in the background.
-- Long enough that opening it again and again adds no requests: the usage
-- endpoints throttle, and Claude's budget is shared with Claude Code.
local OPEN_FRESHNESS = 120

local report = noctalia.state.get(state.REPORT)
local isOpen = false
local lastRenderAt = 0

-- What the panel is doing, one thing at a time:
--   { kind = "idle" }
--   { kind = "adding", provider, draft }       the add-account form is open
--   { kind = "renaming", key, draft }          an account's name is being edited
--   { kind = "confirming", key, untilAt }      a removal waits for its second click
local IDLE = { kind = "idle" }
local mode = IDLE
-- The copy button's check mark: { key, untilAt }, alongside any mode.
local copied: { key: string, untilAt: number }? = nil

local render

local function setMode(next)
  mode = next
  render()
end

-- Drops what has timed out. Returns true when something did.
local function expire(now: number): boolean
  local lapsed = false
  if mode.kind == "confirming" and now >= mode.untilAt then
    mode, lapsed = IDLE, true
  end
  if copied and now >= copied.untilAt then
    copied, lapsed = nil, true
  end
  return lapsed
end

-- The vendor's own usage page, one click from its card. xdg-open runs as an
-- argv (no shell), and the URL is a constant from the provider's brand.
local canOpenUrls = noctalia.commandExists("xdg-open")

local options = {
  onOpenDashboard = if canOpenUrls
    then function(url: string)
      noctalia.runAsync({ "xdg-open", url })
      panel.close()
    end
    else nil,
  onRefresh = function()
    state.requestRefresh()
  end,
  onSignIn = state.signIn,
  onUnhide = state.unhide,
  onRemove = function(key: string)
    if mode.kind == "confirming" and mode.key == key then
      state.removeAccount(key)
      setMode(IDLE)
    else
      setMode({ kind = "confirming", key = key, untilAt = view.now() + CONFIRM_SECONDS })
    end
  end,
  onCopy = function(key: string, text: string)
    noctalia.copyToClipboard(text, "text/plain")
    copied = { key = key, untilAt = view.now() + COPIED_SECONDS }
    render()
  end,
  onAddOpen = function(id: string)
    setMode({ kind = "adding", provider = id, draft = "" })
  end,
  onAddChange = function(text: string)
    if mode.kind == "adding" then
      mode.draft = text
    end
  end,
  onAddSubmit = function(id: string)
    state.addAccount(id, mode.draft or "")
    setMode(IDLE)
  end,
  onRenameOpen = function(key: string, label: string)
    setMode({ kind = "renaming", key = key, draft = label })
  end,
  onRenameChange = function(text: string)
    if mode.kind == "renaming" then
      mode.draft = text
    end
  end,
  onRenameSubmit = function(key: string)
    state.renameAccount(key, mode.draft or "")
    setMode(IDLE)
  end,
  onAddCancel = function()
    setMode(IDLE)
  end,
  onRenameCancel = function()
    setMode(IDLE)
  end,
}

local function providers()
  return if type(report) == "table" and type(report.providers) == "table" then report.providers else {}
end

local function isRefreshing(): boolean
  for _, provider in providers() do
    for _, account in provider.accounts do
      if account.busy then
        return true
      end
    end
  end
  return false
end

-- A provider shows as a card unless its only account isn't signed in.
local function isConnected(provider): boolean
  local accounts = provider.accounts
  return #accounts > 1 or accounts[1].phase ~= "signed_out"
end

-- When the newest numbers were fetched.
local function subtitle(now: number): string
  if type(report) ~= "table" then
    return noctalia.tr("panel.starting")
  elseif isRefreshing() then
    return noctalia.tr("status.refreshing")
  end
  local newest = nil
  for _, provider in providers() do
    for _, account in provider.accounts do
      local at = account.snapshot and account.snapshot.fetchedAt
      if at and (newest == nil or at > newest) then
        newest = at
      end
    end
  end
  return if newest then noctalia.tr("panel.updated", { ago = time.ago(now - newest) }) else noctalia.tr("panel.not_refreshed")
end

-- ── Render ────────────────────────────────────────────────────────────────

function render()
  if not isOpen then
    return
  end
  local now = view.now()
  lastRenderAt = now
  expire(now)
  options.now = now
  options.interval = if type(report) == "table" and report.interval then report.interval else 300
  options.mode = mode
  options.copied = copied and copied.key

  local connected, disconnected = {}, {}
  for _, provider in providers() do
    if isConnected(provider) or (mode.kind == "adding" and mode.provider == provider.id) then
      table.insert(connected, cards.providerCard(provider, options))
    else
      table.insert(disconnected, cards.disconnectedRow(provider, options))
    end
  end

  local content = if #connected == 0 then { cards.emptyState() } else connected
  if #disconnected > 0 then
    table.insert(content, ui.column({ gap = 8, key = "disconnected" }, disconnected))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Headroom", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        cards.caption(subtitle(now)),
      }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        enabled = not isRefreshing(),
        tooltip = noctalia.tr("panel.refresh_tooltip"),
        onClick = options.onRefresh,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.settings_tooltip"),
        onClick = function()
          noctalia.openSettings()
        end,
      }),
    }),
    ui.scroll({ flexGrow = 1, gap = 12 }, content),
  }))
end

-- ── Host callbacks ────────────────────────────────────────────────────────

noctalia.state.watch(state.REPORT, function(value)
  report = value
  render()
end)

function onOpen(_context)
  isOpen = true
  report = noctalia.state.get(state.REPORT)
  panel.setWantsSecondTicks(true)
  render()
  state.requestRefresh(OPEN_FRESHNESS)
end

function onClose()
  isOpen = false
  mode, copied = IDLE, nil
  panel.setWantsSecondTicks(false)
end

-- Countdowns show minutes, so a re-render every 15s is plenty; a pending
-- removal or copy check redraws as soon as it lapses.
function update()
  if isOpen then
    local now = view.now()
    if expire(now) or now - lastRenderAt >= 15 then
      render()
    end
  end
end

function onKey(chord, pressed)
  if pressed and chord == "r" then
    state.requestRefresh()
  end
end
