--!nonstrict
-- Headroom panel: one card per signed-in provider, with every usage window of
-- each of its accounts, and the controls to add, sign in and remove accounts.
--
-- Each window shows its usage meter with a thin time track beneath it: when the
-- meter runs ahead of the time track you are burning faster than the window
-- allows, and the pace line says when you would run out. Presentation only;
-- refreshes and account changes are requested from the service through
-- shared state.

local state = require("./lib/state.luau")
local view = require("./lib/view.luau")
local time = require("./lib/time.luau")
local cards = require("./ui/cards.luau")

local report = noctalia.state.get(state.REPORT)
local isOpen = false
local lastRenderAt = 0

-- How long a removal waits for its second click, and a copy shows its check.
local CONFIRM_SECONDS = 5
local COPIED_SECONDS = 2

-- Panel-only state, reset when the panel closes.
local adding: string? = nil -- provider whose add form is open
local addDraft = ""
local renaming: string? = nil -- account whose name is being edited
local renameDraft = ""
local confirming: { key: string, untilAt: number }? = nil
local copied: { key: string, untilAt: number }? = nil

local render

-- The vendor's own usage page, one click from its card. xdg-open runs as an
-- argv (no shell), and the URL is a constant from the provider's brand.
local canOpenUrls = noctalia.commandExists("xdg-open")

local cardOptions = {
  onOpenDashboard = if canOpenUrls
    then function(url: string)
      noctalia.runAsync({ "xdg-open", url })
      panel.close()
    end
    else nil,
  onRefresh = function()
    state.requestRefresh()
  end,
  onSignIn = function(key: string)
    state.signIn(key)
  end,
  onRemove = function(key: string)
    if confirming and confirming.key == key and view.now() < confirming.untilAt then
      confirming = nil
      state.removeAccount(key)
    else
      confirming = { key = key, untilAt = view.now() + CONFIRM_SECONDS }
    end
    render()
  end,
  onCopy = function(key: string, text: string)
    noctalia.copyToClipboard(text, "text/plain")
    copied = { key = key, untilAt = view.now() + COPIED_SECONDS }
    render()
  end,
  onAddOpen = function(id: string)
    adding, addDraft = id, ""
    render()
  end,
  onAddCancel = function()
    adding = nil
    render()
  end,
  onAddChange = function(text: string)
    addDraft = text
  end,
  onAddSubmit = function(id: string)
    adding = nil
    state.addAccount(id, addDraft)
    render()
  end,
  onRenameOpen = function(key: string, current: string)
    renaming, renameDraft = key, current
    render()
  end,
  onRenameCancel = function()
    renaming = nil
    render()
  end,
  onRenameChange = function(text: string)
    renameDraft = text
  end,
  onRenameSubmit = function(key: string)
    renaming = nil
    state.renameAccount(key, renameDraft)
    render()
  end,
}

local function isRefreshing(): boolean
  for _, provider in (if type(report) == "table" then report.providers else {}) do
    for _, account in provider.accounts or {} do
      if account.busy then
        return true
      end
    end
  end
  return false
end

-- A provider shows as a card unless its only account isn't signed in.
local function isConnected(provider): boolean
  local accounts = provider.accounts or {}
  return #accounts > 1 or (accounts[1] ~= nil and accounts[1].status ~= "absent")
end

local function subtitle(now: number): string
  if type(report) ~= "table" then
    return noctalia.tr("panel.starting")
  elseif isRefreshing() then
    return noctalia.tr("status.refreshing")
  elseif report.lastRefreshAt then
    return noctalia.tr("panel.updated", { ago = time.ago(now - report.lastRefreshAt) })
  end
  return noctalia.tr("panel.not_refreshed")
end

-- ── Render ────────────────────────────────────────────────────────────────

function render()
  if not isOpen then
    return
  end
  local now = view.now()
  lastRenderAt = now
  cardOptions.adding = adding
  cardOptions.renaming = renaming
  cardOptions.confirmingRemove = if confirming and now < confirming.untilAt then confirming.key else nil
  cardOptions.copied = if copied and now < copied.untilAt then copied.key else nil

  local connected, disconnected = {}, {}
  if type(report) == "table" and type(report.providers) == "table" then
    for _, provider in report.providers do
      if isConnected(provider) or adding == provider.id then
        table.insert(connected, cards.providerCard(provider, now, cardOptions))
      else
        table.insert(disconnected, cards.disconnectedRow(provider, cardOptions))
      end
    end
  end

  local content
  if #connected == 0 then
    content = { cards.emptyState() }
    for _, row in disconnected do
      table.insert(content, row)
    end
  else
    content = connected
    if #disconnected > 0 then
      table.insert(content, ui.column({ gap = 8, key = "disconnected" }, disconnected))
    end
  end

  local refreshing = isRefreshing()

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
        enabled = not refreshing,
        tooltip = noctalia.tr("panel.refresh_tooltip"),
        onClick = function()
          state.requestRefresh()
        end,
      }),
      ui.button({
        glyph = "settings",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("panel.settings_tooltip"),
        onClick = function()
          panel.close()
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

-- Opening the panel is a request to see current numbers: show what we have
-- immediately, and fetch anything older than this in the background. Long
-- enough that opening the panel again and again doesn't add requests: the
-- usage endpoints throttle, and Claude's limit is shared with Claude Code.
local OPEN_FRESHNESS = 120

function onOpen(_context)
  isOpen = true
  report = noctalia.state.get(state.REPORT)
  panel.setWantsSecondTicks(true)
  render()
  state.requestRefresh(OPEN_FRESHNESS)
end

function onClose()
  isOpen = false
  adding, renaming, confirming, copied = nil, nil, nil, nil
  panel.setWantsSecondTicks(false)
end

-- Second ticks keep "updated 2m ago" and the countdowns honest; minute
-- precision is all they show, so a re-render every 15s is plenty. A pending
-- removal or copy check redraws as soon as it lapses.
function update()
  if not isOpen then
    return
  end
  local now = view.now()
  local lapsed = (confirming and now >= confirming.untilAt) or (copied and now >= copied.untilAt)
  if lapsed then
    confirming = if confirming and now < confirming.untilAt then confirming else nil
    copied = if copied and now < copied.untilAt then copied else nil
  end
  if lapsed or now - lastRenderAt >= 15 then
    render()
  end
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "r" then
    state.requestRefresh()
  elseif chord == "escape" then
    panel.close()
  end
end
