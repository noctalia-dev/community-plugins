--!strict

type CommandResult = {
    exitCode: number,
    stdout: string,
    stderr: string,
    timedOut: boolean,
}

type Host = {
    state: {
        set: (key: string, value: any) -> (),
    },
    runAsync: (argv: { string }, callback: (result: CommandResult) -> (), timeoutMs: number) -> boolean,
    nowMs: () -> number,
}

type TargetConfig =
    { state: "disabled" }
    | { state: "configured", configuration: string }
    | { state: "invalid", message: string }

type CurrentResolution =
    { state: "ready", path: string }
    | { state: "error", message: string }

type Model = {
    resolveCurrent: (currentResult: CommandResult) -> CurrentResolution,
    resolveTarget: (currentPath: string, targetResult: CommandResult) -> any,
}

local CURRENT_TIMEOUT_MS = 5000
local EVALUATION_TIMEOUT_MS = 60000
local REFRESH_INTERVAL_MS = 15 * 60 * 1000

local function sameConfig(left: TargetConfig, right: TargetConfig): boolean
    if left.state ~= right.state then
        return false
    elseif left.state == "configured" and right.state == "configured" then
        return left.configuration == right.configuration
    elseif left.state == "invalid" and right.state == "invalid" then
        return left.message == right.message
    end
    return true
end

local function new(
    host: Host,
    stateKey: string,
    currentSystem: string,
    model: Model,
    flakeDir: string?,
    targetConfig: TargetConfig
)
    local running = false
    local configVersion = 0
    local rerunAfterConfigChange = false
    local lastStartedAtMs: number? = nil

    local function ready(): boolean
        return flakeDir ~= nil and flakeDir ~= "" and targetConfig.state == "configured"
    end

    local function publishAvailable()
        if targetConfig.state == "invalid" then
            host.state.set(stateKey, {
                state = "error",
                message = targetConfig.message,
            })
        elseif targetConfig.state == "disabled" then
            host.state.set(stateKey, { state = "disabled" })
        elseif flakeDir == nil or flakeDir == "" then
            host.state.set(stateKey, {
                state = "disabled",
                message = "Configure a flake directory to monitor the evaluated NixOS system.",
            })
        else
            host.state.set(stateKey, { state = "checking" })
        end
    end

    local refresh

    local function settleChangedConfiguration()
        running = false
        local rerun = rerunAfterConfigChange
        rerunAfterConfigChange = false
        publishAvailable()
        if rerun and ready() then
            refresh()
        end
    end

    function refresh()
        if running then
            return
        end
        if not ready() then
            publishAvailable()
            return
        end

        local targetDir = flakeDir :: string
        local configuration = (targetConfig :: { state: "configured", configuration: string }).configuration
        local startedVersion = configVersion
        running = true
        lastStartedAtMs = host.nowMs()
        host.state.set(stateKey, { state = "checking" })

        local currentStarted = host.runAsync({
            "readlink",
            "-f",
            currentSystem,
        }, function(currentResult)
            if startedVersion ~= configVersion then
                settleChangedConfiguration()
                return
            end

            local current = model.resolveCurrent(currentResult)
            if current.state == "error" then
                running = false
                host.state.set(stateKey, current)
                return
            end

            local installable = targetDir
                .. "#nixosConfigurations."
                .. configuration
                .. ".config.system.build.toplevel.outPath"
            local evaluationStarted = host.runAsync({
                "nix",
                "eval",
                "--raw",
                "--no-update-lock-file",
                installable,
            }, function(targetResult)
                if startedVersion ~= configVersion then
                    settleChangedConfiguration()
                    return
                end

                running = false
                host.state.set(stateKey, model.resolveTarget(current.path, targetResult))
            end, EVALUATION_TIMEOUT_MS)

            if not evaluationStarted then
                running = false
                host.state.set(stateKey, {
                    state = "error",
                    message = "Could not start configured NixOS system evaluation",
                })
            end
        end, CURRENT_TIMEOUT_MS)

        if not currentStarted then
            running = false
            host.state.set(stateKey, {
                state = "error",
                message = "Could not start current NixOS system resolution",
            })
        end
    end

    local function initialize()
        publishAvailable()
        if ready() then
            refresh()
        end
    end

    local function configure(nextFlakeDir: string?, nextTargetConfig: TargetConfig)
        if nextFlakeDir == flakeDir and sameConfig(nextTargetConfig, targetConfig) then
            return
        end

        flakeDir = nextFlakeDir
        targetConfig = nextTargetConfig
        configVersion += 1
        lastStartedAtMs = nil
        if running then
            rerunAfterConfigChange = true
        else
            publishAvailable()
            if ready() then
                refresh()
            end
        end
    end

    local function tick()
        if not ready() or running then
            return
        end
        if lastStartedAtMs == nil or host.nowMs() - lastStartedAtMs >= REFRESH_INTERVAL_MS then
            refresh()
        end
    end

    return {
        initialize = initialize,
        configure = configure,
        refresh = refresh,
        tick = tick,
    }
end

return {
    new = new,
}
