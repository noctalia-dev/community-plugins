--!nonstrict
-- niri IPC through the `niri msg` CLI. Every action uses the argv form of
-- noctalia.runAsync (plugin_api 24), so no value is ever parsed by a shell.

local M = {}

M.COMMAND = "niri"
M.SUBSCRIBE = "niri msg --json event-stream"
M.SNAPSHOT = {
  workspaces = { "niri", "msg", "--json", "workspaces" },
  windows = { "niri", "msg", "--json", "windows" },
}

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

-- niri's events are already what lib/model.luau applies; niri re-sends full
-- WorkspacesChanged/WindowsChanged on every new connection.
function M.decoder()
  return function(event)
    return { event }
  end
end

function M.snapshotEvent(kind, list)
  if kind == "workspaces" then
    return { WorkspacesChanged = { workspaces = list } }
  end
  return { WindowsChanged = { windows = list } }
end

return M
