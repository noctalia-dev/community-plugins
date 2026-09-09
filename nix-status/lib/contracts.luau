--!strict

export type InputChangeKind = "added" | "removed" | "updated"

export type InputChange = {
    name: string,
    kind: InputChangeKind,
    oldRev: string,
    newRev: string,
    oldDate: string,
    newDate: string,
}

export type UpdateStatus =
    { state: "idle", message: nil? }
    | { state: "checking", message: nil? }
    | { state: "unconfigured", message: string }
    | { state: "current", changedInputs: { InputChange } }
    | { state: "updates", changedInputs: { InputChange } }
    | { state: "error", message: string }

export type GenerationState = "checking" | "current" | "different" | "error"

export type GenerationStatus = {
    state: GenerationState,
    bootedPath: string?,
    currentPath: string?,
    message: string?,
    refreshing: boolean?,
}

export type ClosureChange = "increase" | "decrease"

export type ClosureLine = {
    text: string?,
    prefix: string?,
    amount: string?,
    change: ClosureChange?,
}

export type ClosureDiffStatus =
    { state: "idle" }
    | { state: "running" }
    | { state: "ready", output: string, lines: { ClosureLine }, truncated: boolean? }
    | { state: "error", message: string }

export type SystemTargetStatus =
    { state: "disabled", message: string? }
    | { state: "checking" }
    | { state: "current", currentPath: string, targetPath: string }
    | { state: "different", currentPath: string, targetPath: string }
    | { state: "error", message: string }

local state = {
    updateStatus = "status",
    generationStatus = "generation-status",
    closureDiffStatus = "closure-diff-status",
    systemTargetStatus = "system-target-status",
}

local request = {
    update = "check-request",
    generationRefresh = "generation-refresh-request",
    closureDiff = "closure-diff-request",
    systemTargetRefresh = "system-target-refresh-request",
}

return {
    state = state,
    request = request,
}
