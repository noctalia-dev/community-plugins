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

type StatusFields = { [string]: any }
type SuccessCallback = () -> ()

local function new(host: Host, stateKey: string, bootedSystem: string, currentSystem: string)
    local running = false

    local function publish(state: string, fields: StatusFields?)
        local status: StatusFields = fields or {}
        status.state = state
        host.state.set(stateKey, status)
    end

    local function check(onSuccess: SuccessCallback?)
        if running then
            return
        end

        running = true

        local existing = host.state.get(stateKey)
        if existing == nil then
            publish("checking")
        else
            publish(existing.state, {
                bootedPath = existing.bootedPath,
                currentPath = existing.currentPath,
                message = existing.message,
                refreshing = true,
            })
        end

        local started = host.runAsync({
            "readlink",
            "-f",
            bootedSystem,
            currentSystem,
        }, function(result)
            running = false

            if result.timedOut then
                publish("error", {
                    message = "Timed out while resolving NixOS system generations",
                })
                return
            end

            if result.exitCode ~= 0 then
                local message = host.string.trim(result.stderr)
                if message == "" then
                    message = "Could not resolve NixOS system generations"
                end

                publish("error", { message = message })
                return
            end

            local paths: { string } = {}
            for path in result.stdout:gmatch("[^\r\n]+") do
                table.insert(paths, path)
            end

            if #paths ~= 2 then
                publish("error", {
                    message = "Expected booted and current NixOS system paths",
                })
                return
            end

            publish(paths[1] == paths[2] and "current" or "different", {
                bootedPath = paths[1],
                currentPath = paths[2],
            })

            if onSuccess ~= nil then
                onSuccess()
            end
        end, 5000)

        if not started then
            running = false
            publish("error", {
                message = "Could not start generation check",
            })
        end
    end

    return {
        check = check,
    }
end

return {
    new = new,
}
