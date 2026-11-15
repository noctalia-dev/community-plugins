--!nonstrict
-- Account tab (spec §6.5). Pure, like view_connect: it builds a ui tree from the
-- snapshot and the panel's ui_state and reports changes through setUi.
--
--   view_account.build(snapshot, ui_state, send, setUi) -> UiNode
--
-- snapshot.account (service.luau): nil until read, { loggedIn = false }, or
--   { loggedIn = true, masked, expiresAt, expiry = "ok"|"warn"|"expired",
--     deviceName, devices = { name } }. It never holds the account number.
-- snapshot.accountReadFailed: the last read failed (offline). With no account
--   to show, the tab says so and offers Retry (a refresh) instead of loading.
--
-- ui_state fields read here:
--   accountInput  what is typed in the account-number field (logged out only).
--                 Login sends it once, normalised, and drops it (false).
--   loginSeq      part of the login form's key. ui.input reads its value only
--                 when it mounts, so login bumps it to remount the field empty.
--   voucherInput / voucherSeq   the same pair for the voucher field.
--   confirm       the action being confirmed: "logout" or "revoke.<device name>"
--                 (view_common.confirmRow).
--
-- "Open account page" (mullvad.net, to add time or manage devices) shows while
-- logged in, and while logged out after a login refused for too many devices.

local commands = require("./commands.luau")
local view_common = require("./view_common.luau")

local view_account = {}

local function tr(key, subst)
  if noctalia and noctalia.tr then
    return noctalia.tr(key, subst)
  end
  return key
end

local EXPIRY_COLOR = { warn = "primary", expired = "error" }

local function hint(text, color)
  return ui.label({ text = text, fontSize = 11, color = color or "on_surface_variant", maxLines = 3 })
end

local function sectionLabel(key)
  return ui.label({ text = tr(key), fontSize = 10, color = "on_surface_variant" })
end

local function typed(value)
  if type(value) == "string" then
    return value
  end
  return ""
end

local function accountPageButton(send)
  return ui.row({ gap = 8 }, {
    ui.button({
      key = "account.open_page",
      text = tr("account.open_page"),
      glyph = "external-link",
      variant = "outline",
      controlSize = "sm",
      onClick = function()
        send({ action = "open_account_page" })
      end,
    }),
  })
end

local function loginForm(ui_state, send, patch, busy)
  local text = typed(ui_state.accountInput)
  local number = commands.normaliseAccount(text)
  local seq = tonumber(ui_state.loginSeq) or 0
  local function submit(value)
    local digits = commands.normaliseAccount(value)
    if digits == nil or busy then
      return
    end
    send({ action = "login", number = digits })
    patch({ accountInput = false, loginSeq = seq + 1 })
  end
  local children = {
    hint(tr("account.logged_out_hint")),
    ui.row({ key = "account.form." .. seq, gap = 8, align = "center" }, {
      ui.input({
        key = "account.input",
        password = true,
        placeholder = tr("account.input_placeholder"),
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(value)
          patch({ accountInput = value })
        end,
        onSubmit = function(value)
          submit(value)
        end,
      }),
      ui.button({
        key = "account.login",
        text = tr("account.login"),
        glyph = "login",
        variant = "primary",
        controlSize = "sm",
        enabled = not busy and number ~= nil,
        onClick = function()
          submit(ui_state.accountInput)
        end,
      }),
    }),
  }
  if text ~= "" and number == nil then
    children[#children + 1] = hint(tr("error.invalid_account"), "error")
  end
  return children
end

local function expiryLine(account)
  local date = account.expiresAt and account.expiresAt:match("^(%d+%-%d+%-%d+)") or (account.expiresAt or "")
  local key = account.expiry == "expired" and "account.expired_on" or "account.expires"
  return ui.label({
    key = "account.expiry",
    text = tr(key, { date = date }),
    fontSize = 12,
    fontWeight = account.expiry == "warn" and "semibold" or nil,
    color = EXPIRY_COLOR[account.expiry],
  })
end

local function deviceRows(account, ui_state, send, patch, busy)
  local rows = { sectionLabel("account.devices") }
  for _, name in ipairs(account.devices or {}) do
    local current = name == account.deviceName
    local actionId = "revoke." .. name
    local right = nil
    if current then
      right = hint(tr("account.current_device"))
    else
      right = view_common.confirmRow(tr, ui_state, actionId, function()
        send({ action = "revoke_device", name = name })
        patch({ confirm = false })
      end, function()
        patch({ confirm = false })
      end, busy) or ui.button({
        key = "device." .. name .. ".revoke",
        text = tr("account.revoke"),
        variant = "outline",
        controlSize = "sm",
        enabled = not busy,
        onClick = function()
          patch({ confirm = actionId })
        end,
      })
    end
    rows[#rows + 1] = ui.row({ key = "device." .. name, gap = 8, align = "center" }, {
      ui.label({ text = name, fontSize = 12, flexGrow = 1 }),
      right,
    })
  end
  return rows
