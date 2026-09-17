# Service state transitions

This document describes the behavior currently implemented by `service.luau`. It is a characterization baseline for tests and future refactoring, not a proposed redesign.

## State and request channels

The service communicates with the panel and widget through Noctalia's in-memory state store.

| Channel | Direction | Purpose |
| --- | --- | --- |
| `generation-status` | Service → UI | Status of the booted-versus-current generation check |
| `closure-diff-status` | Service → UI | Status and result of a startup or requested closure comparison |
| `status` | Service → UI | Status and result of a mutating flake input update |
| `system-target-status` | Service → UI | Status of the evaluated-versus-active configured system check |
| `generation-refresh-request` | Panel → service | Incrementing counter requesting a generation refresh |
| `closure-diff-request` | Panel → service | Incrementing counter requesting a closure comparison |
| `check-request` | Panel → service | Incrementing counter requesting a flake input update |
| `system-target-refresh-request` | Panel → service | Incrementing counter requesting a configured-system refresh |

Request values have no meaning beyond changing the stored value and triggering a watcher. Each workflow has a separate in-memory running flag; a user request received while its workflow is running is ignored. The configured-system workflow makes one deliberate exception for configuration changes: it lets the old command finish, discards its stale result, and reruns with the new configuration when possible.

## Generation status

### Shapes currently published

```luau
{ state = "checking" }

{
    state = "current" | "different",
    bootedPath = string,
    currentPath = string,
}

{
    state = "current" | "different" | "error" | "checking",
    bootedPath = string?,
    currentPath = string?,
    message = string?,
    refreshing = true,
}

{
    state = "error",
    message = string,
}
```

The `refreshing` shape preserves selected fields from the previous status while a new check is running. Once the check completes, the newly published result does not contain `refreshing`.

### Triggers

A generation check starts:

- when the service loads;
- on every service `update()` interval, currently every 60 seconds;
- when `generation-refresh-request` changes;
- after a successful closure comparison.

### Transition table

| Starting condition | Event/result | Published status | Other effects |
| --- | --- | --- | --- |
| No status exists | Check starts | `checking` | Sets the generation running guard |
| A previous status exists | Check starts | Previous state and selected fields, plus `refreshing = true` | Sets the generation running guard |
| Any status; check running | Another trigger arrives | No change | Trigger is ignored |
| Check running | `readlink` times out | `error` with timeout message | Releases the running guard |
| Check running | `readlink` exits non-zero | `error` with trimmed stderr or fallback message | Releases the running guard |
| Check running | Output contains other than exactly two non-empty lines | `error` with expected-paths message | Releases the running guard |
| Check running | Both resolved paths are equal | `current` with both paths | Releases the running guard |
| Check running | Resolved paths differ | `different` with both paths | Releases the running guard |
| Starting command fails | `runAsync` returns `false` | `error` with start-failure message | Releases the running guard |

### Reload behavior

Generation state is not explicitly reset on service load. The initial check does the following:

- if no previous status exists, it publishes `checking`;
- if a previous status exists, it preserves its state and selected fields while adding `refreshing = true`.

The generation running guard is process-local and therefore starts as `false` after reload.

## Closure-diff status

### Shapes currently published

```luau
{ state = "idle" }
{ state = "running" }

{
    state = "ready",
    output = string,
    lines = { any },
    truncated = boolean?,
}

{
    state = "error",
    message = string,
}
```

`lines` contains the structured output produced by `lib/closure_diff.luau`.

### Triggers

A closure comparison starts:

- when `closure-diff-request` changes;
- after the initial generation check succeeds on service load.

### Transition table

| Starting condition | Event/result | Published status | Other effects |
| --- | --- | --- | --- |
| Not running | Request arrives | `running` | Sets the closure running guard |
| Running | Another request arrives | No change | Request is ignored |
| Running | Command times out | `error` with timeout message | Releases the running guard |
| Running | Command exits non-zero | `error` using cleaned stderr, then stdout, then fallback message | Releases the running guard |
| Running | Manually requested command succeeds | `ready` with cleaned output, parsed lines, and truncation flag | Releases the running guard and requests a generation check directly |
| Running | Automatic startup command succeeds | `ready` with cleaned output, parsed lines, and truncation flag | Releases the running guard; does not repeat the generation check |
| Starting command fails | `runAsync` returns `false` | `error` with start-failure message | Releases the running guard |

