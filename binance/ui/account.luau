--!nonstrict
-- Account tab: the connection (verified badge, re-verify, rotate, disconnect)
-- or the connect wizard, then display preferences (privacy, bar style).
--
-- Step-1 keys predate account.json, so the plugin starts keyless for them;
-- "Verify existing key" runs verify, which promotes them without a new key
-- (orchestrator decision 2026-10-19: one click, never automatic).

local state = require("../lib/state.luau")
local fmt = require("./fmt.luau")
local parts = require("./parts.luau")
local wizard = require("./wizard.luau")

local M = {}

local BAR_MODES = { "full", "value", "icon" }

local function tr(key: string, subst)
  return noctalia.tr(key, subst)
end

local function busyWith(report, what: string): boolean
  return report.status.busy and report.status.busyWhat == what
end

local function connectionCard(report, ctx)
  local account = report.account
  local verifying = busyWith(report, "verify")
  local disconnecting = busyWith(report, "disconnect")
  local rotatingInProgress = account.rotating and account.stage ~= "active"

  local badge
  if account.verifiedAt then
    badge = ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "shield-check", size = 22, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("panel.account.verified"), fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
        -- The service re-checks daily; much older means checks are failing.
        parts.caption(
          tr("panel.account.verified_at", { ago = fmt.ago(account.verifiedAt) }),
          if fmt.now() - account.verifiedAt > 36 * 3600000 then "error" else nil
        ),
      }),
    })
  else
    badge = ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = "shield-question", size = 22, color = "on_surface_variant" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = tr("panel.account.connected"), fontSize = 14, fontWeight = "semibold", color = "on_surface" }),
        parts.caption(tr("panel.account.not_verified")),
      }),
    })
  end

  local children = {
    badge,
    parts.caption(tr("panel.account.stocks_permission_note"), nil, { maxLines = 3 }),
  }

  -- A failed daily re-check while the key stays active (rotation errors show
  -- in the wizard instead).
  if account.error and not rotatingInProgress then
    table.insert(children, parts.banner(
      "error",
      "alert-circle",
      fmt.errorTitle(account.error.code),
      tr("panel.account.recheck_failed", { ago = fmt.ago(account.error.at) }),
      nil,
      "recheck-error"
    ))
    if account.error.code == "permissions_too_broad" and account.error.flags then
      local names = {}
      for _, flag in account.error.flags do
        table.insert(names, wizard.flagName(flag))
      end
      table.insert(children, parts.caption(tr("panel.account.untick", { list = table.concat(names, ", ") }), "error", { maxLines = 3 }))
    end
  end

  -- During a rotation, verify checks the pending key: the wizard below owns
  -- that button, so the active key's controls step aside.
  table.insert(children, ui.row({ gap = 6, align = "center" }, parts.nodes(
    if rotatingInProgress
      then nil
      else ui.button({
        text = tr(if verifying then "panel.busy.verify" else "panel.account.verify_now"),
        glyph = if verifying then "loader-2" else "shield-check",
        variant = "outline",
        controlSize = "sm",
        enabled = not verifying,
        onClick = function()
          state.verify()
        end,
      }),
    if rotatingInProgress
      then nil
      else ui.button({
        text = tr("panel.account.rotate"),
        glyph = "key",
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("panel.account.rotate_tooltip"),
        onClick = function()
          state.keygen()
        end,
      }),
    ctx.linkButton(wizard.API_MANAGEMENT_URL, tr("panel.account.api_management"))
  )))

  local confirming = ctx.confirmDisconnect ~= nil and fmt.now() < ctx.confirmDisconnect
  table.insert(children, ui.separator({ color = "outline_variant/0.2" }))
  table.insert(children, ui.row({ gap = 10, align = "center" }, {
    parts.caption(tr("panel.account.disconnect_note"), nil, { flexGrow = 1, maxLines = 3 }),
    ui.button({
      text = tr(if disconnecting then "panel.busy.disconnect"
        elseif confirming then "panel.account.disconnect_confirm"
        else "panel.account.disconnect"),
      variant = if confirming then "destructive" else "outline",
      controlSize = "sm",
      enabled = not disconnecting,
      onClick = function()
        if confirming then
          ctx.confirmDisconnect = nil
          state.disconnect()
        else
          ctx.confirmDisconnect = fmt.now() + 5000
        end
        ctx.render()
      end,
    }),
  }))

  return parts.card(children, { key = "connection", padding = 14 })
end

local function existingKeyCard(report)
  local verifying = busyWith(report, "verify")
  return parts.card({
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        parts.title(tr("panel.account.existing_title")),
        parts.caption(tr("panel.account.existing_body"), nil, { maxLines = 3 }),
      }),
      ui.button({
        text = tr(if verifying then "panel.busy.verify" else "panel.account.verify_existing"),
        variant = "outline",
        controlSize = "sm",
        enabled = not verifying,
        onClick = function()
          state.verify()
        end,
      }),
    }),
  }, { key = "existing" })
end

local function displayCard(report)
  local modeLabels = {}
  for i, mode in BAR_MODES do
    modeLabels[i] = tr(`panel.account.bar_mode_{mode}`)
  end
  local modeIndex = table.find(BAR_MODES, report.barMode) or 1
  return parts.card({
    parts.title(tr("panel.account.display")),
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.account.privacy"), fontSize = 12, color = "on_surface" }),
        parts.caption(tr("panel.account.privacy_body"), nil, { maxLines = 2 }),
      }),
      ui.toggle({
        checked = report.privacy == true,
        onChange = function(value)
          state.setPrivacy(value == "true")
        end,
      }),
    }),
    ui.row({ gap = 10, align = "center" }, {
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = tr("panel.account.bar_mode"), fontSize = 12, color = "on_surface" }),
        parts.caption(tr("panel.account.bar_mode_body"), nil, { maxLines = 2 }),
      }),
      ui.select({
        key = "bar-mode",
        options = modeLabels,
        selectedIndex = modeIndex - 1,
        controlSize = "sm",
        width = 150,
        onChange = function(index)
          state.setBarMode(BAR_MODES[(tonumber(index) or 0) + 1] or "full")
        end,
      }),
    }),
  }, { key = "display" })
end

function M.render(report, ctx): { any }
  local account = report.account
  local out = {}
  if report.mode == "connected" then
    table.insert(out, connectionCard(report, ctx))
    if account.rotating and account.stage ~= "active" then
      table.insert(out, wizard.render(report, ctx))
    end
  else
    table.insert(out, wizard.render(report, ctx))
    if account.stage == "none" then
      table.insert(out, existingKeyCard(report))
    end
  end
  table.insert(out, displayCard(report))
  return out
end

return M
