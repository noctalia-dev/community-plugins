--!nonstrict
-- VS Code launcher provider ("/code") - a thin client. Results come from the service's
-- "vscode.state" snapshot through view_launcher; Enter sends one `open {key}` request.
-- setResults must carry the exact query onQuery got, so the last one is kept and results
-- are set again whenever a new snapshot arrives.

local view_launcher = require("./view_launcher.luau")

local STATE_KEY = "vscode.state"
local REQUEST_KEY = "vscode.request"

local snapshot = noctalia.state.get(STATE_KEY)
local lastQuery = nil
local lastQueryAt = 0
local REPUBLISH_WINDOW_MS = 5000 -- a snapshot re-publishes only this soon after a query
local counter = 0

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function send(request)
  counter = counter + 1
  request.requestId = "launcher-" .. noctalia.nowMs() .. "-" .. counter
  noctalia.state.set(REQUEST_KEY, request)
end

local function publish()
  if lastQuery == nil then
    return
  end
  local text = noctalia.string.trim(lastQuery)
  launcher.setResults(lastQuery, view_launcher.results(snapshot, text, noctalia.fuzzyScore, tr))
end

function onQuery(query)
  lastQuery = query
  lastQueryAt = noctalia.nowMs()
  if noctalia.string.trim(query) == "" then
    send({ action = "refresh" })
  end
  publish()
end

function onActivate(id)
  if id == nil or id == "" then
    return
  end
  -- A missing entry (a pinned folder that is gone) has nothing to open.
  if type(snapshot) == "table" then
    for _, list in ipairs({ snapshot.pinned or {}, snapshot.recent or {} }) do
      for _, e in ipairs(list) do
        if e.key == id and e.missing then
          return
        end
      end
    end
  end
  send({ action = "open", key = id })
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) ~= "table" then
    return
  end
  snapshot = value
  if noctalia.nowMs() - lastQueryAt <= REPUBLISH_WINDOW_MS then
    publish()
  end
end)
