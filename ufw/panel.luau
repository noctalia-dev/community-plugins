--!nonstrict
-- UFW panel: a thin client like the bar widget. It renders the service's ufw.state snapshot
-- through view_panel.build and turns clicks into one ufw.request each; it runs no process.
--
-- Local state (never sent until Add): the add form. Inputs are uncontrolled, so the typed
-- text arrives through onChange and lives in `form`; a new form.seq re-keys the inputs, which
-- mounts them empty. Add validates with commands.validateAdd first: an invalid entry shows its
-- error under the add row and sends nothing. A valid one is sent as stage_add; the form is
-- cleared once the service's answer shows the new pending op, and kept (with the service's
-- add.* error) when the service refuses it.

local view_panel = require("./view_panel.luau")
local commands = require("./commands.luau")
local model = require("./model.luau")

local REQUEST_KEY = "ufw.request"
local STATE_KEY = "ufw.state"

-- view names to service actions
local ACTIONS = {
  turn_on = "enable",
  start_service = "start_service",
  load_rules = "load_rules",
  enable_at_boot = "enable_at_boot",
}

local snapshot = nil
local form = { proto = "both", port = "", comment = "", seq = 1, errorKey = nil }
-- A sent stage_add waiting for its answer: { seq = requestSeq before, count = #pending before }.
local awaitingAdd = nil
-- Every request gets a fresh id, so two identical clicks are two state changes.
local requestId = 0

local render -- forward

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function send(request)
  requestId = requestId + 1
  request.requestId = requestId
  noctalia.state.set(REQUEST_KEY, request)
end

local function resetForm()
  form = { proto = "both", port = "", comment = "", seq = form.seq + 1, errorKey = nil }
end

local function pendingCount(snap)
  return type(snap) == "table" and type(snap.pending) == "table" and #snap.pending or 0
end

-- Clears the form once the service has answered the stage_add: a new pending op means it was
-- staged; an error means it was refused, and the text stays so it can be fixed.
local function settleAdd(snap)
  if awaitingAdd == nil or type(snap.requestSeq) ~= "number" or snap.requestSeq <= awaitingAdd.seq then
    return
  end
  if pendingCount(snap) > awaitingAdd.count then
    awaitingAdd = nil
    resetForm()
  elseif type(snap.lastError) == "table" and type(snap.lastError.key) == "string"
    and string.sub(snap.lastError.key, 1, 4) == "add." then
    -- only an add.* error answers the add; an older unrelated error does not
    awaitingAdd = nil
  end
end

local h = { form = form, confirmOff = false, toggleSeq = 0 }
-- The direction of the last switch flip the panel acted on (true = on), until a snapshot
-- settles it; and whether the last snapshot was busy.
local lastFlip = nil
local wasBusy = false

-- ui.toggle is value-driven: after a flip whose action did not happen (refused, cancelled,
-- timed out) `checked` is unchanged, so the host could keep drawing the flipped switch. A new
-- toggleSeq re-keys the switch's box, which remounts it showing the real state.
local function remountSwitch()
  h.toggleSeq = h.toggleSeq + 1
end

local function settleSwitch(snap)
  local busy = snap.busy == true
  if wasBusy and not busy then
    remountSwitch() -- an action ended, whatever its outcome
  elseif not busy and lastFlip ~= nil and model.switchOn(snap) ~= lastFlip then
    remountSwitch() -- the flip was not applied
  end
  if not busy then
    lastFlip = nil
  end
  wasBusy = busy
end

-- Turning on runs at once; turning off first asks in the panel. The switch is remounted so it
-- keeps showing "on" until the user confirms.
function h.toggle(on)
  if on then
    h.confirmOff = false
    lastFlip = true
    send({ action = "enable" })
    return
  end
  h.confirmOff = true
  remountSwitch()
  render()
end

function h.confirmTurnOff()
  if h.confirmOff ~= true then
    return
  end
  h.confirmOff = false
  lastFlip = false
  send({ action = "disable" })
  render()
end

function h.cancelOff()
  h.confirmOff = false
  remountSwitch()
  render()
end

function h.primary(name)
  local action = ACTIONS[name]
  if action ~= nil then
    send({ action = action })
  end
end

function h.stageAdd(port, proto, comment)
  local op, err = commands.validateAdd(port or "", proto or "both", comment)
  if op == nil then
    form.errorKey = err
    render()
    return
  end
  form.errorKey = nil
  awaitingAdd = {
    seq = type(snapshot) == "table" and tonumber(snapshot.requestSeq) or 0,
    count = pendingCount(snapshot),
  }
  send({ action = "stage_add", port = port, proto = op.proto, comment = op.comment })
  render()
end

function h.stageRemove(ruleId)
  send({ action = "stage_remove", rule = ruleId })
end

function h.unstage(opId)
  send({ action = "unstage", id = opId })
end

function h.discard()
  send({ action = "discard" })
end

function h.save()
  send({ action = "save" })
end

function h.fallback(kind)
  if kind == "polkit_agent" then
    send({ action = "enable_polkit_agent" })
  elseif kind == "terminal" then
    local fallback = type(snapshot) == "table" and snapshot.polkitFallback
    if type(fallback) == "table" and type(fallback["for"]) == "string" then
      send({ action = "run_in_terminal", ["for"] = fallback["for"] })
    end
  end
end

function h.dismiss(key)
  send({ action = "dismiss_error", key = key })
end

function h.setForm(patch)
  local redraw = false
  for k, v in pairs(patch) do
    if k == "proto" and form.proto ~= v then
      redraw = true
    end
    form[k] = v
  end
  -- typing needs no redraw (the host owns the input text); the choice does
  if redraw then
    render()
  end
end

function render()
  h.form = form
  panel.render(view_panel.build(snapshot, ui, tr, h))
end

function onOpen(_context)
  local value = noctalia.state.get(STATE_KEY)
  if type(value) == "table" then
    snapshot = value
  end
  -- a half-typed entry does not survive closing the panel
  resetForm()
  awaitingAdd = nil
  h.confirmOff = false
  lastFlip = nil
  wasBusy = type(snapshot) == "table" and snapshot.busy == true
  render()
  -- state.watch does not replay an old value; ask for a fresh snapshot (and re-read the files)
  send({ action = "refresh" })
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  snapshot = value
  settleAdd(value)
  settleSwitch(value)
  -- nothing left to confirm once the firewall is off, or while an action runs
  if not model.switchOn(value) or value.busy == true then
    h.confirmOff = false
  end
  render()
end)

render()
