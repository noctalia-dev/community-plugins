--!nonstrict
-- Keys of the noctalia.state channel. The service is the only writer of everything here except the
-- per-entry command keys (cmd:<entry>), which the UI entries write and the service watches.

local M = {}

M.CONN = "conn" -- { state, retryAfterMs?, retryAt?, expiresAt?, kind?, reason?, message? }
M.SCOPES = "scopes" -- { string } granted scopes
M.SIGNED_IN = "signedIn" -- boolean
M.APP_VERSION = "appVersion" -- Sonolith version string
M.PLAYER = "player" -- PlayerState
M.TRACK = "track" -- { item = MediaItem? }
M.ART = "art" -- { trackId, path (512 px), thumb (128 px) }
M.POSITION = "position" -- { positionMs, positionAt, durationMs, rate, status }
M.QUEUE = "queue" -- QueueSummary + { items = { QueueEntry } }
M.LYRICS = "lyrics" -- { trackId, status, tier, lineIndex?, line?, words? ({ startMs, text }), nextLine? }
M.SCOPE_REQUEST = "scopeRequest" -- outcome of the last app.requestScopes: { status, retryAt? }
M.REV = "rev" -- bumped on every change

-- Connection states, as the bridge reports them, plus the service's own "noPython" / "starting".
M.CONNECTED = "connected"

function M.cmdKey(entry)
  return "cmd:" .. entry
end

function M.resKey(entry)
  return "res:" .. entry
end

function M.get(key)
  return noctalia.state.get(key)
end

function M.hasScope(scope)
  local scopes = noctalia.state.get(M.SCOPES)
  if type(scopes) ~= "table" then
    return false
  end
  for _, s in ipairs(scopes) do
    if s == scope then
      return true
    end
  end
  return false
end

function M.isConnected()
  local conn = noctalia.state.get(M.CONN)
  return type(conn) == "table" and conn.state == M.CONNECTED
end

-- The current item, or nil.
function M.track()
  local t = noctalia.state.get(M.TRACK)
  return type(t) == "table" and t.item or nil
end

-- The playback position now, extrapolated from the last event: positionMs + (now - positionAt) * rate.
function M.positionNow(pos)
  pos = pos or noctalia.state.get(M.POSITION)
  if type(pos) ~= "table" or pos.positionMs == nil then
    return 0, nil
  end
  local ms = pos.positionMs
  if pos.status == "playing" and pos.positionAt then
    ms += math.max(0, noctalia.nowMs() - pos.positionAt) * (pos.rate or 1)
  end
  if pos.durationMs then
    ms = math.min(ms, pos.durationMs)
  end
  return ms, pos.durationMs
end

return M
