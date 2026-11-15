--!nonstrict
-- Pure modules with state over time: the scheduler and the notification latches.

local t = require("./support/t")
local env = require("./support/env")

local host = env.host()
local mods = env.modules(host)
local scheduler = mods.require("lib/scheduler.luau")
local notify = mods.require("lib/notify.luau")
local model = mods.require("lib/model.luau")

t.group("scheduler", function()
  -- Random runs of every event the service sends it. Invariants:
  --   at most one request per entry is current, and only its reply counts;
  --   a throttled entry is never fetched before its wait is over;
  --   a request with no reply ends within the timeout.
  t.test("invariants over random event sequences", function()
    local seed = 7
    local function rand(n: number): number
      seed = (seed * 1103515245 + 12345) % 2147483648
      return seed % n + 1
    end
    for _ = 1, 200 do
      local entry = scheduler.new()
      local now = 0
      local out = {} -- generations of requests sent
      local throttledUntil = nil
      for _ = 1, 60 do
        local op = rand(7)
        now += rand(120)
        local lost = scheduler.expired(entry, now)
        if lost then
          t.ok(scheduler.finish(entry, entry.generation, now, 300, lost), "timeout ends the request")
        end
        if op == 1 and scheduler.isDue(entry, now) then
          t.ok(throttledUntil == nil or now >= throttledUntil, "never fetched while throttled")
          table.insert(out, scheduler.start(entry, now))
        elseif op == 2 and #out > 0 then
          local generation = out[rand(#out)]
          local code = ({ "network", "rate_limited", "auth", nil })[rand(4)]
          local accepted = scheduler.finish(entry, generation, now, 300, code and model.err(code) or nil)
          t.ok(not accepted or generation == out[#out], "only the latest request's reply counts")
          if accepted then
            throttledUntil = if code == "rate_limited" then entry.nextAt else nil
          end
        elseif op == 3 then
          scheduler.force(entry, now)
        elseif op == 4 then
          scheduler.cap(entry, now, rand(600))
        elseif op == 5 then
          scheduler.abandon(entry, now) -- the sign-in changed
        end
        t.ok(entry.state ~= "inflight" or now - entry.since < scheduler.TIMEOUT_SECONDS + 120, "no request outlives its timeout by a tick")
      end
    end
  end)
end)

t.group("notifications", function()
  local function opts(now: number)
    return {
      critical = 90,
      enabled = true,
      credits = true,
      interval = 300,
      now = now,
      tr = host.globals.noctalia.tr,
      trp = host.globals.noctalia.trp,
      duration = function(s)
        return `{s}s`
      end,
    }
  end
  local function snap(percent: number, resetsAt: number, credits)
    return { windows = { { id = "weekly", label = "Weekly", usedPercent = percent, resetsAt = resetsAt } }, resetCredits = credits }
  end

  t.test("one warning per cycle, whatever the jitter; the reset only when it is news", function()
    local latches = {}
    t.eq(#notify.messages("Claude", snap(92, 1000), latches, opts(0)), 1)
    t.eq(#notify.messages("Claude", snap(95, 1000.4), latches, opts(10)), 0, "same cycle, jittered")
    t.eq(#notify.messages("Claude", snap(80, 1001), latches, opts(20)), 0, "dipped, same cycle")
    t.eq(#notify.messages("Claude", snap(91, 1000), latches, opts(30)), 0, "back over, same cycle")
    local reset = notify.messages("Claude", snap(5, 605800), latches, opts(1100))
    t.eq(#reset, 1)
    t.ok(reset[1].title:find("has reset"), "reset message")

    -- A cycle that ended a week ago is not announced.
    local old = {}
    notify.messages("Claude", snap(95, 1000), old, opts(0))
    t.eq(#notify.messages("Claude", snap(5, 605800), old, opts(600000)), 0)
  end)

  t.test("a credit about to expire is announced once", function()
    local latches = {}
    local credits = { { count = 1, label = "Weekly limit reset", expiresAt = 200000 } }
    t.eq(#notify.messages("Codex", snap(10, 1000, credits), latches, opts(0)), 0, "more than two days left")
    t.eq(#notify.messages("Codex", snap(10, 1000, credits), latches, opts(100000)), 1)
    t.eq(#notify.messages("Codex", snap(10, 1000, credits), latches, opts(100300)), 0)
    -- One reply without the credit list (a failed read) does not re-arm it.
    t.eq(#notify.messages("Codex", snap(10, 1000, nil), latches, opts(100600)), 0)
    t.eq(#notify.messages("Codex", snap(10, 1000, credits), latches, opts(100900)), 0)
  end)
end)

return nil
