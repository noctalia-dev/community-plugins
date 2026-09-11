--!nonstrict
-- PackageKit backend: the generic path for distros whose native manager
-- PackageKit abstracts (Fedora/dnf, Debian/Ubuntu/apt, openSUSE/zypper).
-- `pkcon` output is identical across them (verified against fixtures/ from
-- Fedora 41 and Ubuntu 24.04 containers), so one parser covers all three
-- families. Escalation is PackageKit's own polkit policies — no pkexec and
-- no keep-authorization rule of ours; on most desktop distros an active
-- session updates with one prompt or none.
--
-- Capability notes: no rollback (PackageKit has no transaction undo), no
-- distro news feed, no AUR-like layer, no download-size estimate (pkcon
-- does not expose it cheaply). The check output has no old version either,
-- so items carry from="" — the UI already tolerates that.

return function(env)
    local MAX_LISTED = env.MAX_LISTED

    local backend = {
        id = "packagekit",
        caps = { bgUpdate = true, size = false, rollback = false, news = false, aur = false },
        checkTool = "pkcon",
        missingToolKey = "err_no_pkcon",
        nativeLabelKey = "source.system",
        -- "Package:" lines appear once per package in the download phase and
        -- once in the install phase, so the counter runs at up to 2x; the
        -- engine clamps the bar at 100%, which makes this harmless.
        progressPattern = "^Package:",
        news = nil,
        polkitRuleName = nil,
        polkitRule = nil,
    }

    -- pkcon exits 5 when there is nothing to report; normalize to 0 so only
    -- a genuine failure reaches the engine. LC_ALL=C: pkcon localizes the
    -- severity words the parser keys on ("Security", "Bug fix", ...).
    backend.checkCommand = [[LC_ALL=C pkcon -p get-updates 2>/dev/null; code=$?; if [ "$code" -eq 5 ]; then exit 0; fi; exit "$code"]]

    -- Result lines look like:
    --   Security     curl-8.9.1-4.fc41.x86_64 (updates)
    --   Bug fix      libcurl4t64-8.5.0-2ubuntu10.11.amd64 (ubuntu-noble-updates-main)
    -- The name/version split is at the first "-<digit>" boundary, which
    -- holds for both rpm (epoch "1:" starts with a digit) and deb versions.
    local SEVERITIES = {
        ["Security"] = true, ["Bug fix"] = true, ["Enhancement"] = true,
        ["Normal"] = true, ["Important"] = true, ["Critical"] = true,
        ["Low"] = true, ["Trivial"] = true, ["Blocked"] = true,
    }

    function backend.parseCheck(output, ignored, ignoredOut)
        local items = {}
        local n = 0
        for line in (output or ""):gmatch("[^\n]+") do
            local severity, rest = line:match("^(%a[%a ]-)%s%s+(%S.*)$")
            if severity ~= nil and SEVERITIES[severity] then
                local pkgid = rest:match("^(%S+)")
                -- strip the trailing ".arch" (underscore included: x86_64)
                local nameVer = pkgid:gsub("%.[%w_]+$", "")
                local name, version = nameVer:match("^(.-)%-(%d.*)$")
                if name ~= nil and name ~= "" then
                    if ignored[name] then
                        table.insert(ignoredOut, { name = name, from = "", to = version, source = "plugin" })
                    else
                        n += 1
                        if #items < MAX_LISTED then
                            table.insert(items, { name = name, from = "", to = version })
                        end
                    end
                end
            end
        end
        return n, items
    end

    -- PackageKit cannot exclude packages per transaction, but `pkcon
    -- update` accepts explicit names — so with a plugin ignore list the
    -- engine passes the pending-minus-ignored snapshot (pendingNames) and
    -- the update names exactly those. nil = no filter needed (update all),
    -- {} = everything pending is ignored (refresh only). Dependencies of an
    -- updated package can still pull an ignored one in — the same
    -- best-effort semantics as --exclude elsewhere.
    backend.ignoreByExplicitList = true

    function backend.buildBackgroundCommand(_ignored, pendingNames)
        local base = "pkcon -y --plain refresh"
        if pendingNames == nil then
            return base .. " && pkcon -y --plain update"
        end
        if #pendingNames == 0 then
            return base
        end
        return base .. " && pkcon -y --plain update " .. table.concat(pendingNames, " ")
    end

    function backend.buildTerminalCommand(_ignored, pendingNames)
        local base = "pkcon refresh"
        if pendingNames == nil then
            return base .. " && pkcon update"
        end
        if #pendingNames == 0 then
            return base
        end
        return base .. " && pkcon update " .. table.concat(pendingNames, " ")
    end

    backend.sizeCommand = nil

    -- Kernel-flavour agnostic and works on every systemd-era distro; native
    -- backends can refine (needs-restarting, /var/run/reboot-required).
    backend.rebootCommand = [[test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing]]

    return backend
end
