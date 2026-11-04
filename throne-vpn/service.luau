--!nonstrict
-- One worker for all panel/widget instances; the Python helper is bundled.
local helper = noctalia.pluginDir() .. "/backend.py"
local fetching = false
local acting = false
local generation = 0
local tr = noctalia.tr

local function arguments()
    return {
        "python3", helper,
        "--addr=" .. (noctalia.getConfig("api_address") or "127.0.0.1:9095"),
        "--key-file=" .. (noctalia.getConfig("api_key_file") or ""),
        "--thronectl=" .. (noctalia.getConfig("thronectl_path") or "thronectl"),
    }
end

local function decode(result)
    if result.timedOut or result.stdoutTruncated then
        return { ok = false, error = tr("errors.timeout") }
    end
    local data = noctalia.json.decode(result.stdout or "")
    if type(data) == "table" and type(data.ok) == "boolean" then
        if result.exitCode ~= 0 and data.ok then return { ok = false, error = tr("errors.command") } end
        return data
    end
    return { ok = false, error = tr("errors.response") }
end

local fetch
fetch = function()
    if fetching or acting then return end
    fetching = true
    local started = generation
    local argv = arguments()
    table.insert(argv, "--snapshot")
    local accepted = noctalia.runAsync(argv, function(result)
        fetching = false
        if started ~= generation then fetch(); return end
        noctalia.state.set("snapshot", decode(result))
    end)
    if not accepted then
        fetching = false
        noctalia.state.set("snapshot", { ok = false, error = tr("errors.launch") })
    end
end

local function act(request)
    if acting or type(request) ~= "table" then return end
    local argv = arguments()
    if request.kind == "connect" then
        local id = request.id
        if id ~= "last" and (type(id) ~= "number" or id ~= id or id < 0 or id > 9007199254740991 or id % 1 ~= 0) then return end
        table.insert(argv, "--connect")
        table.insert(argv, id == "last" and "last" or string.format("%.0f", id))
    elseif request.kind == "disconnect" then
        table.insert(argv, "--disconnect")
    else
        return
    end
    generation = generation + 1
    local started = generation
    acting = true
    noctalia.state.set("action_error", "")
    noctalia.state.set("busy", true)
    local accepted = noctalia.runAsync(argv, function(result)
        local data = decode(result)
        acting = false
        if started == generation then
            if data.ok and result.exitCode == 0 then
                local cached = noctalia.state.get("snapshot")
                if type(cached) == "table" and cached.ok and type(data.status) == "table" then
                    cached.status = data.status
                    noctalia.state.set("snapshot", cached)
                end
            else
                noctalia.state.set("action_error", data.error or tr("errors.command"))
            end
        end
        noctalia.state.set("busy", false)
        fetch()
    end)
    if not accepted then
        acting = false
        noctalia.state.set("action_error", tr("errors.launch"))
        noctalia.state.set("busy", false)
    end
end

local function interval()
    local seconds = tonumber(noctalia.getConfig("poll_seconds")) or 3
    noctalia.setUpdateInterval(math.max(2, math.min(60, math.floor(seconds))) * 1000)
end

function onConfigChanged()
    generation = generation + 1
    noctalia.state.set("action_error", "")
    noctalia.state.set("snapshot", { ok = false, error = tr("status.loading") })
    interval()
    fetch()
end

noctalia.state.set("busy", false)
noctalia.state.set("action_error", "")
noctalia.state.watch("action", act)
noctalia.state.watch("refresh", function() fetch() end)
interval()
function update() fetch() end
fetch()
