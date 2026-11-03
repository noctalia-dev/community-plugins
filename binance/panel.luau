--!nonstrict
-- Binance panel: a header (title, freshness, privacy, refresh), the tabs,
-- status banners, then the selected tab's content. Keyless it shows only
-- Overview (what the plugin does and how to connect), Watchlist and Account.
--
-- Presentation only: it draws the report the service publishes and sends
-- commands back through lib/state.luau. Panel-local state (tab, filters,
-- open forms) lives in `ctx`, which every tab module reads and updates.

local state = require("./lib/state.luau")
local fmt = require("./ui/fmt.luau")
local parts = require("./ui/parts.luau")
local status = require("./ui/status.luau")
local overview = require("./ui/overview.luau")
local holdings = require("./ui/holdings.luau")
local wallets = require("./ui/wallets.luau")
local watchlist = require("./ui/watchlist.luau")
local account = require("./ui/account.luau")

local TABS = {
  { id = "overview", module = overview, connectedOnly = false },
  { id = "holdings", module = holdings, connectedOnly = true },
  { id = "wallets", module = wallets, connectedOnly = true },
  { id = "watchlist", module = watchlist, connectedOnly = false },
  { id = "account", module = account, connectedOnly = false },
}

-- How long a copy shows its check mark.
local COPIED_MS = 2000

local report = noctalia.state.get(state.REPORT)
local isOpen = false
local lastRenderAt = 0
local canOpenUrls = noctalia.commandExists("xdg-open")

local render

local ctx = { tab = "overview", canOpenUrls = canOpenUrls }

function ctx.openSettings()
  panel.close()
  noctalia.openSettings()
end

-- Forms, filters and folds start over on every open; the tab is kept.
local function resetCtx()
  ctx.holdingsFilter = "all"
  ctx.showDust = false
  ctx.folded = {}
  ctx.watchEdit = false
  ctx.watchDraft = ""
  ctx.watchSeed = (ctx.watchSeed or 0) + 1 -- fresh key empties the input
  ctx.alertForm = nil
  ctx.custom = { open = false, seed = 0, from = "", to = "" }
  ctx.chartHover = nil
  ctx.chartDays = {}
  ctx.confirmDisconnect = nil
  ctx.copied = nil -- { key, untilAt }
  ctx.exportAskedAt = nil
  ctx.depositDraft = ""
  ctx.targetForm = nil
  ctx.depositSeed = (ctx.depositSeed or 0) + 1
end

resetCtx()

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

function ctx.render()
  render()
end

function ctx.setTab(id: string)
  ctx.tab = id
  ctx.chartHover = nil
  render()
end

-- A copy button that turns into a check for a moment. With `action`, the
-- service does the copying (the public key is in its hands, not ours).
function ctx.copyButton(text: string?, key: string, label: string, action: (() -> ())?)
  local copied = ctx.copied and ctx.copied.key == key and fmt.now() < ctx.copied.untilAt
  return ui.button({
    key = `copy-{key}`,
    text = if copied then tr("panel.copied") else label,
    glyph = if copied then "check" else "copy",
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      if action then
        action()
      elseif text then
        noctalia.copyToClipboard(text, "text/plain")
      end
      ctx.copied = { key = key, untilAt = fmt.now() + COPIED_MS }
      render()
    end,
  })
end

-- Opens a binance.com page in the browser, or copies its address when there
-- is no xdg-open. Callers pass a constant or a lib/links.luau URL (symbol
-- validated); xdg-open runs as an argv, no shell.
function ctx.openUrl(url: string)
  if canOpenUrls then
    noctalia.runAsync({ "xdg-open", url })
  else
    noctalia.copyToClipboard(url, "text/plain")
  end
end

function ctx.linkButton(url: string, label: string)
  if not canOpenUrls then
    return ctx.copyButton(url, url, label)
  end
  return ui.button({
    text = label,
    glyph = "external-link",
    variant = "ghost",
    controlSize = "sm",
    onClick = function()
      ctx.openUrl(url)
    end,
  })
end

local function isConnected(): boolean
  return type(report) == "table" and report.mode == "connected"
end

local function visibleTabs()
  local out = {}
  for _, tab in TABS do
    if isConnected() or not tab.connectedOnly then
      table.insert(out, tab)
    end
  end
  return out
end

-- ── Header, tabs, banners ─────────────────────────────────────────────────

local function subtitle(): string
  if type(report) ~= "table" then
    return tr("panel.starting")
  end
  local busy = status.busyText(report)
  if busy then
    return busy
  elseif report.status.lastRefreshAt then
    return tr("panel.updated", { ago = fmt.ago(report.status.lastRefreshAt) })
  end
  return tr("panel.not_refreshed")
end

local function header()
  local hasReport = type(report) == "table"
  local privacy = hasReport and report.privacy == true
  return ui.row({ align = "center", gap = 6, key = "header" }, parts.nodes(
    ui.glyph({ name = "currency-bitcoin", size = 20, color = "primary" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      parts.caption(subtitle(), nil, { maxLines = 1 }),
    }),
    -- Keyless there are no amounts to hide.
    if not isConnected() then nil else ui.button({
      glyph = if privacy then "eye-off" else "eye",
      variant = "ghost",
      controlSize = "sm",
      enabled = hasReport,
      selected = privacy,
      tooltip = tr(if privacy then "panel.privacy_off" else "panel.privacy_on"),
      onClick = function()
        state.setPrivacy(not privacy)
      end,
    }),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      enabled = hasReport and not report.status.busy,
      tooltip = tr("panel.refresh"),
      onClick = function()
        state.requestRefresh()
      end,
    }),
    ui.button({
      glyph = "settings",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.settings"),
      onClick = function()
        ctx.openSettings()
      end,
    })
  ))
