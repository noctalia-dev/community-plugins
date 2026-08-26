-- tests/panel_handlers_test.lua
-- Covers Fix 5: panel.luau's plain event-handler logic (onReorder,
-- onWorkspaceToggled, onScaleChanged, cloneMonitorsForRequest) contains no
-- Luau-only syntax and is exercisable under plain Lua with small stubs for
-- `ui`/`panel`/`barWidget`.
--
-- This test deliberately loads BOTH service.luau (for the real buildSnapshot)
-- and panel.luau (for the handlers under test), and seeds the panel's
-- snapshot via buildSnapshot's actual output rather than a hand-crafted
-- table. That's what lets it double as a regression test for Fix 1: if
-- buildSnapshot stops computing a real `mode` field, cloneMonitorsForRequest
-- silently falls back to "preferred" and this test's mode assertion catches
-- it end-to-end, the same way the real dispatch-to-writer path would be
-- affected.

local stateValues = {}
local watchers = {}
local notifyErrorCalls = {}

noctalia = {
  json = { decode = function() return {} end },
  commandExists = function() return false end, -- keep service.luau's poll() a no-op
  runAsync = function() return false end,
  getConfig = function() return nil end,
  setUpdateInterval = function() end,
  tr = function(key, args)
    if args ~= nil and args.message ~= nil then
      return key .. ": " .. tostring(args.message)
    end
    return key
  end,
  notifyError = function(title, message)
    notifyErrorCalls[#notifyErrorCalls + 1] = { title = title, message = message }
  end,
  state = {
    set = function(key, value)
      stateValues[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    get = function(key) return stateValues[key] end,
    watch = function(key, callback) watchers[key] = callback end,
  },
}

-- Minimal ui/panel stand-ins: every ui.xxx(...) call becomes a no-op-ish
-- table-returning function via the __index fallback; panel.render/close are
-- no-ops so panel.luau's render() calls (including the one that fires at
-- file-load time, per its last line) don't error.
ui = setmetatable({}, { __index = function()
  return function(props, children) return { props = props, children = children } end
end })
local renderCallCount = 0
local lastRenderTree = nil
panel = {
  render = function(tree)
    renderCallCount = renderCallCount + 1
    lastRenderTree = tree
  end,
  close = function() end,
}

-- Recursively finds a node in the ui-stub tree (see the ui stand-in above)
-- whose props.key matches, so tests can reach into real onChange/onSubmit
-- callbacks/props as actually wired up by monitorCard(), rather than calling
-- panel.luau's handler functions directly and only ever exercising the wiring
-- by assumption.
local function findNodeByKey(node, key)
  if type(node) ~= "table" then return nil end
  if type(node.props) == "table" and node.props.key == key then return node end
  if type(node.children) == "table" then
    for _, child in ipairs(node.children) do
      local found = findNodeByKey(child, key)
      if found ~= nil then return found end
    end
  end
  return nil
end

assert(loadfile("service.luau"))()
assert(loadfile("panel.luau"))()

local SNAPSHOT_KEY = "hypr-display-config.snapshot"
local REQUEST_KEY = "hypr-display-config.apply_request"
local RESULT_KEY = "hypr-display-config.apply_result"

-- Build a snapshot using the REAL buildSnapshot from service.luau so this
-- test exercises the full Fix-1-through-panel.luau contract, not just a
-- hand-rolled fixture.
local monitors = {
  { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
    scale = 1, transform = 0, refreshRate = 60,
    availableModes = { "1920x1080@60.00Hz", "1920x1080@59.94Hz" }, disabled = false },
  { name = "HEADLESS-1", width = 1280, height = 720, x = 1920, y = 0,
    scale = 1, transform = 0, refreshRate = 60,
    availableModes = {}, disabled = false },
}
local bindings = { { workspace = 1, monitor = "eDP-1" } }
local snapshot = buildSnapshot(monitors, bindings, 3)

assert(snapshot.monitors[1].name == "eDP-1", "fixture sanity: eDP-1 should sort first (x=0)")
assert(snapshot.monitors[2].name == "HEADLESS-1", "fixture sanity: HEADLESS-1 should sort second (x=1920)")
assert(#snapshot.monitors[1].workspaces == 1 and snapshot.monitors[1].workspaces[1] == 1)
assert(#snapshot.monitors[2].workspaces == 0)
assert(#snapshot.unboundWorkspaces == 2 and snapshot.unboundWorkspaces[1] == 2 and snapshot.unboundWorkspaces[2] == 3)
assert(snapshot.monitors[1].mode == "1920x1080@60.00Hz",
  "fixture sanity: eDP-1's computed mode should match its availableModes entry")

-- Seed the panel's internal snapshot via the real SNAPSHOT_KEY watcher.
noctalia.state.set(SNAPSHOT_KEY, snapshot)

local function requestMonitorByName(name)
  local request = stateValues[REQUEST_KEY]
  assert(type(request) == "table", "no apply_request published")
  for _, monitor in ipairs(request.monitors) do
    if monitor.name == name then return monitor end
  end
  error("apply_request has no monitor entry named " .. name)
end

local function assertAllEntriesHaveWidth()
  local request = stateValues[REQUEST_KEY]
  for _, monitor in ipairs(request.monitors) do
    assert(type(monitor.width) == "number" and monitor.width > 0,
      "apply_request monitor entry for " .. tostring(monitor.name) .. " is missing a numeric width")
  end
end

-- 1) onReorder: drag HEADLESS-1 in front of eDP-1.
onReorder("HEADLESS-1", "eDP-1")
do
  local request = stateValues[REQUEST_KEY]
  assert(request.monitors[1].name == "HEADLESS-1", "expected HEADLESS-1 first after reorder, got " .. request.monitors[1].name)
  assert(request.monitors[2].name == "eDP-1", "expected eDP-1 second after reorder, got " .. request.monitors[2].name)
end
assertAllEntriesHaveWidth()

-- This is the Fix-1 regression check: eDP-1's mode must survive the
-- snapshot -> cloneMonitorsForRequest pipeline as its real current mode, not
-- silently fall back to "preferred" because buildSnapshot forgot to compute it.
local edp1AfterReorder = requestMonitorByName("eDP-1")
assert(edp1AfterReorder.mode == "1920x1080@60.00Hz",
  "expected eDP-1's real current mode to survive to the apply_request, got " .. tostring(edp1AfterReorder.mode)
    .. " -- this is the exact Fix 1 regression: buildSnapshot must set `mode`, "
    .. "otherwise cloneMonitorsForRequest falls back to 'preferred' on every apply.")

-- 2) onWorkspaceToggled: check workspace 2 (currently unbound) onto eDP-1.
onWorkspaceToggled("2", "eDP-1", true)
local edp1AfterAssign = requestMonitorByName("eDP-1")
local sawWorkspace1, sawWorkspace2 = false, false
for _, id in ipairs(edp1AfterAssign.workspaces) do
  if id == 1 then sawWorkspace1 = true end
  if id == 2 then sawWorkspace2 = true end
end
assert(sawWorkspace1, "eDP-1 should still have workspace 1 bound")
assert(sawWorkspace2, "eDP-1 should now have workspace 2 bound after onWorkspaceToggled(true)")
assertAllEntriesHaveWidth()

-- 2b) Unchecking must unassign rather than move it anywhere else.
onWorkspaceToggled("2", "eDP-1", false)
local edp1AfterUnassign = requestMonitorByName("eDP-1")
local stillHasWorkspace2 = false
for _, id in ipairs(edp1AfterUnassign.workspaces) do
  if id == 2 then stillHasWorkspace2 = true end
end
assert(not stillHasWorkspace2, "expected workspace 2 to be unassigned from eDP-1 after onWorkspaceToggled(false)")
local headlessAfterUnassign = requestMonitorByName("HEADLESS-1")
for _, id in ipairs(headlessAfterUnassign.workspaces) do
  assert(id ~= 2, "unchecking a workspace must leave it unbound, not move it to another monitor")
end
-- Restore it for the rest of the test, which assumes workspace 2 is bound to eDP-1.
onWorkspaceToggled("2", "eDP-1", true)
assertAllEntriesHaveWidth()

-- 3) onScaleChanged (Fix 2 left this as the actual apply-dispatch site, fired
-- from the scale input's onSubmit rather than onChange).
onScaleChanged("eDP-1", "1.75")
local edp1AfterScale = requestMonitorByName("eDP-1")
assert(edp1AfterScale.scale == 1.75, "expected eDP-1 scale to be 1.75, got " .. tostring(edp1AfterScale.scale))
assertAllEntriesHaveWidth()

-- 4) Fix 7(b): an error apply_result should trigger noctalia.notifyError in
-- addition to setting the on-screen error banner.
-- (Note: service.luau's own poll() already fired one notifyError call at
-- load time above, since our stub's commandExists always reports hyprctl as
-- missing (Fix 7(b) part 1) -- so we count from the baseline, not from zero.)
-- Fix B made the RESULT_KEY watcher correlate against the actually in-flight
-- request id, so this must use the real id dispatchApply just published
-- (step 3's onScaleChanged dispatched it) rather than an arbitrary string.
local baselineNotifyCount = #notifyErrorCalls
local inFlightRequestId = stateValues[REQUEST_KEY].request_id
assert(type(inFlightRequestId) == "string" and #inFlightRequestId > 0,
  "expected a real in-flight request_id from the step-3 dispatch")
noctalia.state.set(RESULT_KEY, { request_id = inFlightRequestId, status = "error", message = "boom" })
assert(#notifyErrorCalls == baselineNotifyCount + 1, "expected exactly one new notifyError call for an error apply_result")
local lastCall = notifyErrorCalls[#notifyErrorCalls]
assert(tostring(lastCall.message):find("boom", 1, true) ~= nil,
  "expected the notifyError message to mention the underlying failure, got " .. tostring(lastCall.message))

-- 5) Fix A: the scale input's onSubmit must be wired as the string handler
-- name "onScaleSubmit" (matching the confirmed-real onSubmit convention),
-- not a closure. Reach into the actually-rendered tree (not just call the
-- handler function directly) so this would catch a regression back to a
-- closure. `render` itself is a panel.luau-local, so trigger a render via the
-- exposed global onRefreshClicked() the same way a real refresh click would.
onRefreshClicked()
local scaleNode = findNodeByKey(lastRenderTree, "scale-eDP-1")
assert(scaleNode ~= nil, "expected to find the eDP-1 scale ui.input node in the rendered tree")
assert(scaleNode.props.onSubmit == "onScaleSubmit",
  "expected the scale input's onSubmit to be the string \"onScaleSubmit\", got " .. tostring(scaleNode.props.onSubmit))
assert(type(scaleNode.props.onChange) == "function",
  "expected the scale input's onChange to still be a closure (confirmed-real convention for onChange)")

-- Simulate the user typing (fires onChange, which is confirmed to work as a
-- closure and is what feeds `activeScaleMonitor`), then submitting (fires
-- the global onScaleSubmit string handler, which has no monitor name of its
-- own and must resolve it via activeScaleMonitor).
scaleNode.props.onChange("2.25")
onScaleSubmit("2.25")
local edp1AfterSubmit = requestMonitorByName("eDP-1")
assert(edp1AfterSubmit.scale == 2.25,
  "expected onScaleSubmit (string-handler path) to apply the new scale via activeScaleMonitor, got "
    .. tostring(edp1AfterSubmit.scale))

-- 5b) Regression: editing monitor A's scale (onChange, no submit), then
-- switching focus to monitor B's field and submitting WITHOUT typing there
-- (no onChange fires for B, so activeScaleMonitor is still "A") must not
-- misapply B's displayed text to monitor A. onScaleSubmit must no-op instead
-- of dispatching a wrong-monitor apply.
local headlessNode = findNodeByKey(lastRenderTree, "scale-HEADLESS-1")
assert(headlessNode ~= nil, "expected to find the HEADLESS-1 scale ui.input node in the rendered tree")
local requestIdBeforeLeak = stateValues[REQUEST_KEY].request_id
scaleNode = findNodeByKey(lastRenderTree, "scale-eDP-1")
scaleNode.props.onChange("9.99") -- types in eDP-1, does not submit
onScaleSubmit(headlessNode.props.value) -- submits HEADLESS-1's *displayed* value without ever focusing/changing it
assert(stateValues[REQUEST_KEY].request_id == requestIdBeforeLeak,
  "expected the cross-monitor submit to no-op (no new apply_request dispatched), but a new request was sent")
local edp1AfterLeakAttempt = requestMonitorByName("eDP-1")
assert(edp1AfterLeakAttempt.scale == 2.25,
  "expected eDP-1's scale to remain unchanged by a submit that actually targeted a different monitor, got "
    .. tostring(edp1AfterLeakAttempt.scale))

-- 6) Fix C: submitting an invalid scale must still re-render, so the input
-- visibly reverts to the last-known-good value instead of leaving stale
-- invalid text on screen with no feedback.
local renderCountBeforeInvalid = renderCallCount
scaleNode = findNodeByKey(lastRenderTree, "scale-eDP-1")
scaleNode.props.onChange("not-a-number")
onScaleSubmit("not-a-number")
assert(renderCallCount > renderCountBeforeInvalid,
  "expected an invalid scale submission to still trigger a render()")
