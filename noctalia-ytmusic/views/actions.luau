local REQ_KEY = "noctalia_ytmusic.request"

local req_nonce = os.time() * 1000

local function request(action, payload)
    req_nonce = math.max(req_nonce + 1, os.time() * 1000)
    local msg = { action = action, nonce = req_nonce }
    for k, v in pairs(payload or {}) do
        msg[k] = v
    end
    noctalia.state.set(REQ_KEY, msg)
end

return request