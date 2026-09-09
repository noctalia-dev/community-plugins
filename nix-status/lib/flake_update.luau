--!strict

type CommandResult = {
    exitCode: number,
    stdout: string,
    stderr: string,
    timedOut: boolean,
}

type Host = {
    state: {
        get: (key: string) -> any,
        set: (key: string, value: any) -> (),
    },
    string: {
        trim: (value: string) -> string,
    },
    runAsync: (argv: { string }, callback: (result: CommandResult) -> (), timeoutMs: number) -> boolean,
}

type Parser = {
    parseUpdateOutput: (output: string) -> { any },
}

type SuccessCallback = () -> ()

local FLAKE_UPDATE_TIMEOUT_MS = 60000

local function new(host: Host, stateKey: string, flakeDir: string?, parser: Parser)
    local running = false
    local configVersion = 0

    local function publish(state: string, message: string?)
        host.state.set(stateKey, {
            state = state,
            message = message,
        })
    end

    local function publishAvailable()
        if flakeDir == nil or flakeDir == "" then
            publish("unconfigured", "Configure a flake directory in plugin settings to enable input updates.")
        else
            publish("idle", nil)
        end
    end

    local function initialize()
        local existing = host.state.get(stateKey)
        if flakeDir == nil or flakeDir == "" or existing == nil
            or existing.state == "checking" or existing.state == "unconfigured" then
            publishAvailable()
        end
    end

    local function configure(path: string?)
        if path == flakeDir then
            return
        end
        flakeDir = path
        configVersion += 1
        -- Keep checking visible until the old command finishes; never allow overlapping updates.
        if not running then
            publishAvailable()
        end
    end

    local function update(onSuccess: SuccessCallback?)
        if running then
            return
        end

        local target = flakeDir
        if target == nil or target == "" then
            publishAvailable()
            return
        end

        local startedVersion = configVersion
        running = true
        publish("checking", nil)

        local started = host.runAsync({
            "nix",
            "flake",
            "update",
            "--flake",
            target,
        }, function(result)
            running = false

            if startedVersion ~= configVersion then
                publishAvailable()
                return
            end

            if result.timedOut then
                publish("error", "Nix flake update timed out")
                return
            end

            if result.exitCode ~= 0 then
                local message = host.string.trim(result.stderr)
                if message == "" then
                    message = host.string.trim(result.stdout)
                end
                if message == "" then
                    message = "Nix flake update failed"
                end

                publish("error", message)
                return
            end

            local output = result.stdout .. "\n" .. result.stderr
            local changedInputs = parser.parseUpdateOutput(output)
            host.state.set(stateKey, {
                state = #changedInputs == 0 and "current" or "updates",
                changedInputs = changedInputs,
            })
            if onSuccess ~= nil then
                onSuccess()
            end
        end, FLAKE_UPDATE_TIMEOUT_MS)

        if not started then
            running = false
            publish("error", "Could not start nix flake update")
        end
    end

    return {
        initialize = initialize,
        configure = configure,
        update = update,
    }
end

return {
    new = new,
}
