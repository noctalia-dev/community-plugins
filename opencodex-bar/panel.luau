--!nonstrict
-- Native Noctalia panel for OpenCodex. It consumes the service snapshot and
-- never talks to OpenCodex itself. Layout follows CodexBar: every limit is one
-- row with a progress bar and a reset countdown.

local common = require("./common.luau")

-- Breathing room between sections. A separator applies its spacing above and
-- below the rule, so this is half the gap you actually see.
local SECTION_SPACING = 9

-- Mirrors the OpenCodex dashboard: its quota bar is green below the warn
-- threshold (`threshold: 80` in the GUI), amber at or above it, and a window is
-- "exhausted" at >= 99.5 (gui: `Kr(e){return e>=99.5}`). The hexes are its own
-- --green / --amber / --red custom properties, each with a light and dark value.
local WARN_USED = 80
local EXHAUSTED_USED = 99.5

local TONES = {
  ok = { light = "#0a7d5c", dark = "#4ecb9d" },
  warn = { light = "#9a4a08", dark = "#fbbf24" },
  over = { light = "#b91c1c", dark = "#f87171" },
}

-- The `theme_colors` setting swaps OpenCodex's palette for Noctalia's own
-- roles, so the plugin can sit inside a colour scheme instead of beside it.
local THEME_TONES = { ok = "primary", warn = "tertiary", over = "error" }

local function tone(name)
  if common.themeColors() then
    return THEME_TONES[name] or THEME_TONES.ok
  end
  local pair = TONES[name] or TONES.ok
  return noctalia.isDarkMode() and pair.dark or pair.light
end

-- Contribution-grid shading: one ramp of the "ok" tone. A role token takes an
-- alpha suffix ("primary/0.25"); a literal hex needs an 8-digit form instead.
local GRID_ALPHA_HEX = { "40", "73", "b3", "ff" }
local GRID_ALPHA_ROLE = { "/0.25", "/0.45", "/0.7", "" }

local function gridFill(step)
  if common.themeColors() then
    return THEME_TONES.ok .. GRID_ALPHA_ROLE[step]
  end
  return tone("ok") .. GRID_ALPHA_HEX[step]
end

local currentSnapshot = noctalia.state.get("snapshot") or {
  status = "loading",
  providers = {},
}
local currentAction = noctalia.state.get("action") or { status = "idle" }
local activeTab = "usage"
local panelOpen = false
local renderPanel
local hoveredUsageDate = nil
local selectedUsageDate = nil
local pendingAccountAction = nil
local hoveredAccountAction = nil

-- Translation catalogs are cached by some Noctalia builds while a development
-- plugin is hot-reloaded. Keep new action controls readable until the next full
-- plugin reload instead of exposing a raw key such as "action.use_reset".
local function trOr(key, fallback, substitutions)
  local translated = noctalia.tr(key, substitutions)
  return translated == key and fallback or translated
end

local function refresh()
  noctalia.state.set("command", { type = "refresh", nonce = noctalia.nowMs() })
end

-- OpenCodex serves its dashboard from the proxy root, so the configured base
-- URL is the address to open (`ocx gui` opens exactly this).
--
-- Only a bare scheme://host[:port] is a valid dashboard address. A base_url
-- with a path or anything odd simply hides the button.
local function dashboardUrl()
  local url = noctalia.getConfig("base_url")
  if type(url) ~= "string" then return nil end
  url = noctalia.string.trim(url):gsub("/+$", "")
  if url:match("^https?://[%w%.%-]+$") or url:match("^https?://[%w%.%-]+:%d+$")
    or url:match("^https?://%[[^%]]+%]$") or url:match("^https?://%[[^%]]+%]:%d+$") then
    return url
  end
  return nil
end

local function openDashboard()
  local url = dashboardUrl()
  if url == nil then return end
  -- plugin API 24 executes argument arrays directly, so the URL never passes
  -- through a shell.
  noctalia.runAsync({ "xdg-open", url })
end

local function enabledProviders()
  local result = {}
  for _, provider in ipairs(currentSnapshot.providers or {}) do
    if common.providerVisible(provider) then table.insert(result, provider) end
  end
  return result
end

