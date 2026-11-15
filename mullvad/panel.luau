--!nonstrict
-- Mullvad panel - a thin client like the bar widget. It owns no `mullvad` call:
-- it renders the service's "mullvad.state" snapshot and turns clicks into one
-- "mullvad.request" each.
--
-- Layout: title row, header (model.header: state, plus fix buttons), the last
-- error as a dismissable notice, then the tab row and the active tab's body.
-- While the daemon is down the header replaces the tabs and body.
--
-- ui_state is local to the panel and never reaches the service:
--   tab = "connect" | "advanced" | "account", and the view fields each view_*
--   module documents (view_connect: mode, countryCode, cityCode; view_account:
--   accountInput, loginSeq, voucherInput, voucherSeq, confirm). Views report
--   changes through setUi(patch); the panel merges them and re-renders.
-- To add a tab: one entry in TABS and its en.json "tab.<id>" label.

local model = require("./model.luau")
local view_connect = require("./view_connect.luau")
local view_advanced = require("./view_advanced.luau")
local view_account = require("./view_account.luau")

local REQUEST_KEY = "mullvad.request"
local STATE_KEY = "mullvad.state"

local snapshot = nil
local ui_state = { tab = "connect", mode = "country" }
local hasApp = false
-- The lastError the user dismissed, as "key\ndetail"; it stays hidden while the
-- service keeps publishing that same error.
local dismissedError = nil
-- Every request gets a fresh id, so two identical clicks are two state changes.
local requestId = 0
-- A login request holds the account number. The service wipes it from the
-- channel when it arrives; if no service consumed it (not running), the panel
-- wipes it itself after LOGIN_WIPE_MS, or at once when the panel closes.
-- Delivery to a running watcher is already queued when state.set returns.
local LOGIN_WIPE_MS = 3000
local pendingLogin = nil -- { requestId, atMs }

local render -- forward

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function errorSignature(err)
  return tostring(err.key) .. "\n" .. tostring(err.detail or "")
end

local function secondTicks(on)
  if panel and panel.setWantsSecondTicks then
    panel.setWantsSecondTicks(on)
  end
end

local function send(request)
  local copy = {}
  for k, v in pairs(request) do
    copy[k] = v
  end
  requestId = requestId + 1
  copy.requestId = requestId
  if request.action ~= "refresh" then
    dismissedError = nil
  end
  noctalia.state.set(REQUEST_KEY, copy)
  if request.action == "login" then
    pendingLogin = { requestId = requestId, atMs = noctalia.nowMs() }
    secondTicks(true)
  end
end

-- Wipe the pending login request if it is still what the channel holds.
local function wipePendingLogin(now)
  if pendingLogin == nil or (not now and noctalia.nowMs() - pendingLogin.atMs < LOGIN_WIPE_MS) then
    return
  end
  local stored = noctalia.state.get(REQUEST_KEY)
  if type(stored) == "table" and stored.action == "login" and stored.requestId == pendingLogin.requestId then
    noctalia.state.set(REQUEST_KEY, nil)
  end
  pendingLogin = nil
  secondTicks(false)
end

-- show_flags defaults to on; only an explicit false turns the flags off.
local function showFlags()
  return noctalia.getConfig("show_flags") ~= false
end

local function setUi(patch)
  for k, v in pairs(patch) do
    ui_state[k] = v
  end
  render()
end

local function detectApp()
  hasApp = noctalia.commandExists ~= nil and noctalia.commandExists("mullvad-vpn") == true
end

-- ── tabs ─────────────────────────────────────────────────────────────────────

local TABS = {
  { id = "connect", glyph = "plug-connected", build = function()
    return view_connect.build(snapshot or {}, ui_state, send, setUi, showFlags())
  end },
  { id = "advanced", glyph = "adjustments", build = function()
    return view_advanced.build(snapshot or {}, ui_state, send, hasApp)
  end },
  { id = "account", glyph = "user-circle", build = function()
    return view_account.build(snapshot or {}, ui_state, send, setUi)
  end },
}

