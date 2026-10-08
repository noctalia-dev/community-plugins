--!nonstrict
-- Hands an expired session back to the vendor's own CLI.
--
-- Access tokens are short-lived and the refresh token belongs to the vendor's
-- tool: spending it here could sign that tool out. So instead of refreshing,
-- an adapter runs the lightest CLI command that authenticates; the CLI renews
-- and saves its own session, and the adapter reads the credentials again.
-- Bounded in time and in frequency, so a dead session cannot spawn the CLI on
-- every refresh.

local M = {}

-- Finds a CLI on PATH, else at the first existing fallback path ("~/..." ok).
function M.findCommand(ctx, name: string, fallbacks: { string }): string?
  if ctx.which(name) then
    return name
  end
  for _, path in fallbacks do
    local expanded = ctx.expandPath(path)
    if ctx.fileExists(expanded) then
      return expanded
    end
  end
  return nil
end

export type Renewer = (ctx: any, argv: { string }, done: (renewed: boolean) -> ()) -> ()

-- A renewer allows one attempt per `cooldown` seconds; done(true) means the
-- command ran and exited cleanly (the caller re-reads the credentials to know
-- whether that produced a fresh token).
function M.new(cooldown: number, timeoutMs: number): Renewer
  local lastAttemptAt = -math.huge
  return function(ctx, argv, done)
    local now = ctx.now()
    if now - lastAttemptAt < cooldown then
      done(false)
      return
    end
    lastAttemptAt = now
    ctx.run(argv, timeoutMs, function(result)
      done(result ~= nil and result.exitCode == 0)
    end)
  end
end

return M
