--!nonstrict
-- The connect wizard: four steps from no key to a verified read-only key,
-- driven entirely by report.account.stage (the helper records progress in
-- account.json, so a closed panel or a restart resumes at the right step).
--
--   1 Generate key     stage none              keygen; public key copied
--   2 Register it      stage awaiting_api_key  user works in the browser
--   3 Save API key     stage awaiting_api_key  store_api_key from clipboard
--   4 Verify           stage awaiting_verify   verify; then stage active
--
-- The same steps rotate a key (account.rotating): the active key keeps
-- working until the new one verifies. Every error code the keyring
-- subcommands return gets a fix in the step where it happened.

local state = require("../lib/state.luau")
local fmt = require("./fmt.luau")
local parts = require("./parts.luau")
local status = require("./status.luau")

local M = {}

M.API_MANAGEMENT_URL = "https://www.binance.com/en/my/settings/api-management"
local INSTALL_KEYRING = "sudo pacman -S gnome-keyring"
local TIME_SYNC = "timedatectl set-ntp true"

-- Errors that mean the pending pair is gone or unusable: start again.
local RESTART = {
  no_pending_key = true,
  pending_incomplete = true,
  keyring_corrupt = true,
  keyring_readback_failed = true,
  item_missing = true,
}

-- Which step's command produced a busy state.
local BUSY_STEP = { keygen = 1, store_api_key = 3, verify = 4 }

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

function M.currentStep(account): number
  if account.stage == "awaiting_api_key" then
    return 3
  elseif account.stage == "awaiting_verify" then
    return 4
  end
  return 1
end

-- Human name of a permission flag as Binance's API Management labels it.
-- Translation keys are snake_case: enableFixApiTrade -> enable_fix_api_trade.
function M.flagName(flag: string): string
  local key = `wizard.flag.{(flag:gsub("%u", function(c)
    return "_" .. c:lower()
  end))}`
  local text = tr(key)
  return if text == key then flag else text
end

local function stepCommand(step: number)
  if step == 1 then
    state.keygen()
  elseif step == 3 then
    state.storeApiKey()
  else
    state.verify()
  end
end

-- The fix for an error, with the one action that applies.
local function fixBox(err, step: number, ctx)
  local code = err.code
  local children = {}
  local key = `wizard.fix.{code}`
  local body = tr(key, {
    until_time = if err.untilAt then fmt.duration(err.untilAt - fmt.now()) else "",
    code = tostring(err.binanceCode or err.status or ""),
    command = if code == "missing_dependency" then status.INSTALL_CRYPTOGRAPHY
      elseif code == "no_secret_service" then INSTALL_KEYRING
      elseif code == "clock_skew" then TIME_SYNC
      else "",
  })
  if body == key then
    -- No specific fix: the service's short title plus Binance's message.
    body = fmt.errorTitle(code) .. (if err.msg then ` — {err.msg}` else "")
  end
  table.insert(children, ui.label({ text = body, fontSize = 12, color = "on_surface", maxLines = 6 }))

  if code == "permissions_too_broad" and err.flags then
    local flags = {}
    for i, flag in err.flags do
      table.insert(flags, parts.bullet("square-x", M.flagName(flag), "error", `flag{i}`))
    end
    table.insert(children, ui.column({ gap = 4, paddingH = 4 }, flags))
    table.insert(children, parts.caption(tr("wizard.fix.permissions_after"), nil, { maxLines = 2 }))
  end

  local action
  if code == "missing_dependency" or code == "no_secret_service" or code == "clock_skew" then
    local command = if code == "missing_dependency" then status.INSTALL_CRYPTOGRAPHY
      elseif code == "no_secret_service" then INSTALL_KEYRING
      else TIME_SYNC
    action = ctx.copyButton(command, `fix-{code}`, tr("wizard.copy_command"))
  elseif RESTART[code] and step > 1 then
    action = ui.button({
      text = tr("wizard.start_over"),
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        state.keygen()
      end,
    })
  elseif code == "permissions_too_broad" or code == "auth_rejected" then
    action = ctx.linkButton(M.API_MANAGEMENT_URL, tr("wizard.open_api_management"))
  elseif code ~= "rate_limited" and code ~= "busy" then
    -- keyring_locked, clipboard and network errors, and anything unknown:
    -- the fix is to run the step again.
    action = ui.button({
      text = tr("wizard.try_again"),
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        stepCommand(step)
      end,
    })
  end
  if action then
    table.insert(children, ui.row({ gap = 6 }, { action }))
  end

  return ui.row({ gap = 10, align = "start", padding = 10, radius = 10, fill = "error/0.10", key = `fix-{code}` }, {
    ui.glyph({ name = "alert-circle", size = 16, color = "error" }),
    ui.column({ gap = 6, flexGrow = 1 }, children),
  })
end

local function stepMarker(n: number, phase: string)
  local done, current = phase == "done", phase == "current"
  return ui.column({
    width = 22,
    height = 22,
    radius = 11,
    align = "center",
    justify = "center",
    fill = if current then "primary" elseif done then "primary/0.15" else nil,
    border = if current or done then nil else "outline_variant/0.6",
    borderWidth = if current or done then nil else 1,
  }, {
    if done
      then ui.glyph({ name = "check", size = 14, color = "primary" })
      else ui.label({
        text = tostring(n),
        fontSize = 11,
        fontWeight = "bold",
        color = if current then "on_primary" else "on_surface_variant",
      }),
  })
end

