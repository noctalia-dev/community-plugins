--!nonstrict
local state = require("../rest_state")

local function local_ms(year, month, day, hour)
  return os.time({ year = year, month = month, day = day, hour = hour or 12, min = 0, sec = 0 }) * 1000
end

local leap_end = state.day_end_ms("2024-02-29")
assert(leap_end ~= nil)
local final_second = os.date("*t", math.floor(leap_end / 1000))
local next_second = os.date("*t", math.floor((leap_end + 1) / 1000))
assert(final_second.year == 2024 and final_second.month == 2 and final_second.day == 29)
assert(final_second.hour == 23 and final_second.min == 59 and final_second.sec == 59)
assert(next_second.year == 2024 and next_second.month == 3 and next_second.day == 1)
assert(state.day_end_ms("2024-02-30") == nil)
assert(state.date_after_days(local_ms(2026, 1, 31), 1) == "2026-02-01")
assert(state.date_after_days(local_ms(2024, 2, 28), 1) == "2024-02-29")
assert(state.date_after_days(local_ms(2026, 12, 28), 7) == "2027-01-04")

local now_ms = local_ms(2026, 3, 10)
local day_end = state.day_end_ms("2026-03-11")
local normalized = state.normalize({
  {
    id = "date-only",
    title = "Date task",
    notes = "notes",
    isDone = false,
    projectId = "project-1",
    tagIds = { "tag-1" },
    dueDay = "2026-03-11",
    timeEstimate = 60000,
    timeSpent = 30000,
    created = 2,
  },
  {
    id = "timed",
    title = "Timed task",
    dueWithTime = day_end,
    dueDay = "2026-03-11",
    created = 1,
  },
  { id = "done", title = "Done", isDone = true, dueWithTime = now_ms - 1 },
  { id = "tracked", title = "Tracked", isDone = false, created = 3 },
}, {
  { id = "project-1", title = "Work" },
}, {
  { id = "tag-1", title = "urgent" },
}, {
  currentTaskId = "tracked",
}, now_ms)

assert(normalized.currentTask.id == "tracked")
assert(normalized.upcoming[1].id == "timed", "timed due wins an equal date-only timestamp")
assert(normalized.upcoming[2].id == "date-only")
local task = normalized.upcoming[2]
assert(task.id == "date-only")
assert(task.title == "Date task" and task.notes == "notes" and task.isDone == false)
assert(task.project == "Work" and task.tags[1] == "urgent")
assert(task.dueDay == "2026-03-11" and task.dueAt == day_end and task.dueKind == "day")
assert(task.timeEstimate == 60000 and task.timeSpent == 30000 and task.created == 2)
assert(normalized.counts.active == 3 and normalized.counts.due == 2 and normalized.counts.overdue == 0)

local fallback = state.normalize({}, {}, {}, {
  currentTaskId = "outside",
  currentTask = { id = "outside", title = "Outside", isDone = false },
}, now_ms)
assert(fallback.currentTask.id == "outside")

local many = {}
for index = 1, 51 do
  table.insert(many, {
    id = "task-" .. tostring(index),
    title = "Task",
    isDone = false,
    dueWithTime = now_ms + index,
    created = index,
  })
end
local bounded = state.normalize(many, {}, {}, { currentTaskId = "task-51" }, now_ms)
assert(#bounded.upcoming == state.constants.MAX_UPCOMING)
assert(bounded.currentTask.id == "task-51")
assert(bounded.counts.active == 51 and bounded.counts.due == 51)

local overdue_normalized = state.normalize({
  { id = "overdue", title = "Overdue", dueDay = "2026-03-09", created = 1 },
  { id = "shared-1", title = "Shared", dueDay = "2026-03-11", created = 2 },
  { id = "shared-2", title = "Shared", dueDay = "2026-03-11", created = 3 },
  { id = "done", title = "Done", isDone = true, dueDay = "2026-03-11", created = 4 },
  { id = "", title = "Ignored", dueDay = "2026-03-11", created = 5 },
}, {}, {}, {
  currentTaskId = "fallback",
  currentTask = { id = "fallback", title = "Fallback", dueDay = "2026-03-11" },
}, now_ms)
assert(overdue_normalized.currentTask.id == "fallback" and overdue_normalized.currentTask.dueAt == day_end)
assert(overdue_normalized.upcoming[1].id == "overdue" and overdue_normalized.upcoming[2].id == "shared-1"
  and overdue_normalized.upcoming[3].id == "shared-2")
assert(overdue_normalized.counts.active == 3 and overdue_normalized.counts.due == 3
  and overdue_normalized.counts.overdue == 1)

print("REST state tests passed")
