--!nonstrict
-- Launcher entries have no update timer; queue-events wakes pending callbacks.
local M = {}
local tasks, serial, published = {}, 0, nil
local function publish()
    local due
    for _, task in pairs(tasks) do if not due or task.due < due then due = task.due end end
    if due ~= published then
        published = due
        noctalia.state.set("work_deadline", due)
    end
end
function M.after(delay, callback)
    serial = serial + 1
    tasks[serial] = {due = noctalia.nowMs() + delay, callback = callback}
    publish()
    return serial
end
function M.cancel(id)
    if id then tasks[id] = nil; publish() end
end
function M.clear()
    tasks = {}
    publish()
end
noctalia.state.set("work_deadline", nil)
noctalia.state.watch("work_tick", function()
    local now, ready = noctalia.nowMs(), {}
    for id, task in pairs(tasks) do
        if task.due <= now then table.insert(ready, {id = id, task = task}) end
    end
    table.sort(ready, function(a, b) return a.task.due < b.task.due end)
    for _, entry in ipairs(ready) do
        if tasks[entry.id] == entry.task then
            tasks[entry.id] = nil
            entry.task.callback()
        end
    end
    publish()
end)
return M