local function step(n: number, phase: string, title: string, body)
  local header = ui.row({ gap = 10, align = "center" }, {
    stepMarker(n, phase),
    ui.label({
      text = title,
      fontSize = 13,
      fontWeight = if phase == "current" then "semibold" else "medium",
      color = if phase == "todo" then "on_surface_variant" else "on_surface",
      flexGrow = 1,
    }),
  })
  if body == nil or #body == 0 then
    return ui.column({ key = `step{n}` }, { header })
  end
  return ui.column({ gap = 8, key = `step{n}` }, {
    header,
    ui.column({ gap = 8, paddingH = 32 }, body),
  })
end

local function primaryAction(n: number, label: string, report)
  local busyWhat = report.status and report.status.busy and report.status.busyWhat
  local busyHere = busyWhat ~= nil and BUSY_STEP[busyWhat] == n
  local busyElsewhere = busyWhat ~= nil and BUSY_STEP[busyWhat] ~= nil and not busyHere
  return ui.row({ gap = 8, align = "center" }, parts.nodes(
    ui.button({
      text = if busyHere then tr(`panel.busy.{busyWhat}`) else label,
      glyph = if busyHere then "loader-2" else nil,
      variant = "primary",
      controlSize = "sm",
      enabled = not busyHere and not busyElsewhere,
      onClick = function()
        stepCommand(n)
      end,
    }),
    if busyHere then parts.caption(tr("wizard.keyring_prompt"), nil, { flexGrow = 1, maxLines = 2 }) else nil
  ))
end

function M.render(report, ctx)
  local account = report.account
  local rotating = account.rotating == true
  local current = M.currentStep(account)
  local err = account.error
  -- A missing dependency stops every step; show it where the user is.
  if err == nil and report.status.dependency then
    err = { code = "missing_dependency" }
  end
  -- While the step's command runs again, its previous error is moot.
  local busyWhat = report.status.busy and report.status.busyWhat
  if busyWhat and BUSY_STEP[busyWhat] == current then
    err = nil
  end

  -- Step 2 happens in the browser, so it stays current alongside step 3.
  local function phase(n: number): string
    if n == current or (n == 2 and current == 3) then
      return "current"
    end
    return if n < current then "done" else "todo"
  end

  -- Step 1
  local body1
  if current == 1 then
    body1 = parts.nodes(
      parts.caption(tr("wizard.step1_body"), nil, { maxLines = 4, fontSize = 12 }),
      if err then fixBox(err, 1, ctx) else nil,
      primaryAction(1, tr("wizard.step1_action"), report)
    )
  else
    body1 = {
      ui.row({ gap = 8, align = "center" }, {
        parts.caption(tr("wizard.step1_done"), nil, { flexGrow = 1 }),
        ctx.copyButton(nil, "pubkey", tr("wizard.copy_public_key"), function()
          state.copyPublicKey()
        end),
      }),
    }
  end

  -- Step 2: only instructions; nothing to observe until step 3 succeeds.
  local body2
  if current == 3 then
    body2 = {
      parts.bullet("number-1", tr("wizard.step2_open"), nil, "i1"),
      parts.bullet("number-2", tr("wizard.step2_paste"), nil, "i2"),
      parts.bullet("number-3", tr("wizard.step2_reading"), nil, "i3"),
      ui.row({ gap = 6 }, { ctx.linkButton(M.API_MANAGEMENT_URL, tr("wizard.open_api_management")) }),
    }
    if account.publicKeyPem then
      table.insert(body2, ui.column({ gap = 4, padding = 8, radius = 8, fill = "surface/0.6", key = "pem" }, {
        ui.label({
          text = account.publicKeyPem:gsub("%s+$", ""),
          fontSize = 10,
          fontFamily = "monospace",
          color = "on_surface_variant",
          maxLines = 4,
        }),
      }))
    end
  end

  local body3
  if current == 3 then
    body3 = parts.nodes(
      parts.caption(tr("wizard.step3_body"), nil, { maxLines = 4, fontSize = 12 }),
      if err then fixBox(err, 3, ctx) else nil,
      primaryAction(3, tr("wizard.step3_action"), report)
    )
  end

  local body4
  if current == 4 then
    body4 = parts.nodes(
      parts.banner("info", "clipboard-x", tr("wizard.history_title"), tr("wizard.history_body"), nil, "history"),
      parts.caption(tr("wizard.step4_body"), nil, { maxLines = 4, fontSize = 12 }),
      if err then fixBox(err, 4, ctx) else nil,
      primaryAction(4, tr("wizard.step4_action"), report),
      -- Plugins can't place their widget; the user's [bar] config does.
      if rotating then nil else parts.bullet("layout-navbar", tr("wizard.bar_tip"), "on_surface_variant", "bar-tip")
    )
  end

  return parts.card({
    ui.row({ gap = 8, align = "start" }, parts.nodes(
      ui.column({ gap = 2, flexGrow = 1 }, parts.nodes(
        ui.label({
          text = tr(if rotating then "wizard.rotate_title" else "wizard.title"),
          fontSize = 15,
          fontWeight = "bold",
          color = "on_surface",
        }),
        parts.caption(tr(if rotating then "wizard.rotate_subtitle" else "wizard.subtitle"), nil, { maxLines = 3 })
      )),
      -- A new key pair replaces the pending one; the active key is untouched.
      if current > 1
        then ui.button({
          text = tr("wizard.start_over"),
          variant = "ghost",
          controlSize = "sm",
          tooltip = tr("wizard.start_over_tooltip"),
          onClick = function()
            state.keygen()
          end,
        })
        else nil
    )),
    step(1, phase(1), tr("wizard.step1_title"), body1),
    step(2, phase(2), tr("wizard.step2_title"), body2),
    step(3, phase(3), tr("wizard.step3_title"), body3),
    step(4, phase(4), tr("wizard.step4_title"), body4),
  }, { key = "wizard", gap = 14, padding = 14 })
end

return M
