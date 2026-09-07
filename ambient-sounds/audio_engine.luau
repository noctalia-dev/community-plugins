--!nonstrict
-- Owns mpv processes, their IPC sockets, and PipeWire master volume.
local AudioEngine = {}
AudioEngine.__index = AudioEngine
local pluginRoot = noctalia.pluginDir() or "."

-- The bundled recordings are quieter than typical desktop audio. Keep the UI
-- at a familiar 0–100 range while giving each source a small 35% gain boost.
local SOURCE_GAIN = 1.35
local AMPLIFY_GAIN = 1.5

local function playerVolume(sound)
    local amplify = sound.amplified and AMPLIFY_GAIN or 1
    return math.floor(sound.level * SOURCE_GAIN * amplify)
end

local function systemVolume(callback)
    noctalia.runAsync({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(result)
        local volume = 100
        local value = result and result.stdout and result.stdout:match("(%d+%.?%d*)")

        if value then
            volume = math.floor((tonumber(value) or 1) * 100)
        end

        callback(volume)
    end)
end

local function commandJson(command)
    local json = '{"command":['

    for index, value in ipairs(command) do
        if index > 1 then
            json = json .. ","
        end

        if type(value) == "string" then
            json = json .. '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
        elseif type(value) == "boolean" then
            json = json .. (value and "true" or "false")
        else
            json = json .. tostring(value)
        end
    end

    return json .. "]}"
end

function AudioEngine.new(sounds)
    return setmetatable({
        sounds = sounds,
        running = false,
        masterVolume = 100,
        volumeRequestInFlight = false,
        socketDir = "/tmp/noctalia-ambient-" .. tostring(os.time()),
    }, AudioEngine)
end

function AudioEngine:socketPath(sound)
    return self.socketDir .. "/" .. sound.id .. ".sock"
end

function AudioEngine:sendCommand(sound, command)
    local json = commandJson(command)

    noctalia.runAsync({
        "/bin/sh",
        "-c",
        "printf '%s\\n' '" .. json:gsub("'", "'\\''") .. "' | socat - UNIX-CONNECT:" .. self:socketPath(sound),
    })
end

function AudioEngine:startSound(sound)
    if sound.playerStarted or sound.starting then
        return
    end

    sound.starting = true
    sound.generation = (sound.generation or 0) + 1
    local myGeneration = sound.generation
    local socket = self:socketPath(sound)

    local created, createError = noctalia.mkdirAll(self.socketDir)
    if not created then
        sound.starting = false
        noctalia.notifyError("Ambient Sounds", "Could not create the audio control socket directory: " .. (createError or "unknown error"))
        return
    end

    if sound.generation ~= myGeneration then return end -- stopped/restarted meanwhile

    noctalia.removeFile(socket)
    if sound.generation ~= myGeneration then return end

    sound.playerStarted = true
    sound.starting = false
    local launched = noctalia.runAsync({
        "mpv", "--no-video", "--no-terminal", "--loop-file=inf",
        "--input-ipc-server=" .. socket, "--volume=" .. tostring(playerVolume(sound)),
        pluginRoot .. "/" .. sound.file,
    })
    if not launched then
        sound.playerStarted = false
        noctalia.notifyError("Ambient Sounds", "Could not start mpv for " .. sound.title .. ".")
    end
end

function AudioEngine:stopSound(sound)
    sound.generation = (sound.generation or 0) + 1  -- invalidates any in-flight startSound
    self:sendCommand(sound, { "quit" })
    noctalia.runAsync({ "pkill", "-f", "input-ipc-server=" .. self:socketPath(sound) })
    noctalia.removeFile(self:socketPath(sound))
    sound.playerStarted = false
    sound.starting = false
end

function AudioEngine:start()
    for _, sound in ipairs(self.sounds) do
        if sound.enabled then
            self:startSound(sound)
        end
    end
    self.running = true
end

function AudioEngine:stopAll()
    for _, sound in ipairs(self.sounds) do
        self:stopSound(sound)
    end
    self.running = false
end

function AudioEngine:toggleSound(id, enabled)
    for _, sound in ipairs(self.sounds) do
        if sound.id == id then
            sound.enabled = enabled == nil and not sound.enabled or enabled
            if self.running then
                if sound.enabled then
                    self:startSound(sound)
                else
                    self:stopSound(sound)
                end
            end
            return
        end
    end
end

function AudioEngine:setSoundVolume(id, value)
    for _, sound in ipairs(self.sounds) do
        if sound.id == id then
            sound.level = value
            if self.running then
                self:sendCommand(sound, { "set_property", "volume", playerVolume(sound) })
            end
            return
        end
    end
end

function AudioEngine:setAmplified(id, enabled)
    for _, sound in ipairs(self.sounds) do
        if sound.id == id then
            sound.amplified = enabled
            if self.running and sound.playerStarted then
                self:sendCommand(sound, { "set_property", "volume", playerVolume(sound) })
            end
            return
        end
    end
end

function AudioEngine:setMasterVolume(value)
    self.masterVolume = value
    noctalia.runAsync({ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", tostring(value) .. "%" })
end


function AudioEngine:refreshSystemVolume(onChanged)
    if self.volumeRequestInFlight then
        return
    end
    self.volumeRequestInFlight = true
    systemVolume(function(volume)
        self.volumeRequestInFlight = false
        if volume ~= self.masterVolume then
            self.masterVolume = volume
            onChanged()
        end
    end)
end

function AudioEngine:cleanup()
    self:stopAll()
    noctalia.runAsync({ "pkill", "-f", "input-ipc-server=" .. self.socketDir })
    noctalia.runAsync({ "rmdir", self.socketDir })
end

return AudioEngine
