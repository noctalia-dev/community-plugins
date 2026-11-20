--!nonstrict
-- Pricing and usage history: the model rates pricing.sh fetches once a day, and the cost
-- history usage-stats.sh builds from every account's transcripts with them, both
-- published for the Usage tab. New rates re-queue every live session's details, which
-- were priced with the old ones.

local core = require("./service-core.luau")
local acc = require("./service-accounts.luau")
local details = core.details
local cfg, decode, runJson, publish, script = core.cfg, core.decode, core.runJson, core.publish, core.script
local PRICING, DATA = core.PRICING, core.DATA
local M = {}

local usagePending, pricingPending = false, false
M.usageAt = -math.huge

function M.publishPricing()
  local p = decode(noctalia.readFile(PRICING))
  publish("pricing", p and { updated = p.updated, rates = p.rates } or nil)
end

-- Once a day (the file records the date it was fetched); callback runs either way.
local function refreshPricing(done)
  local p = decode(noctalia.readFile(PRICING))
  if (p and p.updated == os.date("%Y-%m-%d")) or pricingPending then done() return end
  pricingPending = true
  local url = noctalia.string.trim(tostring(cfg("currency_api_url", "")))
  if url == "" then url = "https://api.frankfurter.dev/v1/latest" end
  local started = noctalia.runAsync(script("pricing.sh", PRICING, url), function(r)
    pricingPending = false
    for _, d in pairs(details) do d.key = nil end
    if r.exitCode ~= 0 then noctalia.log("claude-operator: pricing refresh failed: " .. noctalia.string.trim(r.stderr or "")) end
    M.publishPricing()
    done()
  end, 40000)
  if not started then pricingPending = false; done() end
end

function M.refreshUsage()
  if usagePending then return end
  usagePending, M.usageAt = true, noctalia.nowMs()
  refreshPricing(function()
    local argv = script("usage-stats.sh", PRICING, DATA .. "/usage")
    for _, a in ipairs(acc.accountList()) do argv[#argv + 1] = a.dir end
    local started = runJson(argv, 60000, function(usage, r)
      usagePending = false
      if usage then
        usage.updated = noctalia.nowMs()
        publish("usage", usage)
      else
        noctalia.log("claude-operator: usage stats failed: " .. noctalia.string.trim(r.stderr or ""))
      end
    end)
    if not started then usagePending = false end
  end)
end

return M