local function activeTab()
  for _, tab in ipairs(TABS) do
    if tab.id == ui_state.tab then
      return tab
    end
  end
  return TABS[1]
end

local function tabRow(active)
  local buttons = {}
  for _, tab in ipairs(TABS) do
    local id = tab.id
    buttons[#buttons + 1] = ui.button({
      key = "tab." .. id,
      text = tr("tab." .. id),
      glyph = tab.glyph,
      -- no `selected = true`: the host paints a selected button in the primary fill,
      -- which would make the active tab look like the main action button
      variant = id == active.id and "secondary" or "ghost",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        setUi({ tab = id })
      end,
    })
  end
  -- One outlined container around the whole row; the active tab is filled.
  return ui.row({ key = "tabs", gap = 4, padding = 3, radius = 10, border = "outline_variant", borderWidth = 1 }, buttons)
end

-- ── header ───────────────────────────────────────────────────────────────────

-- Header actions that stay in the panel; every other action is sent as-is
-- ({action = name}).
local LOCAL_ACTIONS = {
  open_account_tab = function()
    setUi({ tab = "account" })
  end,
  connect = function()
    local request = view_connect.connectRequest(snapshot or {}, ui_state)
    if request ~= nil then
      send(request)
    end
  end,
}
-- Text only: the header sentence already says what to do.
local NO_BUTTON = { reboot_notice = true }

-- A header action that has nothing to send right now is disabled, like the
-- tab's own button (connect in my-country mode before a real location is known).
local function headerActionPossible(action)
  if action == "connect" then
    return view_connect.connectRequest(snapshot or {}, ui_state) ~= nil
  end
  return true
end

local function headerButton(action)
  return ui.button({
    key = "header." .. action,
    text = tr("header.action." .. action),
    variant = "outline",
    controlSize = "sm",
    enabled = not (snapshot and snapshot.busy == true) and headerActionPossible(action),
    onClick = function()
      local handler = LOCAL_ACTIONS[action]
      if handler ~= nil then
        handler()
      else
        send({ action = action })
      end
    end,
  })
end

local function header()
  local view = model.barView(snapshot, true, showFlags())
  local text = tr("header.loading")
  local kind = "loading"
  local actions = {}
  local tunnel = nil
  if type(snapshot) == "table" then
    local h = model.header(snapshot, showFlags())
    text = tr(h.textKey, h.subs)
    kind = h.kind
    actions = h.actions
    tunnel = snapshot.tunnel
  end
  local problem = kind == "error" or kind == "daemon_down"

  local lines = {
    ui.label({ text = text, fontSize = 13, fontWeight = "semibold", maxLines = 3, color = problem and "error" or nil }),
  }
  if tunnel ~= nil and not problem then
    -- "Connected to {place}" already names the place; in every other state show
    -- the visible location the daemon reports, and nothing when it reports none.
    local where = model.place(snapshot, showFlags())
    if tunnel.state ~= "connected" and where ~= "" then
      lines[#lines + 1] = ui.label({
        key = "header.location",
        text = tr("header.visible_location", { location = where }),
        fontSize = 11,
        color = "on_surface_variant",
      })
    end
    if tunnel.ipv4 ~= nil then
      lines[#lines + 1] = ui.label({ key = "header.ip", text = tr("header.ip", { ip = tunnel.ipv4 }), fontSize = 11, color = "on_surface_variant" })
    end
  end
  local children = {
    ui.row({ gap = 10, align = "center" }, {
      ui.glyph({ name = view.glyph, size = 22, color = view.color }),
      ui.column({ gap = 2, flexGrow = 1 }, lines),
    }),
  }
  local buttons = {}
  for _, action in ipairs(actions) do
    if not NO_BUTTON[action] then
      buttons[#buttons + 1] = headerButton(action)
    end
  end
  if #buttons > 0 then
    children[#children + 1] = ui.row({ gap = 6 }, buttons)
  end
  return ui.column({
    key = "header",
    gap = 8,
    padding = 10,
    radius = 8,
    fill = problem and "error/0.12" or "surface_container/0.4",
  }, children)
end

-- ── notices ──────────────────────────────────────────────────────────────────

-- Extra buttons under an error's text, by error key.
local ERROR_BUTTONS = {
  ["error.no_polkit_agent"] = { "run_in_terminal", "enable_polkit_agent" },
}

local function errorButtons(err)
  local names = ERROR_BUTTONS[err.key]
  if names == nil then
    return nil
  end
  local buttons = {}
  for _, name in ipairs(names) do
    buttons[#buttons + 1] = ui.button({
      key = "error." .. name,
      text = tr("error.action." .. name),
      variant = "outline",
      controlSize = "sm",
      enabled = not (snapshot and snapshot.busy == true),
      onClick = function()
        send({ action = name, ["for"] = err.action })
      end,
    })
  end
  return ui.row({ gap = 6 }, buttons)
end

local function errorNotice()
  local err = snapshot and snapshot.lastError
  if type(err) ~= "table" or err.key == nil or errorSignature(err) == dismissedError then
    return nil
  end
  local extra = errorButtons(err)
  local row = ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
    ui.label({
      text = tr(err.key, { detail = err.detail or "" }),
      fontSize = 11,
      color = "error",
      flexGrow = 1,
      maxLines = 4,
    }),
    ui.button({
      key = "error.dismiss",
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.dismiss"),
      onClick = function()
        -- Clear it in the service too; hide it here at once (send resets the
        -- local dismissal, so it is set after).
        send({ action = "dismiss_error", key = err.key, detail = err.detail })
        dismissedError = errorSignature(err)
        render()
      end,
    }),
  })
  local children = { row }
  if extra ~= nil then
    children[2] = extra
  end
  return ui.column({ key = "error.notice", gap = 6, padding = 8, radius = 8, fill = "error/0.12" }, children)
