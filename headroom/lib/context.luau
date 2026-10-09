--!nonstrict
-- Builds the provider.Context adapters run with, from a Noctalia host.
--
-- The one place host capabilities are handed to adapters, so what an adapter
-- can do is exactly this table. The service and the tests both build their
-- context here, so neither can drift from the other.

local http = require("./http.luau")
local time = require("./time.luau")

local M = {}

function M.new(host, userAgent: string)
  local function decodeJson(text: string)
    return host.json.decode(text)
  end

  return {
    now = function()
      return math.floor(host.nowMs() / 1000)
    end,
    env = host.getenv,
    expandPath = host.expandPath,
    fileExists = host.fileExists,
    readFile = function(path: string)
      return (host.readFile(path))
    end,
    readJson = function(path: string)
      local text, err = host.readFile(path)
      if text == nil then
        return nil, err
      end
      return decodeJson(text)
    end,
    decodeJson = decodeJson,
    getJson = http.client(host.http, decodeJson),
    postJson = http.postClient(host.http, decodeJson),
    run = function(argv: { string }, timeoutMs: number, done)
      local started = host.runAsync(argv, function(result)
        done(if result.timedOut then nil else result)
      end, timeoutMs)
      if not started then
        done(nil)
      end
    end,
    which = host.commandExists,
    duration = time.duration,
    tr = host.tr,
    userAgent = userAgent,
  }
end

return M