-- A provider disabled in OpenCodex, or hidden by the `hidden_providers`
-- setting, is gone from the accounts tab and from the bar widget, so its usage
-- must not reappear here either. For the OpenCodex side the test is
-- "explicitly present and disabled" rather than "not in the enabled list":
-- /api/usage reports ids the provider list need not carry at all, and those
-- should still be shown.
local function hiddenProviderIds()
  local hidden = {}
  for _, provider in ipairs(currentSnapshot.providers or {}) do
    if not provider.enabled then hidden[tostring(provider.id):lower()] = true end
  end
  -- Codex-login usage is filed under either id depending on the endpoint; the
  -- snapshot only ever carries "openai".
  if hidden.openai then hidden.codex = true end
  if hidden.codex then hidden.openai = true end
  for id in pairs(common.hiddenProviders()) do hidden[id] = true end
  return hidden
end

local function providerMark(id, size)
  local named = common.providerGlyph(id)
  return ui.glyph({
    name = named or "robot",
    size = named ~= nil and size or size - 1,
    color = named ~= nil and "on_surface" or "on_surface/0.7",
  })
end

local function compactNumber(value)
  if type(value) ~= "number" then return "0" end
  local absolute = math.abs(value)
  if absolute < 1000 then return string.format("%.0f", value) end
  if absolute < 1000000 then return string.format("%.1fK", value / 1000) end
  if absolute < 1000000000 then return string.format("%.1fM", value / 1000000) end
  return string.format("%.1fB", value / 1000000000)
end

local function cost(value)
  if type(value) ~= "number" then return "—" end
  if value == 0 then return "$0.00" end
  if value < 0.01 then return "<$0.01" end
  return string.format("$%.2f", value)
end

local function usedPercent(value)
  if type(value) ~= "number" then return "—" end
  return noctalia.tr("quota.used", { percent = string.format("%.0f", value) })
end

local function countdown(resetAtMs)
  if type(resetAtMs) ~= "number" then return nil end
  local minutes = math.floor((resetAtMs - noctalia.nowMs()) / 60000)
  if minutes <= 0 then return noctalia.tr("reset.pending") end
  if minutes < 60 then return noctalia.tr("reset.minutes", { minutes = tostring(minutes) }) end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    return noctalia.tr("reset.hours", { hours = tostring(hours), minutes = tostring(minutes % 60) })
  end
  return noctalia.tr("reset.days", { days = tostring(math.floor(hours / 24)), hours = tostring(hours % 24) })
end

local function usedColor(value)
  if value >= EXHAUSTED_USED then return tone("over") end
  if value >= WARN_USED then return tone("warn") end
  return tone("ok")
end

local function accountPlan(account)
  if type(account.plan) ~= "string" or account.plan == "" then return nil end
  -- Keep OpenCodex's actual plan identifier, changing only its presentation.
  -- In particular, do not conflate distinct values such as `pro`/`prolite` or
  -- `team`/`business` with friendlier but potentially inaccurate names.
  local words = {}
  for word in account.plan:gsub("[_%-]+", " "):gmatch("%S+") do
    table.insert(words, word:sub(1, 1):upper() .. word:sub(2):lower())
  end
  return #words > 0 and table.concat(words, " ") or nil
end

local function accountStatus(account)
  if account.paused == true then return noctalia.tr("account.paused"), "error" end
  if account.needsReauth == true then return noctalia.tr("account.reauth"), "error" end

  local health = type(account.health) == "table" and account.health.status or account.health
  if health == "cooldown" or health == "warning" or health == "degraded"
    or health == "unhealthy" or health == "unavailable" or health == "error" then
    return account.healthLabel or noctalia.tr("account.warning"), "tertiary"
  end

  if account.active == true then return noctalia.tr("account.active"), "primary" end
  return nil, nil
end

local function accountAction(commandType, account)
  pendingAccountAction = nil
  noctalia.state.set("command", {
    type = commandType,
    accountId = account.id,
    nonce = noctalia.nowMs(),
  })
  renderPanel()
end

local function actionMessage()
  if currentAction.status == "idle" or currentAction.status == "working" then return nil, nil end
  local key
  if currentAction.status == "success" then
    if currentAction.type == "select_account" then
      key = "action_result.selected"
    elseif type(currentAction.remaining) == "number" then
      local count = tostring(math.max(0, math.floor(currentAction.remaining)))
      return trOr("action_result.reset_remaining", "Usage limits reset. " .. count .. " reset credits remain.", {
        count = count,
      }), "primary"
    else
      key = "action_result.reset"
    end
  elseif currentAction.code == "nothing_to_reset" then
    key = "action_result.nothing_to_reset"
  elseif currentAction.code == "no_credit" then
    key = "action_result.no_credit"
  else
    key = currentAction.type == "select_account" and "action_result.select_failed" or "action_result.reset_failed"
  end
  local fallbacks = {
    ["action_result.selected"] = "Account selected for the next turn.",
    ["action_result.reset"] = "Usage limits reset successfully.",
    ["action_result.nothing_to_reset"] = "This account currently has no usage limits to reset.",
    ["action_result.no_credit"] = "No reset credit is available for this account.",
    ["action_result.select_failed"] = "Could not change the active account.",
    ["action_result.reset_failed"] = "Could not use the reset credit.",
  }
  return trOr(key, fallbacks[key] or key), currentAction.status == "success" and "primary" or "error"
