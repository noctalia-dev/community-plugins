local time = require("../lib/time.luau")
local checked = 0
local function equal(actual, expected, message)
    checked = checked + 1
    assert(actual == expected, (message or "unexpected value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function label(actual, key, values)
    equal(actual.key, "time." .. key)
    for name, expected in pairs(values or {}) do equal(actual.values[name], expected, name) end
end

equal(time.parse("1970-01-01T00:00:00Z"), 0)
equal(time.parse("1969-12-31T23:59:59Z"), -1)
equal(time.parse("2000-02-29T00:00:00Z"), 951782400, "century leap day")
equal(time.parse("2024-02-29T12:34:56.125Z"), 1709210096.125)
equal(time.parse("1970-01-01T08:00:00+08:00"), 0, "positive offset subtracts")
equal(time.parse("1969-12-31T19:00:00-0500"), 0, "negative offset adds across day")
equal(time.parse("2024-03-01T00:30:00+01:00"), time.parse("2024-02-29T23:30:00Z"), "offset crosses leap day")
equal(time.parse("1970-01-01t00:00:00.5z"), 0.5)
equal(time.parse("1970-01-01T00:00:00+0000"), 0)
equal(time.parse("1970-01-01T00:00:00-00:00"), 0)
for _, invalid in ipairs({ "1900-02-29T00:00:00Z", "2023-02-29T00:00:00Z", "2024-04-31T00:00:00Z",
    "2024-00-01T00:00:00Z", "2024-13-01T00:00:00Z", "2024-01-00T00:00:00Z", "0000-01-01T00:00:00Z",
    "2024-01-01T24:00:00Z", "2024-01-01T00:60:00Z", "2024-01-01T00:00:60Z",
    "2024-01-01T00:00:00", "2024-01-01", "2024-01-01T00:00:00+24:00", "2024-01-01T00:00:00+00:60",
    "2024-01-01T00:00:00.Z", "2024-01-01T00:00:00Zjunk" }) do
    equal(time.parse(invalid), nil, invalid)
end
equal(time.parse(false), nil)
equal(time.parse(0), nil, "numeric units are not guessed")
local epoch = time.parse("2024-02-29T23:59:30Z")
local stamp = "2024-02-29T23:59:30Z"
label(time.age(stamp, epoch - 1), "future")
label(time.age(stamp, epoch), "just_now")
label(time.age(stamp, epoch + 59.9), "just_now")
label(time.age(stamp, epoch + 60), "minutes_ago", { count = 1 })
label(time.age(stamp, epoch + 3660), "hours_ago", { hours = 1, minutes = 1 })
label(time.age(stamp, epoch + 90000), "days_ago", { days = 1, hours = 1 })
label(time.countdown(stamp, epoch), "reset_due")
label(time.countdown(stamp, epoch + 86400), "reset_due")
label(time.countdown(stamp, epoch - 0.1), "less_than_minute")
label(time.countdown(stamp, epoch - 59.9), "less_than_minute")
label(time.countdown(stamp, epoch - 60), "resets_minutes", { count = 1 })
label(time.countdown(stamp, epoch - 60.1), "resets_minutes", { count = 2 })
label(time.countdown(stamp, epoch - 3660), "resets_hours", { hours = 1, minutes = 1 })
label(time.countdown(stamp, epoch - 90000), "resets_days", { days = 1, hours = 1 })
label(time.age("invalid", epoch), "unknown")
label(time.countdown(stamp, 0 / 0), "unknown")
label(time.age(stamp, math.huge), "unknown")
print("time cases passed (" .. checked .. " assertions)")
