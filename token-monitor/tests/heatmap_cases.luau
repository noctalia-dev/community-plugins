local Heatmap = require("../lib/heatmap.luau")
local total = 0
local function test(name, fn) fn(); total += 1; print("PASS " .. name) end
local function find(data, date)
    for _, column in ipairs(data.columns) do
        for _, cell in ipairs(column.cells) do if cell.date == date then return cell end end
    end
    error("date outside window: " .. date)
end
local function ctx(today, metric, weeks)
    return { today = today, heatmapMetric = metric, heatmapWeeks = weeks }
end

test("strict Gregorian dates and reversible ordinal boundaries", function()
    for _, date in ipairs({"2000-02-29", "2024-02-29", "1900-03-01", "0001-01-01", "9999-12-31"}) do
        local parsed = assert(Heatmap.parseDate(date))
        assert(Heatmap.dateFromOrdinal(parsed.ordinal) == date)
    end
    for _, date in ipairs({"1900-02-29", "2100-02-29", "2025-02-29", "2026-04-31", "0000-01-01", "2026-00-01", "2026-13-01",
        "2026-10-00", "2026-10-32", "2026-1-01", "2026-10-23T00:00:00Z", " 2026-10-23"}) do
        assert(Heatmap.parseDate(date) == nil, date)
    end
    assert(Heatmap.parseDate(false) == nil and Heatmap.dateFromOrdinal(-1) == nil)
    assert(Heatmap.dateFromOrdinal(math.huge) == nil and Heatmap.dateFromOrdinal(0/0) == nil)
    assert(Heatmap.parseDate("0001-01-01").weekday == 1)
    assert(Heatmap.parseDate("2026-10-23").weekday == 5)
end)
test("cross year weeks use Monday rows and end at current Sunday", function()
    local data = Heatmap.build({}, ctx("2027-01-01", "tokens", 13))
    assert(data.valid and #data.columns == 13)
    assert(data.firstDate == "2026-10-05" and data.lastDate == "2027-01-03")
    assert(data.columns[13].cells[1].date == "2026-12-28")
    assert(data.columns[13].cells[5].date == "2027-01-01")
    assert(data.columns[13].cells[7].state == "future")
    for _, column in ipairs(data.columns) do
        assert(#column.cells == 7)
        assert(Heatmap.parseDate(column.cells[1].date).weekday == 1)
        assert(Heatmap.parseDate(column.cells[7].date).weekday == 7)
    end
    assert(Heatmap.build({}, ctx("2024-03-01", nil, 13)).lastDate == "2024-03-03")
end)
test("missing recorded unknown zero and future retain separate semantics", function()
    local input = {
        {date = "2026-10-19", tokens = 0, messages = 0},
        {date = "2026-10-20", tokens = 100},
        {date = "2026-10-21", tokens = 200, messages = -1},
        {date = "2026-10-23", tokens = 50, messages = 0/0},
        {date = "2026-10-24", tokens = 999999, messages = 500},
        {date = "2026-02-30", tokens = 777},
    }
    local options = ctx("2026-10-23", "messages", 13)
    options.selectedDay = "2026-10-20"
    local data = Heatmap.build(input, options)
    assert(data.recordedCount == 4 and data.knownCount == 1 and data.peak == 0)
    assert(find(data, "2026-10-19").state == "zero" and find(data, "2026-10-19").value == 0)
    assert(find(data, "2026-10-20").state == "unknown" and find(data, "2026-10-20").recorded)
    assert(find(data, "2026-10-20").selected)
    assert(find(data, "2026-10-21").state == "unknown" and find(data, "2026-10-23").state == "unknown")
    assert(find(data, "2026-10-22").state == "missing" and not find(data, "2026-10-22").recorded)
    assert(find(data, "2026-10-24").state == "future" and find(data, "2026-10-24").value == nil)
    assert(not find(data, "2026-10-24").selected and not find(data, "2026-10-24").recorded)
    assert(data.latestRecordedDate == "2026-10-23")
    assert(input[2].messages == nil and input[5].tokens == 999999)
end)
test("four relative intensity levels use only the visible selected metric", function()
    local rows = {{date = "2026-10-19", tokens = 1, cost = 0.000123456789},
        {date = "2026-10-20", tokens = 2, cost = 0.4}, {date = "2026-10-21", tokens = 3},
        {date = "2026-10-22", tokens = 4}, {date = "2020-01-01", tokens = 10000000},
        {date = "2026-10-23", tokens = math.huge}}
    local data = Heatmap.build(rows, ctx("2026-10-23", "tokens", 13))
    assert(data.peak == 4 and data.knownCount == 4)
    for index = 1, 4 do assert(find(data, "2026-10-" .. tostring(18 + index)).level == index) end
    local cost = Heatmap.build(rows, ctx("2026-10-23", "cost", 13))
    assert(cost.peak == 0.4 and find(cost, "2026-10-19").value == 0.000123456789)
    assert(find(cost, "2026-10-21").state == "unknown")
end)
test("bounded windows duplicate buckets and unavailable calendar are deterministic", function()
    local data = Heatmap.build({{date = "2026-10-23", tokens = 3}, {date = "2026-10-23", tokens = 7}}, ctx("2026-10-23", "invalid", 26))
    assert(#data.columns == 26 and data.firstDate == "2026-04-27" and data.lastDate == "2026-10-25")
    assert(data.metric == "tokens" and data.recordedCount == 1 and find(data, "2026-10-23").value == 7)
    assert(#Heatmap.build({}, ctx("2026-10-23", "tokens", 500)).columns == 26)
    assert(not Heatmap.build({}, {}).valid and #Heatmap.build({}, {}).columns == 0)
    local edge = Heatmap.build({}, ctx("0001-01-01", "tokens", 13))
    assert(edge.columns[1].cells[1].state == "outside")
    local endEdge = Heatmap.build({}, ctx("9999-12-31", "tokens", 13))
    assert(endEdge.columns[13].cells[7].state == "outside")
end)
print(tostring(total) .. " heatmap cases passed")