end

local function isCodexProvider(provider)
  local providerId = tostring(provider.id or ""):lower()
  return providerId == "openai" or providerId == "codex"
end

local function beginAccountAction(commandType, account)
  pendingAccountAction = { type = commandType, accountId = account.id }
  renderPanel()
end

local function accountActionEnabled(account)
  return account.paused ~= true and account.needsReauth ~= true
    and currentAction.status ~= "working"
end

-- Account actions are compact text links rather than padded buttons. They use
-- the same typography and underline treatment so neither action dominates the
-- reset-credit row.
local function accountActionHover(key, hovered)
  if hovered == "true" then
    hoveredAccountAction = key
  elseif hoveredAccountAction == key then
    hoveredAccountAction = nil
  end
  renderPanel()
end

local function switchAccountControl(account, key)
  local working = currentAction.status == "working"
    and currentAction.accountId == account.id
    and currentAction.type == "select_account"
  local enabled = accountActionEnabled(account)
  local hovered = enabled and hoveredAccountAction == key
  local color = hovered and "tertiary" or "primary"
  local props = { key = key, gap = 0, opacity = enabled and 1 or 0.55 }
  if enabled then
    props.onClick = function() beginAccountAction("select_account", account) end
    props.onHover = function(state) accountActionHover(key, state) end
  end
  return ui.column(props, {
    ui.label({
      text = working and trOr("action.selecting", "Switching…")
        or trOr("action.select", "Switch Account"),
      color = color,
      fontSize = 11,
      fontWeight = "bold",
    }),
    ui.box({ height = hovered and 2 or 1, minWidth = 47, fill = color }),
  })
end

-- Noctalia labels do not expose text-decoration or click handlers. A compact
-- clickable column with a one-pixel rule gives the reset action link styling
-- while keeping it directly in the reset-credit sentence.
local function resetAccountLink(account, key)
  local working = currentAction.status == "working"
    and currentAction.accountId == account.id
    and currentAction.type == "reset_account"
  local enabled = accountActionEnabled(account)
  local hovered = enabled and hoveredAccountAction == key
  local color = hovered and "tertiary" or "primary"
  local text = working and trOr("action.resetting", "Resetting…")
    or trOr("action.use_reset", "Use Reset")
  local props = { key = key, gap = 0, opacity = enabled and 1 or 0.55 }
  if enabled then
    props.onClick = function() beginAccountAction("reset_account", account) end
    props.onHover = function(state) accountActionHover(key, state) end
  end
  return ui.column(props, {
    ui.label({ text = text, color = color, fontSize = 11, fontWeight = "bold" }),
    ui.box({ height = hovered and 2 or 1, minWidth = 48, fill = color }),
  })
end

local function accountConfirmation(card, provider, account, key)
  if not isCodexProvider(provider) then return end
  local confirmation = pendingAccountAction
  if type(confirmation) ~= "table" or confirmation.accountId ~= account.id then return end

  local isReset = confirmation.type == "reset_account"
  table.insert(card, ui.label({
    key = key .. ":confirm:text",
    text = trOr(
      isReset and "confirm.reset" or "confirm.select",
      (isReset and "Use one reset credit for " or "Use ")
        .. (account.label or account.id) .. (isReset and "?" or " for the next turn?"),
      { account = account.label or account.id }
    ),
    color = isReset and "tertiary" or "on_surface/0.75",
    fontSize = 11,
    maxWidth = 350,
    maxLines = 3,
  }))
  table.insert(card, ui.row({ key = key .. ":confirm:buttons", gap = 5, align = "center" }, {
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      text = trOr("action.cancel", "Cancel"),
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        pendingAccountAction = nil
        renderPanel()
      end,
    }),
    ui.button({
      text = trOr(isReset and "action.confirm_reset" or "action.confirm_select", "Confirm"),
      variant = isReset and "secondary" or "primary",
      controlSize = "sm",
      onClick = function() accountAction(confirmation.type, account) end,
    }),
  }))