A successful manually requested comparison calls the generation-check function directly. If a generation check is already running, that follow-up check is ignored. The automatic startup comparison does not repeat the generation check that triggered it.

### Reload behavior

On service load, every retained closure status is replaced with `idle` so paths or output from before a switch or reboot are not shown as current. The service then:

1. runs the initial generation check;
2. starts a fresh closure comparison if that check succeeds;
3. leaves closure status at `idle` if the generation check fails.

The closure running guard is process-local and therefore starts as `false` after reload.

## Flake-update status

Despite the historical `check` naming in request and function identifiers, this workflow runs a real, mutating `nix flake update` against the configured flake.

### Shapes currently published

```luau
{ state = "idle", message = nil }
{ state = "checking", message = nil }
{ state = "unconfigured", message = string }
{ state = "current", changedInputs = {} }

{
    state = "updates",
    changedInputs = { any },
}

{
    state = "error",
    message = string,
}
```

`changedInputs` contains entries produced by `lib/nix.luau`.

### Trigger

A flake update starts when `check-request` changes, provided a directory is configured. Missing configuration publishes `unconfigured` and never starts a command. Every successful, non-stale update completion also requests an immediate configured-system refresh; the configured-system workflow decides whether it is enabled or already running.

Configuration changes are applied to the existing workflow, without re-registering watchers. When idle, a changed directory clears the previous result to `idle` (or `unconfigured` if cleared). During an update, the original command target and running guard are preserved. Once that command finishes, its result is discarded if configuration changed, and the status becomes `idle` or `unconfigured` for the new configuration. This also applies if the directory changes away and back while running. Setting the same directory has no effect.

### Transition table

| Starting condition | Event/result | Published status | Other effects |
| --- | --- | --- | --- |
| Not running, configured | Request arrives | `checking` | Sets the update running guard and starts a mutating update |
| Not running, unconfigured | Request arrives | `unconfigured` with settings guidance | No command starts |
| Running | Another request arrives | No change | Request is ignored |
| Running | Command times out | `error` with timeout message | Releases the running guard |
| Running | Command exits non-zero | `error` using trimmed stderr, then stdout, then fallback message | Releases the running guard |
| Running | Command succeeds with no parsed changes | `current` with an empty `changedInputs` array | Releases the running guard |
| Running | Command succeeds with parsed changes | `updates` with parsed `changedInputs` | Releases the running guard |
| Starting command fails | `runAsync` returns `false` | `error` with start-failure message | Releases the running guard |

### Reload behavior

On service load:

- with no configured directory, any retained status becomes `unconfigured`;
- with a configured directory, a missing, `unconfigured`, or retained `checking` status becomes `idle`;
- with a configured directory, `current`, `updates`, and `error` statuses are preserved.

The update running guard is process-local and therefore starts as `false` after reload.

## Configured-system status

This workflow compares the evaluated `nixosConfigurations.<name>.config.system.build.toplevel.outPath` with the resolved `/run/current-system` path. It reports whether a switch would select a different store path; it does not build the target or claim that switching will succeed.

### Shapes currently published

```luau
{ state = "disabled", message = string? }
{ state = "checking" }

{
    state = "current" | "different",
    currentPath = string,
    targetPath = string,
}

{
    state = "error",
    message = string,
}
```

An empty configuration name disables this workflow. An invalid name publishes `error`. A configured name without a flake directory publishes `disabled` with configuration guidance.

### Triggers and cadence

A configured-system check starts:

- immediately when the service loads with valid configuration;
- when `system-target-refresh-request` changes;
- immediately after its flake directory or configuration name changes;
- after a successful, non-stale flake input update;
- from the service's one-minute `update()` callback once 15 minutes have elapsed since the previous check started.

The periodic cadence uses Noctalia's millisecond clock and does not create a second Noctalia timer.

### Command sequence and transitions

