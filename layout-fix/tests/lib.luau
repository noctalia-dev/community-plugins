--!nonstrict
-- Helpers shared by the cases. The service keeps its state in locals that
-- nothing can reset, so each case file gets its own luau process and a
-- genuinely fresh service — see run-tests.sh.

local T = LayoutTest

Result = { passed = 0, failed = 0 }

function check(name, ok, detail)
    if ok then
        Result.passed += 1
        print("  ok   " .. name)
    else
        Result.failed += 1
        print("  FAIL " .. name .. (detail ~= nil and ("  — " .. tostring(detail)) or ""))
    end
end

function equals(name, actual, expected)
    check(name, actual == expected,
        "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

function contains(name, haystack, needle)
    check(name, string.find(tostring(haystack), needle, 1, true) ~= nil, haystack)
end

function absent(name, haystack, needle)
    check(name, string.find(tostring(haystack), needle, 1, true) == nil, haystack)
end

function ticks(count)
    for _ = 1, count do
        update()
    end
end

-- Past the startup delay, so everything the service does on startup has run.
function boot()
    ticks(8)
end

function commandMatching(pattern)
    for _, cmd in ipairs(T.commands) do
        if string.find(cmd, pattern, 1, true) ~= nil then
            return cmd
        end
    end
    return nil
end

function notificationBodies()
    local bodies = {}
    for _, entry in ipairs(T.notifications) do
        table.insert(bodies, entry.body)
    end
    return table.concat(bodies, " | ")
end

function finish()
    print(string.format("%d passed, %d failed", Result.passed, Result.failed))
    if Result.failed > 0 then
        error("case failed", 0)
    end
end