end

local function tabBar(tabs)
  local buttons = {}
  local attention = status.accountNeedsAttention(report)
  for _, tab in tabs do
    local flagged = tab.id == "account" and attention
    table.insert(buttons, ui.button({
      key = tab.id,
      text = tr(`panel.tab.{tab.id}`),
      glyph = if flagged then "point-filled" else nil,
      variant = "ghost",
      controlSize = "sm",
      fontSize = 12,
      selected = ctx.tab == tab.id,
      tooltip = if flagged then tr("panel.tab.account_attention") else nil,
      onClick = function()
        ctx.setTab(tab.id)
      end,
    }))
  end
  -- Sized to their labels: equal widths truncate "Overview" and "Watchlist" at 460 px.
  return ui.row({ gap = 2, justify = "space_between", key = "tabs" }, buttons)
end

local function issueAction(issue)
  if issue.action == "copy_install" then
    return ctx.copyButton(status.INSTALL_CRYPTOGRAPHY, "install", tr("panel.copy_command"))
  elseif issue.action == "retry_keyring" then
    return ui.button({
      text = tr("panel.retry"),
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        state.retryKeyring()
      end,
    })
  elseif issue.action == "refresh" then
    return ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.refresh"),
      enabled = not report.status.busy,
      onClick = function()
        state.requestRefresh()
      end,
    })
  elseif issue.action == "account" and ctx.tab ~= "account" then
    return ui.button({
      text = tr("panel.tab.account"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        ctx.setTab("account")
      end,
    })
  end
  return nil
end

-- Problems the user must act on get a full banner each. Conditions that
-- heal by themselves (rate limit, network) share one quiet line, so the
-- portfolio stays at the top; their details are in its tooltip.
local function banners()
  local out, quiet = {}, {}
  for _, issue in status.issues(report) do
    if issue.tone == "error" then
      table.insert(out, parts.banner(issue.tone, issue.glyph, issue.title, issue.body, issueAction(issue), issue.id))
    else
      table.insert(quiet, issue)
    end
  end
  if #quiet > 0 then
    local titles, details = {}, {}
    for _, issue in quiet do
      table.insert(titles, issue.title)
      table.insert(details, if issue.body then `{issue.title}: {issue.body}` else issue.title)
    end
    table.insert(out, ui.row({
      key = "notices",
      gap = 8,
      align = "center",
      paddingH = 4,
      tooltip = table.concat(details, "\n"),
    }, parts.nodes(
      ui.glyph({ name = quiet[1].glyph, size = 14, color = "on_surface_variant" }),
      parts.caption(table.concat(titles, " · "), nil, { flexGrow = 1, maxLines = 1 }),
      issueAction(quiet[1])
    )))
  end
  return out
end

-- ── Render ────────────────────────────────────────────────────────────────

function render()
  if not isOpen then
    return
  end
  lastRenderAt = fmt.now()

  local body = { header() }
  local content
  if type(report) ~= "table" then
    content = { parts.card({ parts.caption(tr("panel.starting_body"), nil, { maxLines = 3 }) }, { key = "starting" }) }
  elseif (report.v or 1) > state.VERSION then
    content = { parts.banner("error", "alert-circle", fmt.errorTitle("unsupported_version"), tr("panel.unsupported_body"), nil, "version") }
  else
    local tabs = visibleTabs()
    local current = tabs[1]
    for _, tab in tabs do
      if tab.id == ctx.tab then
        current = tab
      end
    end
    ctx.tab = current.id
    table.insert(body, tabBar(tabs))
    content = banners()
    for _, node in current.module.render(report, ctx) do
      table.insert(content, node)
    end
  end
  table.insert(body, ui.scroll({ flexGrow = 1, gap = 12, key = `scroll-{ctx.tab}` }, content))
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, body))
end

-- Chart hover: named globals so a leave that arrives after a re-render still
-- reaches a live handler (declarative-ui: graph pointer tracking).
function onChartMove(normX)
  local count = #ctx.chartDays
  if count == 0 then
    return
  end
  local index = math.clamp(math.floor((tonumber(normX) or 0) * (count - 1) + 0.5) + 1, 1, count)
  if index ~= ctx.chartHover then
    ctx.chartHover = index
    render()
  end
end

function onChartLeave()
  if ctx.chartHover ~= nil then
    ctx.chartHover = nil
    render()
  end
end

-- ── Host callbacks ────────────────────────────────────────────────────────

noctalia.state.watch(state.REPORT, function(value)
  report = value
  -- A finished alert edit or watchlist change arrives as a new report; the
  -- forms close themselves on save, so nothing else to reconcile here.
  render()
end)

function onOpen(_context)
  isOpen = true
  report = noctalia.state.get(state.REPORT)
  panel.setWantsSecondTicks(true)
  state.panelOpen(true)
  render()
end

function onClose()
  isOpen = false
  resetCtx()
  panel.setWantsSecondTicks(false)
  state.panelOpen(false)
end

-- Ticks keep "updated 2m ago" and countdowns honest. A copy check or a
-- pending disconnect confirmation redraws as soon as it lapses.
function update()
  if not isOpen then
    return
  end
  local now = fmt.now()
  local lapsed = (ctx.copied and now >= ctx.copied.untilAt)
    or (ctx.confirmDisconnect and now >= ctx.confirmDisconnect)
  if ctx.copied and now >= ctx.copied.untilAt then
    ctx.copied = nil
  end
  if ctx.confirmDisconnect and now >= ctx.confirmDisconnect then
    ctx.confirmDisconnect = nil
  end
  local limited = type(report) == "table" and report.status.rateLimit ~= nil
  local every = if limited then 1000 else 15000
  if lapsed or now - lastRenderAt >= every then
    render()
  end
end