end

local function voucherForm(ui_state, send, patch, busy)
  local code = commands.normaliseVoucher(typed(ui_state.voucherInput))
  local seq = tonumber(ui_state.voucherSeq) or 0
  local function submit(value)
    local normalised = commands.normaliseVoucher(value)
    if normalised == nil or busy then
      return
    end
    send({ action = "redeem", voucher = normalised })
    patch({ voucherInput = false, voucherSeq = seq + 1 })
  end
  return {
    sectionLabel("account.voucher"),
    ui.row({ key = "voucher.form." .. seq, gap = 8, align = "center" }, {
      ui.input({
        key = "voucher.input",
        placeholder = tr("account.voucher_placeholder"),
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(value)
          patch({ voucherInput = value })
        end,
        onSubmit = function(value)
          submit(value)
        end,
      }),
      ui.button({
        key = "voucher.redeem",
        text = tr("voucher.redeem"),
        variant = "outline",
        controlSize = "sm",
        enabled = not busy and code ~= nil,
        onClick = function()
          submit(ui_state.voucherInput)
        end,
      }),
    }),
  }
end

local function logoutRow(ui_state, send, patch, busy)
  return view_common.confirmRow(tr, ui_state, "logout", function()
    send({ action = "logout" })
    patch({ confirm = false })
  end, function()
    patch({ confirm = false })
  end, busy) or ui.row({ gap = 8 }, {
    ui.button({
      key = "account.logout",
      text = tr("account.logout"),
      glyph = "logout",
      variant = "destructive",
      controlSize = "sm",
      enabled = not busy,
      onClick = function()
        patch({ confirm = "logout" })
      end,
    }),
  })
end

local function append(list, nodes)
  for _, node in ipairs(nodes) do
    list[#list + 1] = node
  end
end

function view_account.build(snapshot, ui_state, send, setUi)
  snapshot = snapshot or {}
  ui_state = ui_state or {}
  local function patch(changes)
    if setUi ~= nil then
      setUi(changes)
    end
  end
  local busy = snapshot.busy == true
  local account = snapshot.account
  local children = {}
  if type(account) ~= "table" and snapshot.accountReadFailed == true then
    children[1] = hint(tr("account.read_failed"), "error")
    children[2] = ui.row({ gap = 8 }, {
      ui.button({
        key = "account.retry",
        text = tr("account.retry"),
        glyph = "refresh",
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          send({ action = "refresh" })
        end,
      }),
    })
  elseif type(account) ~= "table" then
    children[1] = ui.label({ key = "account.loading", text = tr("account.loading"), fontSize = 12, color = "on_surface_variant" })
  elseif account.loggedIn ~= true then
    append(children, loginForm(ui_state, send, patch, busy))
    local err = snapshot.lastError
    if type(err) == "table" and err.key == "error.too_many_devices" then
      children[#children + 1] = accountPageButton(send)
    end
  else
    children[#children + 1] = ui.label({
      key = "account.number",
      text = tr("account.number", { number = account.masked or "" }),
      fontSize = 13,
      fontWeight = "semibold",
    })
    children[#children + 1] = expiryLine(account)
    children[#children + 1] = accountPageButton(send)
    children[#children + 1] = hint(tr("account.this_device", { name = account.deviceName or "" }))
    append(children, deviceRows(account, ui_state, send, patch, busy))
    append(children, voucherForm(ui_state, send, patch, busy))
    children[#children + 1] = logoutRow(ui_state, send, patch, busy)
  end
  return ui.column({ key = "account.tab", gap = 10 }, children)
end

return view_account