local scaleNodeAfterInvalid = findNodeByKey(lastRenderTree, "scale-eDP-1")
assert(scaleNodeAfterInvalid.props.value == "2.25",
  "expected the scale input to revert to the last-known-good value (2.25) after an invalid submit, got "
    .. tostring(scaleNodeAfterInvalid.props.value))

-- 7) Fix B: an apply_result for a request other than the one actually in
-- flight must be ignored -- in particular it must not clear the busy guard
-- early. Dispatch a fresh request, send a stale result for a different id,
-- and prove the busy guard (which gates the SNAPSHOT_KEY watcher) is still
-- held; then send the real result and prove it clears.
onWorkspaceToggled("3", "eDP-1", true)
local newInFlightRequestId = stateValues[REQUEST_KEY].request_id
assert(newInFlightRequestId ~= inFlightRequestId, "expected a fresh request_id for this new dispatch")

noctalia.state.set(RESULT_KEY, { request_id = "stale-request-id-does-not-match", status = "ok" })

local sentinelSnapshot = {
  status = "ready",
  monitors = {
    { name = "SENTINEL-SHOULD-BE-IGNORED", width = 100, mode = "preferred",
      scale = 1, transform = 0, disabled = false, workspaces = {} },
  },
  unboundWorkspaces = {},
}
noctalia.state.set(SNAPSHOT_KEY, sentinelSnapshot)
assert(findNodeByKey(lastRenderTree, "card-SENTINEL-SHOULD-BE-IGNORED") == nil,
  "a stale apply_result (wrong request_id) must not clear the busy guard for the request actually in flight")

noctalia.state.set(RESULT_KEY, { request_id = newInFlightRequestId, status = "ok" })
noctalia.state.set(SNAPSHOT_KEY, sentinelSnapshot)
assert(findNodeByKey(lastRenderTree, "card-SENTINEL-SHOULD-BE-IGNORED") ~= nil,
  "the busy guard should clear once the result for the actually in-flight request arrives")

-- 8) Regression: with no request currently in flight (pendingRequestId ==
-- nil, the state right after load and right after any prior result has been
-- handled), a leftover/unrelated apply_result must NOT be treated as fresh.
-- noctalia.state.watch delivers the currently-stored value immediately on
-- registration, so on every real panel (re)open a stale error sitting in
-- RESULT_KEY from a past session would otherwise be replayed as a brand-new
-- notifyError -- with no corresponding user action at all.
local notifyCountBeforeIdleReplay = #notifyErrorCalls
noctalia.state.set(RESULT_KEY, {
  request_id = "leftover-from-a-previous-session",
  status = "error",
  message = "monitors overlap",
})
assert(#notifyErrorCalls == notifyCountBeforeIdleReplay,
  "a stale apply_result must not fire notifyError when no request is currently in flight, but it did")

print("panel_handlers_test: ok")
