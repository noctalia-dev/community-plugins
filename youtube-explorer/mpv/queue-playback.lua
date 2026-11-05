local mp = require("mp")
local utils = require("mp.utils")
local options = {queue_path = "", helper = "", python = ""}
require("mp.options").read_options(options, "queue-playback")
if options.queue_path == "" or options.helper == "" or options.python == "" then return end

local entries = {}
local played = {}
for _, id in ipairs(mp.get_property_native("user-data/youtube-explorer-played") or {}) do played[id] = true end
local loading
mp.register_event("start-file", function(event) loading = event.playlist_entry_id end)
local function trackQueue(replay, refresh, identifyOnly)
    local file = io.open(options.queue_path, "r")
    if not file then return end
    local body = file:read("*a"); file:close()
    local queue = utils.parse_json(body)
    if type(queue) ~= "table" or type(queue.items) ~= "table" then return end
    local path = mp.get_property("path", "")
    local mapped = mp.get_property_native("user-data/youtube-explorer-entries") or {}
    for _, item in ipairs(queue.items) do
        if path == "https://www.youtube.com/watch?v=" .. item.id and type(item.queueToken) == "string"
            and (mapped[item.queueToken] == loading or (not replay and not mapped[item.queueToken])) then
            entries[loading] = {id = item.id, token = item.queueToken}
            if not identifyOnly and (not replay or refresh) then
                local _, error = mp.command_native({
                    "run", options.python, options.helper, refresh and "prepare" or "started", options.queue_path,
                    "--queue-start=" .. item.id, "--queue-token=" .. item.queueToken,
                    "--queue-pid=" .. tostring(utils.getpid()),
                })
                if error then mp.msg.error("Could not update active queue: " .. tostring(error)) end
            end
            break
        end
    end
end
mp.add_hook("on_load", 5, function()
    trackQueue(played[loading] == true, false, true)
    if played[loading] then
        mp.set_property("file-local-options/start", "0")
        mp.set_property("file-local-options/resume-playback", "no")
    end
end)
mp.register_event("file-loaded", function()
    local replay = played[loading] == true
    played[loading] = true
    local ids = {}
    for id in pairs(played) do ids[#ids + 1] = id end
    mp.set_property_native("user-data/youtube-explorer-played", ids)
    trackQueue(replay, false)
end)
mp.register_script_message("youtube-explorer-queue-cleared", function()
    -- Rebind the kept song so its completion still consumes the queue entry,
    -- including when Previous reached a song that had left queue storage.
    -- The helper disables Mix on Clear or reserves the fetch ticket on Refresh.
    trackQueue(true, true)
end)

mp.register_event("end-file", function(event)
    local entry = entries[event.playlist_entry_id]
    entries[event.playlist_entry_id] = nil
    if not entry or (event.reason ~= "eof" and event.reason ~= "stop" and event.reason ~= "error") then return end
    -- Detach so closing mpv cannot kill a pending queue update. Tokens and entry
    -- IDs keep a late event from consuming a replay or an unplayed queue item.
    local _, error = mp.command_native({
        "run", options.python, options.helper, event.reason == "error" and "failed" or "complete", options.queue_path,
        "--queue-start=" .. entry.id, "--queue-token=" .. entry.token,
        "--queue-entry=" .. tostring(event.playlist_entry_id),
    })
    if error then mp.msg.error("Could not update playback queue: " .. tostring(error)) end
end)

mp.register_event("shutdown", function()
    -- Also clear when closing an idle player or a video that is still loading.
    local _, error = mp.command_native({"run", options.python, options.helper, "close", options.queue_path,
        "--queue-pid=" .. tostring(utils.getpid())})
    if error then mp.msg.error("Could not clear playback queue: " .. tostring(error)) end
end)
