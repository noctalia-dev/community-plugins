--!nonstrict
-- xbps backend: native Void Linux support. Void runs runit, not systemd —
-- no systemd units in any command here. The unprivileged check is a
-- dry-run against the synced repodata (`xbps-install -un`); the run syncs
-- itself (-S) under its own escalation. The plugin ignore list is applied
-- with xbps holds for the duration of the transaction (xbps-pkgdb -m
-- hold/unhold). Rollback is off in this first version: installing a
-- specific cached version needs --repository juggling that wants its own
-- testing round.

return function(env)
    local MAX_LISTED = env.MAX_LISTED

    local backend = {
        id = "xbps",
        caps = { bgUpdate = true, size = false, rollback = false, news = false, aur = false },
        checkTool = "xbps-install",
        missingToolKey = "err_no_xbps",
        nativeLabelKey = "source.system",
        escalateProgram = "/usr/bin/xbps-install",
        -- One "name-version: unpacking ..." line per package during the
        -- transaction (verified against the Void container fixture).
        progressPattern = "^[^ ]+: unpacking ",
        news = nil,
        polkitRuleName = "49-linux-updater-xbps.rules",
    }

    backend.polkitRule = [=[/* Installed by the linux-updater Noctalia plugin (one password per update
 * run instead of one per xbps call). Authentication is kept for ~5 minutes.
 * Scope: only pkexec launching xbps-install or xbps-pkgdb, only for an
 * active local session of a wheel member.
 * Remove: sudo rm /etc/polkit-1/rules.d/49-linux-updater-xbps.rules
 */
polkit.addRule(function(action, subject) {
    var prog = action.lookup("program");
    if (action.id == "org.freedesktop.policykit.exec" &&
        (prog == "/usr/bin/xbps-install" || prog == "/usr/bin/xbps-pkgdb") &&
        subject.active && subject.local &&
        subject.isInGroup("wheel")) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
]=]

    -- Dry-run lines: "name-1.2_3 update x86_64 <repo> <isize> <dsize>".
    -- Exit 0 with output when updates exist; exit 17 (or 0 with no lines)
    -- when there is nothing to do.
    backend.checkCommand = [[xbps-install -un 2>/dev/null; code=$?; if [ "$code" -eq 17 ]; then exit 0; fi; exit "$code"]]

    function backend.parseCheck(output, ignored, ignoredOut)
        local items = {}
        local n = 0
        for line in (output or ""):gmatch("[^\n]+") do
            local pkgver, action = line:match("^(%S+)%s+(%S+)")
            if pkgver ~= nil and (action == "update" or action == "install") then
                local name, version = pkgver:match("^(.+)%-([^%-]+)$")
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

    function backend.buildBackgroundCommand(ignored)
        local upgrade = "pkexec xbps-install -Suy"
        if #ignored == 0 then
            return upgrade
        end
        local holdCmds = {}
        local unholdCmds = {}
        for _, name in ipairs(ignored) do
            table.insert(holdCmds, "pkexec xbps-pkgdb -m hold " .. name)
            table.insert(unholdCmds, "pkexec xbps-pkgdb -m unhold " .. name)
        end
        return table.concat(holdCmds, "; ") .. "; " .. upgrade
            .. "; s=$?; " .. table.concat(unholdCmds, "; ") .. "; exit $s"
    end

    function backend.buildTerminalCommand(ignored)
        local upgrade = "sudo xbps-install -Su"
        if #ignored == 0 then
            return upgrade
        end
        local holdCmds = {}
        local unholdCmds = {}
        for _, name in ipairs(ignored) do
            table.insert(holdCmds, "sudo xbps-pkgdb -m hold " .. name)
            table.insert(unholdCmds, "sudo xbps-pkgdb -m unhold " .. name)
        end
        return table.concat(holdCmds, "; ") .. "; " .. upgrade
            .. "; s=$?; " .. table.concat(unholdCmds, "; ") .. "; exit $s"
    end

    backend.sizeCommand = nil

    -- runit, no systemd tooling: the kernel-modules check works everywhere.
    backend.rebootCommand = [[test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing]]

    return backend
end
