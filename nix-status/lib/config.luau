--!strict

type Host = {
    getConfig: (key: string) -> any,
    expandPath: (path: string) -> string,
}

export type SystemTargetConfig =
    { state: "disabled" }
    | { state: "configured", configuration: string }
    | { state: "invalid", message: string }

export type Config =
    { state: "configured", flakeDir: string, systemTarget: SystemTargetConfig }
    | { state: "unconfigured", message: string, systemTarget: SystemTargetConfig }

local function loadSystemTarget(value: any): SystemTargetConfig
    if value == nil then
        return { state = "disabled" }
    end
    if type(value) ~= "string" then
        return {
            state = "invalid",
            message = "NixOS configuration name must be a string.",
        }
    end

    local name = value:match("^%s*(.-)%s*$") or ""
    if name == "" then
        return { state = "disabled" }
    end
    if name:match("^[%a_][%w_-]*$") == nil then
        return {
            state = "invalid",
            message = "NixOS configuration name must start with a letter or underscore and contain only letters, numbers, underscores, or hyphens.",
        }
    end

    return {
        state = "configured",
        configuration = name,
    }
end

local function load(host: Host): Config
    local systemTarget = loadSystemTarget(host.getConfig("nixos_configuration"))
    local value = host.getConfig("flake_dir")
    if type(value) ~= "string" then
        return {
            state = "unconfigured",
            message = "Configure a flake directory in plugin settings to enable input updates.",
            systemTarget = systemTarget,
        }
    end

    local path = value:match("^%s*(.-)%s*$") or ""
    if path == "" then
        return {
            state = "unconfigured",
            message = "Configure a flake directory in plugin settings to enable input updates.",
            systemTarget = systemTarget,
        }
    end

    return {
        state = "configured",
        flakeDir = host.expandPath(path),
        systemTarget = systemTarget,
    }
end

return {
    load = load,
}