end

-- ── render ───────────────────────────────────────────────────────────────────

function render()
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "shield-lock", size = 20, color = "primary" }),
      ui.label({ text = tr("plugin.name"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ key = "panel.refresh", glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh"),
        onClick = function()
          send({ action = "refresh" })
        end }),
      ui.button({ key = "panel.close", glyph = "x", variant = "ghost", tooltip = tr("panel.close"),
        onClick = function()
          panel.close()
        end }),
    }),
    header(),
  }
  local notice = errorNotice()
  if notice ~= nil then
    children[#children + 1] = notice
  end
  if type(snapshot) == "table" and snapshot.busy == true then
    children[#children + 1] = ui.label({ key = "busy", text = tr("panel.busy"), fontSize = 11, color = "primary" })
  end

  if not (type(snapshot) == "table" and snapshot.daemon == "down") then
    local tab = activeTab()
    children[#children + 1] = tabRow(tab)
    children[#children + 1] = ui.scroll({ flexGrow = 1, gap = 10 }, { tab.build() })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 12 }, children))
end

function onOpen(_context)
  local value = noctalia.state.get(STATE_KEY)
  if type(value) == "table" then
    snapshot = value
  end
  -- An open question or a half-typed field does not survive closing the panel:
  -- drop them, and re-key the fields so they mount empty.
  ui_state.confirm = nil
  ui_state.accountInput = nil
  ui_state.voucherInput = nil
  ui_state.loginSeq = (ui_state.loginSeq or 0) + 1
  ui_state.voucherSeq = (ui_state.voucherSeq or 0) + 1
  detectApp()
  render()
  -- state.watch does not replay an old value; ask for a fresh snapshot.
  send({ action = "refresh" })
end

function onClose()
  -- Nothing runs in the background: the service owns every call. Second ticks
  -- stop with the panel, so a pending login request is wiped now, and a typed but
  -- unsent account number is dropped rather than kept until the next open.
  wipePendingLogin(true)
  ui_state.accountInput = nil
end

function update()
  wipePendingLogin(false)
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  snapshot = value
  if value.lastError == nil then
    dismissedError = nil
  end
  render()
end)

detectApp()
render()
