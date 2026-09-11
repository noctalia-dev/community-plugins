--!nonstrict
-- Extra sources: cross-distro developer/desktop package managers that live
-- alongside any backend, the way the engine's Flatpak part does. Each one is
-- strictly opt-in (its own bool setting, default off) and silently skipped
-- when its tool is not installed.
--
-- Contract per entry (what the engine relies on):
--   key         — source id; also the `source` field on run-history items
--   tool        — binary gating the source (commandExists)
--   settingKey  — bool setting that enables it
--   labelKey    — translation key for the panel row / checking step
--   checkCommand — read-only pending-updates query, parsed by parseCheck.
--                  Spawned under LC_ALL=C: the parsers key off English words
--                  and fixed column layouts.
--   parseCheck(stdout, ignoredSet, ignoredOut) -> n, items
--                — same contract as a backend's parseCheck
--   buildUpdateCommand(quotedNames | nil) | nil
--                — the upgrade part appended to the update run; nil names =
--                  everything pending. nil command = check-only (pip: PEP 668
--                  makes a blind upgrade of site-packages a hazard, so its
--                  count is informational).
--   rollbackKind — "version" (reinstall the recorded old version through the
--                  manager itself) or "revert" (the manager restores its own
--                  previous state, no version needed — snap). nil = none.
--   buildRollbackCommand(item) | nil
--                — the rollback command for one run-history item, or nil when
--                  the item lacks what the command needs. The manager resolves
--                  its own dependencies; there is no run-mate resolution like
--                  the pacman cache path has.
--
-- Extras are excluded from the backend's rollback transaction and from the
-- installed-versions verification; their per-item rollback (where declared)
-- runs through the same detached runner as everything else.

