--!nonstrict
-- shared — constants and helpers common to all three entries (bar widget,
-- service, panel), pulled in via require() (relative same-plugin import,
-- plugin_api >= 22). Centralizing these removes the risk the three copies
-- drift apart — e.g. STATE_KEY renamed in one file but not the others would
-- silently break state.watch instead of failing loudly.

local shared = {}

-- engine (service.luau) publishes  STATE_KEY   = { nonce, phase, step, total,
--                                                   counts, uncounted,
--                                                   dismissed, err, checkedAt,
--                                                   configPath, excluded }
-- UI entries send                  REQUEST_KEY = { nonce, action } -- check|update|dismiss
shared.STATE_KEY = "topgrade_state"
shared.REQUEST_KEY = "topgrade_request"

function shared.tr(key, args)
    return noctalia.tr(key, args)
end

-- The nonce is monotonic across writers (every widget instance and the
-- panel): each seeds from the last request already in the shared state.
function shared.request(action)
    local prev = noctalia.state.get(shared.REQUEST_KEY)
    local nonce = (type(prev) == "table" and tonumber(prev.nonce) or 0) + 1
    noctalia.state.set(shared.REQUEST_KEY, { nonce = nonce, action = action })
end

return shared