1. Publish `checking` and run `readlink -f /run/current-system` with a five-second timeout.
2. Validate that it succeeded with exactly one `/nix/store/...` path. Timeout, command failure, malformed output, or failure to start publishes `error`, releases the running guard, and does not start evaluation.
3. Run `nix eval --raw --no-update-lock-file <flake>#nixosConfigurations.<name>.config.system.build.toplevel.outPath` with a 60-second timeout. The lock-file flag makes this automatic check observational rather than allowing it to update `flake.lock`.
4. Validate exactly one evaluated `/nix/store/...` path. Timeout, command failure, malformed output, or failure to start publishes `error` and releases the running guard.
5. Equal paths publish `current`; unequal paths publish `different`.

Manual and periodic triggers received while either command is running are ignored rather than queued. If configuration changes while either command is running, its completion is treated as stale: no old result is published, and a new check starts immediately when the new configuration is valid. Reapplying unchanged configuration has no effect.

### Reload behavior

Configured-system status is rebuilt on service load. Valid configuration publishes `checking` and starts immediately; disabled or invalid configuration publishes its available state without running commands. The running guard, last-start time, configuration version, and pending configuration rerun are process-local.

## Current invariants to preserve

Unless deliberately changed and documented, future changes should preserve these behaviors:

1. At most one command per workflow runs at a time.
2. The four workflows do not block one another.
3. Every callback path and every failure-to-start path releases its workflow's running guard.
4. A generation refresh retains the previous visible result while indicating `refreshing`.
5. Closure, update, and configured-system workflows replace their previous visible result with a running state when applicable.
6. Completed update results survive service reloads when a directory is configured.
7. Every retained closure result is cleared on service reload and rebuilt after a successful initial generation check.
8. Interrupted update operations reset to idle after service reloads, or unconfigured if no directory is configured.
9. A successful manually requested closure comparison triggers a generation refresh; the automatic startup comparison does not.
10. Error output preference remains workflow-specific as described above.
11. Flake updates remain explicitly user-triggered and mutating.
12. Configured-system evaluation remains automatic but read-only with respect to `flake.lock`.
13. User refresh requests are discarded while their workflow is running; only a configured-system configuration change forces a later rerun.
14. Stale configured-system and flake-update results are not published after their relevant configuration changes.

## Characterization coverage

The generation, closure-comparison, flake-update, and configured-system cases below are covered by the standalone test suite.

### Generation

- Initial load with no state publishes `checking` and starts `readlink` with the expected paths.
- Refresh with an existing result preserves that result and adds `refreshing`.
- Equal and different paths publish `current` and `different`, respectively.
- Timeout, non-zero exit, malformed output, and failure to start publish the documented errors.
- A duplicate trigger does not start a second command.
- A completed command releases the guard and allows another command.

### Closure comparison

- Request publishes `running` and starts the expected `nix store diff-closures` command.
- Manual success publishes parsed output and triggers a generation check.
- Automatic startup success publishes parsed output without repeating the generation check.
- Timeout, non-zero exit with each output fallback, and failure to start publish the documented errors.
- Truncation is retained in the ready status.
- Duplicate requests are ignored.
- Reload clears every retained closure state and rebuilds it after a successful initial generation check.
- A failed initial generation check leaves closure status idle.

### Flake update

- Request publishes `checking` and starts the expected mutating command.
- Success with zero changes publishes `current`.
- Success with changes publishes `updates` and the parsed entries.
- Timeout, non-zero exit with each output fallback, and failure to start publish the documented errors.
- Duplicate requests are ignored.
- Configuration changes preserve an active command but discard its eventual stale result.
- Successful non-stale updates request a configured-system refresh.
- Reload resets `checking` but preserves completed states.

### Configured system

- Disabled, invalid, and missing-flake configurations publish the documented state without running commands.
- A valid configuration resolves the current system before evaluating the target.
- Evaluation uses `--no-update-lock-file`.
- Current-system timeout, command failure, malformed output, and failure to start publish errors without launching evaluation and release the guard for retry.
- Evaluation timeout, command failure, malformed output, and failure to start publish the documented errors.
- Equal and different paths publish `current` and `different`, respectively.
- Manual requests are discarded during both command stages.
- The periodic tick waits 15 minutes while manual refresh is immediate.
- Configuration changes during either command stage discard the stale result and rerun with the new configuration.