return function(env)
    local MAX_LISTED = env.MAX_LISTED
    local trim = env.trim

    -- Names reach the command line (quoted) and the panel; anything outside
    -- this shape is dropped. @ and / cover npm scoped packages.
    local function usableName(name)
        return name:match("^[%w@/._+-]+$") ~= nil
    end

    local function newList()
        return { n = 0, items = {} }
    end

    local function push(list, name, from, to, ignored, ignoredOut)
        if not usableName(name) then
            return
        end
        if ignored[name] then
            table.insert(ignoredOut, { name = name, from = from or "", to = to or "", source = "plugin" })
        else
            list.n += 1
            if #list.items < MAX_LISTED then
                table.insert(list.items, { name = name, from = from or "", to = to or "" })
            end
        end
    end

    -- Versions reach rollback command lines (quoted); same shape the
    -- engine's own versionOk accepts.
    local function usableVersion(version)
        return tostring(version or ""):match("^[%w:._+~-]+$") ~= nil
    end

    -- Splits "name@version" at the LAST @, so npm scoped names
    -- ("@scope/pkg@1.2.3") keep their prefix.
    local function splitAtVersion(blob)
        local name, version = blob:match("^(.+)@([^@]*)$")
        if name == nil then
            return blob, ""
        end
        return name, version
    end

    local extras = {}

    -- ── npm (global packages) ────────────────────────────────────────────────
    -- `npm -g outdated` exits 1 when anything is outdated, so the exit code is
    -- normalized; parse failures then show up as an empty list, not an error.
    -- Parseable lines: <path>:<name@wanted>:<name@current>:<name@latest>
    table.insert(extras, {
        key = "npm",
        tool = "npm",
        settingKey = "npm_enabled",
        labelKey = "source.npm",
        checkCommand = [[LC_ALL=C npm -g outdated --parseable 2>/dev/null; exit 0]],
        parseCheck = function(output, ignored, ignoredOut)
            local list = newList()
            for line in (output or ""):gmatch("[^\n]+") do
                local fields = {}
                for field in (line .. ":"):gmatch("([^:]*):") do
                    table.insert(fields, field)
                end
                if #fields >= 4 then
                    local name, wanted = splitAtVersion(fields[2])
                    local _, current = splitAtVersion(fields[3])
                    if current == "MISSING" then
                        current = ""
                    end
                    push(list, name, current, wanted, ignored, ignoredOut)
                end
            end
            return list.n, list.items
        end,
        buildUpdateCommand = function(quotedNames)
            return "npm -g update" .. (quotedNames ~= nil and (" " .. table.concat(quotedNames, " ")) or "")
        end,
        rollbackKind = "version",
        -- The registry keeps every published version, so rolling back is a
        -- plain install of the recorded old one.
        buildRollbackCommand = function(item)
            local name = tostring(item.name or "")
            local from = tostring(item.from or "")
            if not usableName(name) or not usableVersion(from) then
                return nil
            end
            return "npm -g install " .. env.shellQuote(name .. "@" .. from)
        end,
    })

    -- ── cargo (cargo install binaries, via cargo-update) ─────────────────────
    -- Table rows: "name  v1.0.0  v1.1.0  Yes"; only Yes rows are pending.
    table.insert(extras, {
        key = "cargo",
        tool = "cargo-install-update",
        settingKey = "cargo_enabled",
        labelKey = "source.cargo",
        checkCommand = [[LC_ALL=C cargo install-update --list 2>/dev/null]],
        parseCheck = function(output, ignored, ignoredOut)
            local list = newList()
            for line in (output or ""):gmatch("[^\n]+") do
                local name, from, to = line:match("^(%S+)%s+v?(%S+)%s+v?(%S+)%s+Yes%s*$")
                if name ~= nil then
                    push(list, name, from, to, ignored, ignoredOut)
                end
            end
            return list.n, list.items
        end,
        buildUpdateCommand = function(quotedNames)
            if quotedNames ~= nil then
                return "cargo install-update " .. table.concat(quotedNames, " ")
            end
            return "cargo install-update -a"
        end,
        rollbackKind = "version",
        -- cargo install pins the requested version; --force replaces the
        -- newer binary. This rebuilds from source, so it can take a while.
        buildRollbackCommand = function(item)
            local name = tostring(item.name or "")
            local from = tostring(item.from or "")
            if not usableName(name) or not usableVersion(from) then
                return nil
            end
            return "cargo install --force --version " .. env.shellQuote(from) .. " " .. env.shellQuote(name)
        end,
    })

    -- ── pip (check-only) ─────────────────────────────────────────────────────
    -- PEP 668 marks distro Pythons externally managed, and blindly upgrading
    -- site-packages breaks environments — so pip's pending list is shown but
    -- never included in the update run.
    table.insert(extras, {
        key = "pip",
        tool = "pip",
        settingKey = "pip_enabled",
        labelKey = "source.pip",
        checkCommand = [[LC_ALL=C pip list --outdated 2>/dev/null]],
        parseCheck = function(output, ignored, ignoredOut)
            local list = newList()
            for line in (output or ""):gmatch("[^\n]+") do
                -- Two header lines: the column names and the dashes under them.
                if line:match("^Package%s") == nil and line:match("^%-%-") == nil then
                    local name, from, to = line:match("^(%S+)%s+(%S+)%s+(%S+)")
                    if name ~= nil then
                        push(list, name, from, to, ignored, ignoredOut)
                    end
                end
            end
            return list.n, list.items
        end,
        buildUpdateCommand = nil,
    })

    -- ── gem ──────────────────────────────────────────────────────────────────
    -- Lines: "name (1.0.0 < 1.2.0)".
    table.insert(extras, {
        key = "gem",
        tool = "gem",
        settingKey = "gem_enabled",
        labelKey = "source.gem",
        checkCommand = [[LC_ALL=C gem outdated 2>/dev/null]],
        parseCheck = function(output, ignored, ignoredOut)
            local list = newList()
            for line in (output or ""):gmatch("[^\n]+") do
                local name, from, to = line:match("^(%S+) %((%S+) < ([^%)]+)%)")
                if name ~= nil then
                    push(list, name, from, trim(to), ignored, ignoredOut)
                end
            end
            return list.n, list.items
        end,
        buildUpdateCommand = function(quotedNames)
            return "gem update" .. (quotedNames ~= nil and (" " .. table.concat(quotedNames, " ")) or "")
        end,
        rollbackKind = "version",
        -- gem update keeps the old version installed alongside the new one,
        -- so removing the new one usually suffices; the install afterwards
        -- covers a cleaned-up old version and no-ops when it is still there.
        buildRollbackCommand = function(item)
            local name = tostring(item.name or "")
            local from = tostring(item.from or "")
            local to = tostring(item.to or "")
            if not usableName(name) or not usableVersion(from) or not usableVersion(to) then
                return nil
            end
            local quotedName = env.shellQuote(name)
            return "gem uninstall -x -I " .. quotedName .. " -v " .. env.shellQuote(to)
                .. " >/dev/null 2>&1; gem install " .. quotedName .. " -v " .. env.shellQuote(from)
        end,
    })

    -- ── snap ─────────────────────────────────────────────────────────────────
    -- `snap refresh --list` needs no root (snapd socket); the header row is
    -- skipped, and only the new version is reported. The refresh itself
    -- escalates through snapd's own polkit policies, no pkexec of ours.
    table.insert(extras, {
        key = "snap",
        tool = "snap",
        settingKey = "snap_enabled",
        labelKey = "source.snap",
        checkCommand = [[LC_ALL=C snap refresh --list 2>/dev/null]],
        parseCheck = function(output, ignored, ignoredOut)
            local list = newList()
            local first = true
            for line in (output or ""):gmatch("[^\n]+") do
                if first then
                    first = false
                elseif line:match("^All snaps up to date") == nil then
                    local name, to = line:match("^(%S+)%s+(%S+)")
                    if name ~= nil then
                        push(list, name, "", to, ignored, ignoredOut)
                    end
                end
            end
            return list.n, list.items
        end,
        buildUpdateCommand = function(quotedNames)
            return "snap refresh" .. (quotedNames ~= nil and (" " .. table.concat(quotedNames, " ")) or "")
        end,
        rollbackKind = "revert",
        -- snapd keeps the previous revision locally; revert needs no version
        -- and fails honestly when there is nothing to revert to.
        buildRollbackCommand = function(item)
            local name = tostring(item.name or "")
            if not usableName(name) then
                return nil
            end
            return "snap revert " .. env.shellQuote(name)
        end,
    })

    -- ── brew ─────────────────────────────────────────────────────────────────
    -- `--quiet` prints bare names; brew does not report a usable version pair.
    table.insert(extras, {
        key = "brew",
        tool = "brew",
        settingKey = "brew_enabled",
        labelKey = "source.brew",
        checkCommand = [[LC_ALL=C brew outdated --quiet 2>/dev/null]],
        parseCheck = function(output, ignored, ignoredOut)
            local list = newList()
            for line in (output or ""):gmatch("[^\n]+") do
                local name = trim(line)
                if name ~= "" then
                    push(list, name, "", "", ignored, ignoredOut)
                end
            end
            return list.n, list.items
        end,
        buildUpdateCommand = function(quotedNames)
            return "brew upgrade" .. (quotedNames ~= nil and (" " .. table.concat(quotedNames, " ")) or "")
        end,
    })

    return extras
end
