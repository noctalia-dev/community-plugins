--!strict

type CommandResult = {
    exitCode: number,
    stdout: string,
    stderr: string,
    timedOut: boolean,
}

export type Status =
    { state: "current", currentPath: string, targetPath: string }
    | { state: "different", currentPath: string, targetPath: string }
    | { state: "error", message: string }

export type CurrentResolution =
    { state: "ready", path: string }
    | { state: "error", message: string }

local function trim(value: string): string
    return value:match("^%s*(.-)%s*$") or ""
end

local function commandError(result: CommandResult, fallback: string): string
    local message = trim(result.stderr)
    if message == "" then
        message = trim(result.stdout)
    end
    return message ~= "" and message or fallback
end

local function storePath(output: string): string?
    local path = trim(output)
    if path == "" or path:find("[\r\n]") ~= nil then
        return nil
    end
    if path:match("^/nix/store/[^/]+$") == nil then
        return nil
    end
    return path
end

local function resolveCurrent(currentResult: CommandResult): CurrentResolution
    if currentResult.timedOut then
        return {
            state = "error",
            message = "Timed out while resolving the current NixOS system",
        }
    end
    if currentResult.exitCode ~= 0 then
        return {
            state = "error",
            message = commandError(currentResult, "Could not resolve the current NixOS system"),
        }
    end

    local currentPath = storePath(currentResult.stdout)
    if currentPath == nil then
        return {
            state = "error",
            message = "Current NixOS system did not resolve to one Nix store path",
        }
    end

    return {
        state = "ready",
        path = currentPath,
    }
end

local function resolveTarget(currentPath: string, targetResult: CommandResult): Status
    if targetResult.timedOut then
        return {
            state = "error",
            message = "Timed out while evaluating the configured NixOS system",
        }
    end
    if targetResult.exitCode ~= 0 then
        return {
            state = "error",
            message = commandError(targetResult, "Could not evaluate the configured NixOS system"),
        }
    end

    local targetPath = storePath(targetResult.stdout)
    if targetPath == nil then
        return {
            state = "error",
            message = "Configured NixOS system did not evaluate to one Nix store path",
        }
    end

    if currentPath == targetPath then
        return {
            state = "current",
            currentPath = currentPath,
            targetPath = targetPath,
        }
    end

    return {
        state = "different",
        currentPath = currentPath,
        targetPath = targetPath,
    }
end

local function resolve(currentResult: CommandResult, targetResult: CommandResult): Status
    local current = resolveCurrent(currentResult)
    if current.state == "error" then
        return current
    end
    return resolveTarget(current.path, targetResult)
end

return {
    resolve = resolve,
    resolveCurrent = resolveCurrent,
    resolveTarget = resolveTarget,
}
