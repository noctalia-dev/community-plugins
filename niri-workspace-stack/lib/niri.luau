--!nonstrict
-- niri IPC through the `niri msg` CLI. Every action uses the argv form of
-- noctalia.runAsync (plugin_api 24), so no value is ever parsed by a shell.

local M = {}

-- Long-lived event stream with reconnect + backoff. The sentinel lines let the widget
-- show a disconnected state; niri re-sends full WorkspacesChanged/WindowsChanged on
-- every new connection, so no explicit resync is needed after a reconnect.
M.STREAM_START = "NwsStreamStart"
M.STREAM_END = "NwsStreamEnd"
M.EVENT_STREAM = [[
delay=1
while :; do
  printf '{"NwsStreamStart":{}}\n'
  if niri msg --json event-stream; then delay=1; fi
  printf '{"NwsStreamEnd":{}}\n'
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); fi
done
]]

local function run(argv, what)
  local ok = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.log(string.format("niri-workspace-stack: %s failed (exit %d): %s", what, result.exitCode, noctalia.string.trim(result.stderr)))
    end
  end, 2000)
  if not ok then
    noctalia.log("niri-workspace-stack: could not start " .. what)
  end
end

local function isIndexLike(name)
  -- niri's CLI parses any i32-looking reference as an index, so such names are unusable.
  return string.match(name, "^%s*[+-]?%d+%s*$") ~= nil
end

-- Focus a workspace from its *current* model entry (looked up by stable id at click time).
--
-- niri resolves `focus-workspace <index>` against the focused monitor
-- (Niri::find_output_and_workspace_index returns no output for Index), and the CLI
-- cannot send WorkspaceReferenceArg::Id. So:
--   * named workspace          -> `focus-workspace <name>`: niri resolves its output, atomic
--   * same output as focused   -> `focus-workspace <idx>`
--   * other output             -> `focus-monitor <output>` then `focus-workspace <idx>`
--     (the target's idx is unaffected by focus-monitor: it does not change any
--     monitor's active workspace, so no empty workspace is cleaned up in between)
function M.focusWorkspace(ws, focusedOutput)
  if ws == nil or ws.idx == nil then
    return
  end
  if type(ws.name) == "string" and ws.name ~= "" and not isIndexLike(ws.name) then
    run({ "niri", "msg", "action", "focus-workspace", ws.name }, "focus-workspace")
  elseif ws.output == focusedOutput or ws.output == nil then
    run({ "niri", "msg", "action", "focus-workspace", tostring(ws.idx) }, "focus-workspace")
  else
    run({
      "/bin/sh",
      "-c",
      'niri msg action focus-monitor "$1" && exec niri msg action focus-workspace "$2"',
      "niri-workspace-stack",
      ws.output,
      tostring(ws.idx),
    }, "focus-monitor + focus-workspace")
  end
end

function M.focusWindow(id)
  if id == nil then
    return
  end
  run({ "niri", "msg", "action", "focus-window", "--id", string.format("%d", id) }, "focus-window")
end

-- Resync after a lost stream line (lines over 64 KiB are dropped by the host).
--
-- niri's events carry absolute values (ids, full window records), so re-applying an event
-- that a snapshot already reflects is harmless. The only hazard is the reverse: events
-- applied while the two snapshot commands run would be overwritten by the older snapshot.
-- So both replies are collected and applied together only if the model saw no event in the
-- meantime; otherwise the snapshot is retaken (at most 3 attempts).
local resyncActive = false

function M.resync(model, applyEvent, attempt)
  attempt = attempt or 1
  if resyncActive and attempt == 1 then
    return
  end
  resyncActive = true
  local startCount = model.eventCount
  local replies, pending = {}, 2
  local function finish()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if replies.workspaces == nil or replies.windows == nil then
      resyncActive = false
      noctalia.log("niri-workspace-stack: resync failed (niri msg error)")
      return
    end
    if model.eventCount ~= startCount then
      if attempt < 3 then
        M.resync(model, applyEvent, attempt + 1)
      else
        resyncActive = false
        noctalia.log("niri-workspace-stack: resync skipped; event stream too busy, stream state kept")
      end
      return
    end
    resyncActive = false
    applyEvent({ WorkspacesChanged = { workspaces = replies.workspaces } })
    applyEvent({ WindowsChanged = { windows = replies.windows } })
  end
  local function fetch(kind)
    local ok = noctalia.runAsync({ "niri", "msg", "--json", kind }, function(result)
      local list = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
      replies[kind] = type(list) == "table" and list or nil
      finish()
    end, 3000)
    if not ok then
      finish()
    end
  end
  fetch("workspaces")
  fetch("windows")
end

return M