end

-- One limit row: label + percentage, bar, countdown.
-- Two elements per limit, not three: the reset countdown rides on the label
-- row rather than taking a line of its own underneath the bar.
local function quotaRows(rows, quota, keyPrefix)
  for index, window in ipairs((quota and quota.windows) or {}) do
    local used = window.usedPercent or 0
    local key = keyPrefix .. ":" .. tostring(index)
    local head = {
      ui.label({ text = window.label or noctalia.tr("quota.title"), fontSize = 12 }),
    }
    local reset = countdown(window.resetAtMs)
    if reset ~= nil then
      table.insert(head, ui.label({ text = reset, color = "on_surface/0.7", fontSize = 12, flexGrow = 1 }))
    else
      table.insert(head, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(head, ui.label({ text = usedPercent(window.usedPercent), fontSize = 12, color = usedColor(used) }))
    table.insert(rows, ui.row({ key = key .. ":head", gap = 6, align = "center" }, head))
    table.insert(rows, ui.progress({
      key = key .. ":bar",
      progress = used / 100,
      fill = usedColor(used),
      height = 6,
      radius = 3,
    }))
  end
end

-- `named` is false for a provider's only account: the provider header already
-- identifies it, so repeating an alias underneath is noise. Its status badge
-- moves up into that header instead.
local function accountCard(rows, provider, account, providerHasAccountQuota, named)
  local key = provider.id .. ":" .. account.id
  local card = {}

  if named then
    local status, statusColor = accountStatus(account)
    local plan = accountPlan(account)
    local title = {
      ui.label({
        text = account.label or account.id,
        fontSize = 13,
        fontWeight = "bold",
        maxWidth = 220,
      }),
    }
    if plan ~= nil then
      table.insert(title, ui.label({
        text = plan,
        color = "on_surface/0.6",
        fontSize = 10,
        flexGrow = 1,
      }))
    else
      table.insert(title, ui.spacer({ flexGrow = 1 }))
    end
    if status ~= nil then
      table.insert(title, ui.label({ text = status, color = statusColor, fontSize = 10, fontWeight = "bold" }))
    end
    table.insert(card, ui.row({ key = key .. ":title", gap = 8, align = "center" }, title))
  end

  -- Provider-level quota stands in only where the account has none of its own,
  -- so a provider's numbers are never printed twice.
  if account.quota ~= nil then
    quotaRows(card, account.quota, key)
  elseif not providerHasAccountQuota and provider.quota ~= nil then
    quotaRows(card, provider.quota, key)
  else
    table.insert(card, ui.label({
      key = key .. ":noquota",
      text = noctalia.tr("quota.unavailable"),
      color = "on_surface/0.6",
      fontSize = 11,
    }))
  end

  -- A reset credit clears the account's current limits outright, so it is worth
  -- surfacing next to a bar that looks close to full.
  local credits = account.quota ~= nil and account.quota.resetCredits or nil
  if credits ~= nil and credits > 0 then
    local creditRow = {
      ui.glyph({ name = "refresh-dot", size = 12, color = "primary" }),
      ui.label({
        text = noctalia.trp("quota.reset_credits", credits, { count = tostring(math.floor(credits)) }) .. (isCodexProvider(provider) and " ·" or ""),
        color = "primary",
        fontSize = 11,
      }),
    }
    if isCodexProvider(provider) then
      table.insert(creditRow, resetAccountLink(account, key .. ":reset"))
      if account.active ~= true then
        table.insert(creditRow, ui.spacer({ flexGrow = 1 }))
        table.insert(creditRow, switchAccountControl(account, key .. ":select"))
      end
    end
    table.insert(card, ui.row({ key = key .. ":credits", gap = 5, align = "center" }, creditRow))
  elseif isCodexProvider(provider) and account.active ~= true then
    -- Selection remains available when OpenCodex reports no reset-credit data.
    table.insert(card, ui.row({ key = key .. ":select-row", align = "center" }, {
      ui.spacer({ flexGrow = 1 }),
      switchAccountControl(account, key .. ":select"),
    }))
  end

  accountConfirmation(card, provider, account, key)

  if account.quotaUnavailable then
    table.insert(card, ui.label({
      key = key .. ":stale",
      text = noctalia.tr("quota.stale"),
      color = "on_surface/0.6",
      fontSize = 11,
    }))
  end

  table.insert(rows, ui.column({ key = key .. ":card", gap = 3, paddingH = 8, paddingV = 2 }, card))
end

local function accountsTab(body)
  local message, color = actionMessage()
  if message ~= nil then
    table.insert(body, ui.label({
      key = "action:result",
      text = message,
      color = color,
      fontSize = 11,
      maxWidth = 370,
      maxLines = 2,
    }))
  end

  local providers = enabledProviders()
  if #providers == 0 then
    -- The status line names the failure; this says what to do about it.
    local status = currentSnapshot.status
    local title, hint = "empty.no_providers", "empty.no_providers_hint"
    if status == "auth_error" then
      title, hint = "status.auth_error", "empty.auth_hint"
    elseif status == "offline" then
      title, hint = "status.offline", "empty.offline_hint"
    elseif status == "loading" then
      title, hint = "status.loading", nil
    end
    table.insert(body, ui.label({ key = "empty", text = noctalia.tr(title), fontWeight = "bold" }))
    if hint ~= nil then
      table.insert(body, ui.label({
        key = "empty:hint",
        text = noctalia.tr(hint),
        color = "on_surface/0.7",
        fontSize = 12,
        maxWidth = 360,
        maxLines = 3,
      }))
    end
    return
  end

  for index, provider in ipairs(providers) do
    local hasAccountQuota = common.anyAccountQuota(provider)
    local header = {
      providerMark(provider.id, 16),
      ui.label({
        text = provider.label or provider.id,
        fontSize = 14,
        fontWeight = "bold",
        flexGrow = 1,
      }),
    }
    local accounts = provider.accounts or {}
    local named = #accounts > 1

    if not named and accounts[1] ~= nil then
      local account = accounts[1]
      local plan = accountPlan(account)
      local status, statusColor = accountStatus(account)
      if plan ~= nil then
        table.insert(header, ui.label({ text = plan, color = "on_surface/0.6", fontSize = 10 }))
      end
      if status ~= nil then
        table.insert(header, ui.label({ text = status, color = statusColor, fontSize = 10, fontWeight = "bold" }))
      end
    end
    table.insert(body, ui.row({ key = "hdr:" .. provider.id, gap = 8, align = "center" }, header))

    if #accounts == 0 then
      table.insert(body, ui.label({
        key = "noacct:" .. provider.id,
        text = noctalia.tr("account.none"),
        color = "on_surface/0.6",
        fontSize = 11,
      }))
    end
    for _, account in ipairs(accounts) do
      accountCard(body, provider, account, hasAccountQuota, named)
    end
    if provider.pool ~= nil and provider.pool.strategy ~= nil then
      table.insert(body, ui.label({
        key = "pool:" .. provider.id,
        text = noctalia.tr("pool.strategy", { strategy = provider.pool.strategy }),
        color = "on_surface/0.6",
        fontSize = 10,
      }))
    end
    if index < #providers then
      table.insert(body, ui.separator({ key = "sep:" .. provider.id, spacing = SECTION_SPACING }))
    end
  end
end

-- Contribution grid, shaded by request volume against the busiest day in the
-- window. Laid out as a calendar (weekday columns, one row per week) rather
-- than GitHub's transpose: 30 days is only ~5 columns the other way round,
-- which cannot fill the panel width without absurd cell sizes.
-- Cells flex rather than carrying pixel widths. The scroll view's content box
-- is its own width less viewportPaddingH on both sides (Style::spaceXs) and,
-- once a scrollbar appears, a further scrollbarWidth + scrollbarGap gutter.
-- Chasing that with constants meant overlapping the scrollbar; letting the row
-- distribute whatever width it is actually given cannot drift.
local GRID_GAP = 4
local GRID_CELL_H = 26
local WEEKDAY_KEYS = { "mon", "tue", "wed", "thu", "fri", "sat", "sun" }

local function cellColor(requests, busiest)
  if requests <= 0 then return "on_surface/0.07" end
  local ratio = busiest > 0 and requests / busiest or 0
  local step = 1
  if ratio > 0.25 then step = 2 end
  if ratio > 0.5 then step = 3 end
  if ratio > 0.75 then step = 4 end
  return gridFill(step)
end

local function contributionGrid(body, days)
  if #days == 0 then return end

  local busiest = 0
  for _, day in ipairs(days) do
    if day.requests > busiest then busiest = day.requests end
  end

  local headers = {}
  for _, name in ipairs(WEEKDAY_KEYS) do
    table.insert(headers, ui.label({
      text = noctalia.tr("weekday." .. name),
      flexGrow = 1,
      fontSize = 11,
      textAlign = "center",
      color = "on_surface/0.65",
    }))
  end
  table.insert(body, ui.row({ key = "grid:head", gap = GRID_GAP, align = "center" }, headers))

  -- Blank cells before the first day so every column is a fixed weekday.
  local slots = {}
  for _ = 1, (days[1].weekday or 1) - 1 do table.insert(slots, false) end
  for _, day in ipairs(days) do table.insert(slots, day) end

  local rows = {}
  for week = 1, math.ceil(#slots / 7) do
    local cells = {}
    for weekday = 1, 7 do
      local slot = slots[(week - 1) * 7 + weekday]
      local fill = "on_surface/0.02"
      if slot ~= nil and slot ~= false then
        fill = cellColor(slot.requests, busiest)
      end
      local props = {
        key = "cell:" .. tostring(week) .. ":" .. tostring(weekday),
        flexGrow = 1,
        height = GRID_CELL_H,
        radius = 3,
        fill = fill,
      }
      if slot ~= nil and slot ~= false then
        -- Boxes cannot own tooltips in Noctalia's panel API. Hover mirrors the
        -- day into the detail line below; click does the same persistently and
        -- also makes the cell keyboard-focusable/activatable.
        props.border = selectedUsageDate == slot.date and "on_surface/0.9" or "on_surface/0"
        props.borderWidth = 1
        props.onHover = function(hovered)
          if hovered == "true" then
            hoveredUsageDate = slot.date
          elseif hoveredUsageDate == slot.date then
            hoveredUsageDate = nil
          end
          renderPanel()
        end
        props.onClick = function()
          if selectedUsageDate == slot.date then
            selectedUsageDate = nil
          else
            selectedUsageDate = slot.date
          end
          renderPanel()
        end
      end
      table.insert(cells, ui.box(props))
    end
    table.insert(rows, ui.row({ key = "grid:" .. tostring(week), gap = GRID_GAP, align = "center" }, cells))
  end
  table.insert(body, ui.column({ key = "grid", gap = GRID_GAP }, rows))

  local detail = days[#days]
  local wantedDate = hoveredUsageDate or selectedUsageDate
  if wantedDate ~= nil then
    for _, day in ipairs(days) do
      if day.date == wantedDate then
        detail = day
        break
      end
    end
  end
  table.insert(body, ui.label({
    key = "grid:detail",
    text = noctalia.trp("usage.grid_day", detail.requests, {
      date = detail.date,
      count = compactNumber(detail.requests),
      cost = cost(detail.estimatedCostUsd),
    }),
    color = "on_surface/0.75",
    fontSize = 11,
  }))

  local legend = {
    ui.label({
      text = noctalia.tr("usage.grid_caption", { days = tostring(#days), busiest = compactNumber(busiest) }),
      color = "on_surface/0.6",
      fontSize = 11,
      flexGrow = 1,
    }),
    ui.label({ text = noctalia.tr("usage.less"), color = "on_surface/0.6", fontSize = 11 }),
    ui.box({ width = 10, height = 10, radius = 2, fill = "on_surface/0.07" }),
  }
  for step = 1, 4 do
    table.insert(legend, ui.box({ width = 10, height = 10, radius = 2, fill = gridFill(step) }))
  end
  table.insert(legend, ui.label({ text = noctalia.tr("usage.more"), color = "on_surface/0.6", fontSize = 11 }))
  table.insert(body, ui.row({ key = "legend", gap = 4, align = "center" }, legend))
end

local function providerUsageRows(body, providers, models, totals, excluded)
  if #providers == 0 then return end
  table.insert(body, ui.label({
    key = "usage:by-provider",
    text = noctalia.tr("usage.by_provider"),
    fontWeight = "bold",
  }))

  for index, item in ipairs(providers) do
    local key = "usage:p:" .. item.id
    if index > 1 then
      table.insert(body, ui.spacer({ key = key .. ":gap", height = SECTION_SPACING }))
    end
    -- shareRatio is OpenCodex's own figure; fall back to a request share. With
    -- a provider hidden it is a share of a total the panel no longer shows, so
    -- the local computation takes over.
    local share = not excluded and item.shareRatio or nil
    if share == nil and totals.requests and totals.requests > 0 then
      share = item.requests / totals.requests
    end

    table.insert(body, ui.row({ key = key .. ":head", gap = 6, align = "center" }, {
      providerMark(item.id, 14),
      ui.label({ text = item.id, flexGrow = 1, fontSize = 12, fontWeight = "bold" }),
      ui.label({
        text = noctalia.tr("usage.requests", { count = compactNumber(item.requests) }),
        color = "on_surface/0.6",
        fontSize = 11,
      }),
      ui.label({ text = cost(item.estimatedCostUsd), fontSize = 12, fontWeight = "bold" }),
    }))
    if share ~= nil then
      table.insert(body, ui.progress({
        key = key .. ":share",
        progress = share,
        fill = tone("ok"),
        height = 4,
        radius = 2,
      }))
    end

    -- Which models made up that provider's usage, busiest first.
    local busiest = 0
    for _, model in ipairs(models) do
      if model.provider == item.id and model.requests > busiest then busiest = model.requests end
    end
    for _, model in ipairs(models) do
      if model.provider == item.id then
        table.insert(body, ui.row({ key = key .. ":m:" .. model.model, gap = 6, align = "center" }, {
          ui.box({
            width = 3,
            height = 12,
            radius = 2,
            fill = gridFill(busiest > 0 and math.max(1, math.ceil(model.requests / busiest * 4)) or 1),
          }),
          ui.label({ text = model.model, flexGrow = 1, fontSize = 11, color = "on_surface/0.85", maxWidth = 150 }),
          ui.label({
            text = compactNumber(model.requests),
            fontSize = 11,
            color = "on_surface/0.6",
          }),
          ui.label({
            text = noctalia.tr("usage.tokens", { count = compactNumber(model.totalTokens) }),
            fontSize = 11,
            color = "on_surface/0.6",
          }),
          ui.label({ text = cost(model.estimatedCostUsd), fontSize = 11 }),
        }))
      end
    end
  end
end

local function usageTab(body)
  local usage = currentSnapshot.usage
  if usage == nil then
    table.insert(body, ui.label({ key = "usage:none", text = noctalia.tr("usage.unavailable"), color = "on_surface/0.7" }))
    return
  end

  local hidden = hiddenProviderIds()

  -- Drop hidden providers, and the models that belong to them, before anything
  -- is drawn or summed.
  local function isHidden(id) return hidden[tostring(id or ""):lower()] == true end

  local providers, models, excluded = {}, {}, false
  for _, item in ipairs(usage.providers or {}) do
    if isHidden(item.id) then excluded = true else table.insert(providers, item) end
  end
  for _, model in ipairs(usage.models or {}) do
    if isHidden(model.provider) then excluded = true else table.insert(models, model) end
  end

  local today = usage.today
  local totals = usage.totals or {}
  -- OpenCodex's totals cover every provider. Once one is hidden they would
  -- report more than the rows above them, so re-sum what is left. Cached and
  -- reasoning tokens are not broken down per provider and simply cannot be
  -- re-summed, so those rows drop out rather than lie.
  if excluded then
    local summed = { requests = 0, totalTokens = 0, estimatedCostUsd = 0 }
    for _, item in ipairs(providers) do
      summed.requests = summed.requests + (item.requests or 0)
      summed.totalTokens = summed.totalTokens + (item.totalTokens or 0)
      summed.estimatedCostUsd = summed.estimatedCostUsd + (item.estimatedCostUsd or 0)
    end
    totals = summed
  end

  table.insert(body, ui.label({ key = "usage:today-title", text = noctalia.tr("usage.today"), fontWeight = "bold" }))
  table.insert(body, ui.row({ key = "usage:today", gap = 8 }, {
    ui.label({ text = noctalia.tr("usage.requests", { count = compactNumber(today and today.requests) }), flexGrow = 1 }),
    ui.label({ text = noctalia.tr("usage.tokens", { count = compactNumber(today and today.totalTokens) }) }),
  }))
  if today ~= nil and today.estimatedCostUsd ~= nil then
    table.insert(body, ui.row({ key = "usage:today-cost", gap = 8 }, {
      ui.label({ text = noctalia.tr("usage.today_cost"), flexGrow = 1 }),
      ui.label({ text = cost(today.estimatedCostUsd) }),
    }))
  end

  table.insert(body, ui.separator({ key = "usage:sep1", spacing = SECTION_SPACING }))
  contributionGrid(body, usage.days or {})

  table.insert(body, ui.separator({ key = "usage:sep2", spacing = SECTION_SPACING }))
  providerUsageRows(body, providers, models, totals, excluded)

  table.insert(body, ui.separator({ key = "usage:sep3", spacing = SECTION_SPACING }))
  table.insert(body, ui.label({
    key = "usage:window-title",
    text = noctalia.tr("usage.window", { range = usage.range or "30d" }),
    fontWeight = "bold",
  }))
  local function metric(labelKey, text)
    table.insert(body, ui.row({ key = "usage:" .. labelKey, gap = 8 }, {
      ui.label({ text = noctalia.tr(labelKey), flexGrow = 1, color = "on_surface/0.8" }),
      ui.label({ text = text }),
    }))
  end
  metric("usage.requests_label", compactNumber(totals.requests))
  metric("usage.tokens_label", compactNumber(totals.totalTokens))
  if not excluded then
    metric("usage.cached_label", compactNumber(totals.cachedInputTokens))
    metric("usage.reasoning_label", compactNumber(totals.reasoningOutputTokens))
  end
  metric("usage.cost_label", cost(totals.estimatedCostUsd))
end


local function statusLine()
  if currentSnapshot.refreshing and currentSnapshot.lastSuccessfulAtMs == nil then
    return noctalia.tr("status.loading"), "on_surface/0.65"
  end
  if currentSnapshot.error ~= nil and currentSnapshot.error.kind ~= nil then
    return noctalia.tr("status." .. currentSnapshot.error.kind),
      currentSnapshot.status == "degraded" and "tertiary" or "error"
  end
  if currentSnapshot.lastSuccessfulAtMs == nil then
    return noctalia.tr("status.never_updated"), "on_surface/0.65"
  end
  local seconds = math.max(0, math.floor((noctalia.nowMs() - currentSnapshot.lastSuccessfulAtMs) / 1000))
  if seconds < 60 then
    return noctalia.tr("status.updated_seconds", { seconds = tostring(seconds) }), "on_surface/0.6"
  end
  return noctalia.tr("status.updated_minutes", { minutes = tostring(math.floor(seconds / 60)) }), "on_surface/0.6"
end

local function selectTab(name)
  activeTab = name
  renderPanel()
end

function renderPanel()
  if not panelOpen then return end

  local statusText, statusColor = statusLine()
  local function tab(name, labelKey)
    return ui.button({
      key = "tab:" .. name,
      text = noctalia.tr(labelKey),
      controlSize = "sm",
      flexGrow = 1,
      variant = activeTab == name and "primary" or "ghost",
      onClick = function() selectTab(name) end,
    })
  end

  local body = {}
  if activeTab == "usage" then
    usageTab(body)
  else
    accountsTab(body)
  end

  local children = {
    ui.row({ key = "header", gap = 6, align = "center" }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      ui.button({
        key = "dashboard",
        glyph = "external-link",
        glyphSize = 15,
        variant = "ghost",
        controlSize = "sm",
        visible = dashboardUrl() ~= nil,
        tooltip = noctalia.tr("action.dashboard"),
        onClick = openDashboard,
      }),
      ui.spacer({ key = "header:gap", flexGrow = 1 }),
      ui.label({ text = statusText, color = statusColor, fontSize = 11 }),
      ui.button({
        key = "refresh",
        glyph = "refresh",
        glyphSize = 15,
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("action.refresh"),
        onClick = refresh,
      }),
    }),
    ui.row({ key = "tabs", gap = 4 }, { tab("accounts", "tab.accounts"), tab("usage", "tab.usage") }),
    -- flexGrow on both the root column and the scroll is what bounds the tree
    -- to the panel height; without it the content runs off the bottom edge
    -- instead of scrolling.
    ui.scroll({ key = "body", flexGrow = 1, gap = 5 }, body),
  }

  panel.render(ui.column({ flexGrow = 1, gap = 8, padding = 14 }, children))
end

noctalia.state.watch("snapshot", function(value)
  if type(value) == "table" then
    currentSnapshot = value
    renderPanel()
  end
end)

noctalia.state.watch("action", function(value)
  if type(value) == "table" then
    currentAction = value
    if value.status ~= "working" then pendingAccountAction = nil end
    renderPanel()
  end
end)

function onOpen()
  panelOpen = true
  -- Countdowns and the "updated Ns ago" line are the only live text here; a
  -- panel gets no update tick at all unless it asks for one.
  pcall(function() panel.setWantsSecondTicks(true) end)
  renderPanel()
end

function onClose()
  panelOpen = false
  panel.setWantsSecondTicks(false)
end

function update()
  renderPanel()
end
