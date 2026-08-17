--!nonstrict
-- zypper backend: native openSUSE support. Tumbleweed's correct upgrade is
-- `dup` (full distribution upgrade), Leap's is `up` — decided once from
-- os-release. The unprivileged check reads the repo metadata the system's
-- own refresh services keep current (zypper's autorefresh / PackageKit),
-- like the apt backend does; the run refreshes under its own escalation.
--
-- The plugin ignore list is applied with package locks for the duration of
-- the transaction (zypper addlock/removelock). Rollback is off: the right
-- tool on openSUSE is snapper (btrfs snapshots, installed by default), and
-- zypper's package cache is disabled out of the box (keeppackages=0).

return function(env)
    local MAX_LISTED = env.MAX_LISTED
    local trim = env.trim
    local osRelease = env.osRelease or ""

    local tumbleweed = osRelease:find("tumbleweed", 1, true) ~= nil
        or osRelease:find("Tumbleweed", 1, true) ~= nil
    local upgradeVerb = tumbleweed and "dup" or "up"

    local backend = {
        id = "zypper",
        caps = { bgUpdate = true, size = false, rollback = false, news = false, aur = false },
        checkTool = "zypper",
        missingToolKey = "err_no_zypper",
        nativeLabelKey = "source.system",
        escalateProgram = "/usr/bin/zypper",
        -- One "Installing: name-version ..." line per package during the
        -- commit phase (both up and dup).
        progressPattern = "^Installing: ",
        news = nil,
        polkitRuleName = "49-linux-updater-zypper.rules",
        systemIgnoreLabelKey = "ignored_tag_lock",
    }

    backend.polkitRule = [=[/* Installed by the linux-updater Noctalia plugin (one password per update
 * run instead of one per zypper call). Authentication is kept for
 * ~5 minutes, like sudo's timestamp. Scope: only pkexec launching zypper,
 * only for an active local session of a wheel member.
 * Remove: sudo rm /etc/polkit-1/rules.d/49-linux-updater-zypper.rules
 */
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/bin/zypper" &&
        subject.active && subject.local &&
        subject.isInGroup("wheel")) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
]=]

    -- Table output, one row per update:
    --   v | Repository | Name | Current Version | Available Version | Arch
    backend.checkCommand = [[LC_ALL=C zypper --non-interactive -q list-updates 2>/dev/null]]

    function backend.parseCheck(output, ignored, ignoredOut)
        local items = {}
        local n = 0
        for line in (output or ""):gmatch("[^\n]+") do
            if line:match("^v%s*|") ~= nil then
                local fields = {}
                for field in line:gmatch("|([^|]*)") do
                    table.insert(fields, trim(field))
                end
                local name, from, to = fields[2], fields[3], fields[4]
                if name ~= nil and name ~= "" then
                    if ignored[name] then
                        table.insert(ignoredOut, { name = name, from = from, to = to, source = "plugin" })
                    else
                        n += 1
                        if #items < MAX_LISTED then
                            table.insert(items, { name = name, from = from, to = to })
                        end
                    end
                end
            end
        end
        return n, items
    end

    function backend.buildBackgroundCommand(ignored)
        local upgrade = "pkexec zypper --non-interactive " .. upgradeVerb
        if #ignored == 0 then
            return upgrade
        end
        local names = table.concat(ignored, " ")
        return "pkexec zypper --non-interactive addlock " .. names
            .. "; " .. upgrade
            .. "; s=$?; pkexec zypper --non-interactive removelock " .. names .. "; exit $s"
    end

    function backend.buildTerminalCommand(ignored)
        local upgrade = "sudo zypper " .. upgradeVerb
        if #ignored == 0 then
            return upgrade
        end
        local names = table.concat(ignored, " ")
        return "sudo zypper addlock " .. names .. " && " .. upgrade
            .. "; s=$?; sudo zypper removelock " .. names .. "; exit $s"
    end

    backend.sizeCommand = nil

    -- zypper needs-rebooting: exit 102 = reboot needed, 0 = not needed;
    -- anything else (old zypper) falls back to the kernel-modules check.
    backend.rebootCommand = [[zypper needs-rebooting >/dev/null 2>&1
code=$?
if [ "$code" -eq 102 ]; then echo missing
elif [ "$code" -eq 0 ]; then echo present
else test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing
fi]]

    return backend
end
