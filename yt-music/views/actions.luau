local REQ_KEY = "yt_music.request"

-- Millisecond clock + jitter: entries (mini vs full panel) are separate
-- processes seeding their own counter; seeded >=1ms apart, the >=1000 gap can
-- never be bridged by the +/-999 jitter, so cross-entry nonces cannot collide.
local req_nonce = noctalia.nowMs() * 1000 + math.random(0, 999)

local function request(action, payload)
    req_nonce = math.max(req_nonce + 1, noctalia.nowMs() * 1000)
    local msg = { action = action, nonce = req_nonce }
    for k, v in pairs(payload or {}) do
        msg[k] = v
    end
    noctalia.state.set(REQ_KEY, msg)
end

return request