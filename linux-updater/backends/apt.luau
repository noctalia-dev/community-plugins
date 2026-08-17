--!nonstrict
-- apt backend: native Debian-family support (Debian, Ubuntu, Mint, Pop!_OS,
-- Zorin, MX). Two constraints shape it:
--
-- 1. `apt-get update` needs root, so the unprivileged check reads the index
--    lists the system's own apt-daily timers keep fresh (a self-check nags
--    when those timers are off). The background run refreshes the lists
--    itself, under its own escalation, right before upgrading.
-- 2. apt has no per-run --exclude, so the plugin ignore list is applied by
--    holding the packages for the duration of the transaction
--    (apt-mark hold ... / unhold ...), the same tool a user would reach for.
--
-- debconf prompts need no DEBIAN_FRONTEND here: with no controlling tty it
-- falls back to its noninteractive frontend on its own, and the detached
-- runner never has one. Rollback is off: /var/cache/apt/archives is
-- routinely empty (Ubuntu cleans it) and old versions leave the repos.

return function(env)
    local MAX_LISTED = env.MAX_LISTED

    local backend = {
        id = "apt",
        caps = { bgUpdate = true, size = false, rollback = false, news = false, aur = false },
        checkTool = "apt-get",
        missingToolKey = "err_no_apt",
        nativeLabelKey = "source.system",
        escalateProgram = "/usr/bin/apt-get",
        -- One "Unpacking name (version) ..." line per package; "Setting up"
        -- would double-count the same set.
        progressPattern = "^Unpacking ",
        news = nil,
        polkitRuleName = "49-linux-updater-apt.rules",
        systemIgnoreLabelKey = "ignored_tag_hold",
    }

    backend.polkitRule = [=[/* Installed by the linux-updater Noctalia plugin (one password per update
 * run instead of one per apt call). Authentication is kept for ~5 minutes,
 * like sudo's timestamp. Scope: only pkexec launching apt-get or apt-mark,
 * only for an active local session of a sudo/wheel member.
 * Remove: sudo rm /etc/polkit-1/rules.d/49-linux-updater-apt.rules
 */
polkit.addRule(function(action, subject) {
    var prog = action.lookup("program");
    if (action.id == "org.freedesktop.policykit.exec" &&
        (prog == "/usr/bin/apt-get" || prog == "/usr/bin/apt-mark") &&
        subject.active && subject.local &&
        (subject.isInGroup("sudo") || subject.isInGroup("wheel"))) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
]=]

    -- `apt list --upgradable` needs no root and reports both versions:
    --   name/suite newver arch [upgradable from: oldver]
    -- Phased updates Ubuntu holds back are absent from this list — that is
    -- deliberate on their side, not a parsing gap. Held packages carry
    -- "[upgradable from: ...]" too and are filtered by the parser below via
    -- the system hold list appended after a separator line.
    backend.checkCommand = [[apt list --upgradable 2>/dev/null; echo '::HOLDS'; apt-mark showhold 2>/dev/null]]

    function backend.parseCheck(output, ignored, ignoredOut)
        local items = {}
        local n = 0
        local holds = {}
        local inHolds = false
        for line in (output or ""):gmatch("[^\n]+") do
            if line == "::HOLDS" then
                inHolds = true
            elseif inHolds then
                holds[line] = true
            end
        end
        for line in (output or ""):gmatch("[^\n]+") do
            if line == "::HOLDS" then
                break
            end
            local name, to, from = line:match("^([^/%s]+)/%S+%s+(%S+)%s+%S+%s+%[upgradable from: ([^%]]+)%]")
            if name ~= nil then
                if holds[name] then
                    table.insert(ignoredOut, { name = name, from = from, to = to, source = "system" })
                elseif ignored[name] then
                    table.insert(ignoredOut, { name = name, from = from, to = to, source = "plugin" })
                else
                    n += 1
                    if #items < MAX_LISTED then
                        table.insert(items, { name = name, from = from, to = to })
                    end
                end
            end
        end
        return n, items
    end

    local UPGRADE_FLAGS = " -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade"

    -- Two pkexec calls (update, then upgrade) instead of one pkexec'd shell:
    -- the polkit rule can then stay scoped to apt-get/apt-mark, and with
    -- keep-authorization one password still covers the run.
    function backend.buildBackgroundCommand(ignored)
        local upgrade = "pkexec apt-get -qq update; pkexec apt-get" .. UPGRADE_FLAGS
        if #ignored == 0 then
            return upgrade
        end
        local names = table.concat(ignored, " ")
        return "pkexec apt-get -qq update; pkexec apt-mark hold " .. names
            .. "; " .. "pkexec apt-get" .. UPGRADE_FLAGS
            .. "; s=$?; pkexec apt-mark unhold " .. names .. "; exit $s"
    end

    function backend.buildTerminalCommand(ignored)
        local upgrade = "sudo apt-get update && sudo apt-get full-upgrade"
        if #ignored == 0 then
            return upgrade
        end
        local names = table.concat(ignored, " ")
        return "sudo apt-get update && sudo apt-mark hold " .. names
            .. " && sudo apt-get full-upgrade; s=$?; sudo apt-mark unhold " .. names .. "; exit $s"
    end

    -- `apt-get -s` omits the "Need to get" line in simulate mode, so a
    -- cheap size estimate is not available; capability off.
    backend.sizeCommand = nil

    backend.rebootCommand = [[test -f /var/run/reboot-required && echo missing || echo present]]

    -- The unprivileged check depends on the apt-daily timers keeping the
    -- package lists fresh; offer to enable them when they are off.
    backend.selfChecks = {
        {
            id = "apt_timers",
            testCommand = [[systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 && echo ok || echo fail]],
            hintKey = "selfcheck_apt_timers",
            actionKey = "selfcheck_fix",
            tipKey = "selfcheck_apt_timers_tip",
            fixCommand = "pkexec systemctl enable --now apt-daily.timer apt-daily-upgrade.timer",
        },
    }

    return backend
end
