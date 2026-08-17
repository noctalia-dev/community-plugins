--!nonstrict
-- pacman backend: everything Arch-specific the engine needs, for Arch and
-- its derivatives (Manjaro, EndeavourOS, ... — anything with ID_LIKE=arch).
-- Constructed with the engine's helper environment so parsers and command
-- builders share its utilities.
--
-- Backend contract (what the engine relies on):
--   id, caps { bgUpdate, size, rollback, news, aur }, checkTool,
--   missingToolKey, nativeLabelKey, escalateProgram, progressPattern,
--   news { url, page } | nil, polkitRuleName, polkitRule,
--   checkCommand, parseCheck(stdout, ignoredSet, ignoredOut) -> n, items,
--   resolveAurHelper(), aurCheckCommand(helper),
--   buildBackgroundCommand(ignoreList), buildTerminalCommand(ignoreList),
--   sizeCommand(quotedNames) | nil, rebootCommand,
--   findPkgSh, rollbackInstall, depsListCommand(name), reverseDepsCountSh

return function(env)
    local trim = env.trim
    local shellQuote = env.shellQuote
    local cfg = env.cfg
    local commandExists = env.commandExists
    local MAX_LISTED = env.MAX_LISTED

    local backend = {
        id = "pacman",
        caps = { bgUpdate = true, size = true, rollback = "cache", news = true, aur = true },
        checkTool = "checkupdates",
        missingToolKey = "err_no_checkupdates",
        nativeLabelKey = "source.pacman",
        escalateProgram = "/usr/bin/pacman",
        -- Lines pacman prints once per package while applying a transaction;
        -- the engine greps the run log with this to drive the progress bar.
        progressPattern = "^(upgrading|installing|reinstalling|downgrading) ",
        news = {
            url = "https://archlinux.org/feeds/news/",
            page = "https://archlinux.org/news/",
        },
        polkitRuleName = "49-linux-updater-pacman.rules",
        systemIgnoreLabelKey = "ignored_tag_system",
        systemIgnoreTipKey = "ignored_tip_system",
    }

    -- Without this rule pkexec re-authenticates every pacman transaction of
    -- a run (db sync + each install batch); with it one password covers the
    -- whole run. Kept in sync with polkit/49-linux-updater-pacman.rules.
    backend.polkitRule = [=[/* Installed by the linux-updater Noctalia plugin (one password per update
 * run instead of one per pacman transaction). Authentication is kept for
 * ~5 minutes, like sudo's timestamp. Scope: only pkexec launching
 * /usr/bin/pacman, only for an active local session of a wheel member.
 * Remove: sudo rm /etc/polkit-1/rules.d/49-linux-updater-pacman.rules
 */
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec" &&
        action.lookup("program") == "/usr/bin/pacman" &&
        subject.active && subject.local &&
        subject.isInGroup("wheel")) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
]=]

    -- checkupdates exits 2 for "no updates" (not an error), 1 for a real
    -- failure. Normalize the former to 0 so only a genuine failure reaches
    -- the engine.
    backend.checkCommand = [[checkupdates 2>/dev/null; code=$?; if [ "$code" -eq 2 ]; then exit 0; fi; exit "$code"]]

    -- One "name oldver -> newver" line per package: checkupdates' format,
    -- which yay -Qua and paru -Qua also use. A trailing "[ignored]" is
    -- pacman.conf's IgnorePkg: the run skips those, so they go to
    -- ignoredOut instead of the pending count.
    function backend.parseCheck(output, ignored, ignoredOut)
        local items = {}
        local n = 0
        for line in (output or ""):gmatch("[^\n]+") do
            local parts = {}
            for token in line:gmatch("%S+") do
                table.insert(parts, token)
            end
            if #parts >= 4 then
                local name, from, to = parts[1], parts[2], parts[4]
                if parts[#parts] == "[ignored]" then
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

    -- auto tries yay then paru. An explicit choice is trusted as-is and
    -- reported missing instead of falling back to another helper.
    function backend.resolveAurHelper()
        local choice = cfg("aur_helper")
        if choice == "off" then
            return nil
        end
        if choice == "custom" then
            return "custom"
        end
        if choice == "yay" or choice == "paru" then
            return choice
        end
        if commandExists("yay") then
            return "yay"
        end
        if commandExists("paru") then
            return "paru"
        end
        return nil
    end

    function backend.aurCheckCommand(helper)
        if helper == "custom" then
            local raw = trim(cfg("aur_check_cmd"))
            return raw ~= "" and raw or nil
        end
        -- stderr is inspected by the engine to tell a real failure from the
        -- "-Qua" family's usual no-updates exit code.
        return helper .. " -Qua"
    end

    local function ignoreFlag(ignored)
        return #ignored > 0 and (" --ignore " .. table.concat(ignored, ",")) or ""
    end

    -- The core upgrade command, fully non-interactive. pkexec raises the
    -- polkit password dialog; --noconfirm answers every remaining question
    -- with its default. AUR helpers run as the user and escalate through
    -- pkexec themselves, so no terminal and no sudo tty are ever needed.
    function backend.buildBackgroundCommand(ignored)
        local quietFlags = " --noconfirm --noprogressbar --color never"
        local helper = backend.resolveAurHelper()
        if helper ~= nil and helper ~= "custom" and commandExists(helper) then
            local autoAnswers = helper == "paru" and " --skipreview"
                or " --answerdiff None --answerclean None --answeredit None"
            return helper .. " -Syu --sudo pkexec" .. autoAnswers .. quietFlags .. ignoreFlag(ignored)
        end
        return "pkexec pacman -Syu" .. quietFlags .. ignoreFlag(ignored)
    end

    -- Interactive variant for the terminal fallback: no --noconfirm,
    -- prompts and the PKGBUILD review work as usual.
    function backend.buildTerminalCommand(ignored)
        local helper = backend.resolveAurHelper()
        if helper ~= nil and helper ~= "custom" and commandExists(helper) then
            return helper .. " -Syu" .. ignoreFlag(ignored)
        end
        return "sudo pacman -Syu" .. ignoreFlag(ignored)
    end

    -- Summed download size of the pending repo packages, in MiB on stdout.
    function backend.sizeCommand(quotedNames)
        return "LC_ALL=C pacman -Si " .. table.concat(quotedNames, " ") .. [[ 2>/dev/null | awk '
/^Name/ { name=$3 }
/^Download Size/ && !(name in done) {
    done[name]=1
    v=$4; u=$5
    gsub(",", ".", v)
    if (u == "GiB") v = v * 1024
    else if (u == "KiB") v = v / 1024
    else if (u == "B") v = v / 1024 / 1024
    sum += v
}
END { printf "%.2f", sum }']]
    end

    -- A kernel upgrade replaces the whole /usr/lib/modules/<version> tree;
    -- once the running kernel's own directory is gone, a reboot switches to
    -- the new one. Kernel-flavour agnostic.
    backend.rebootCommand = [[test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing]]

    -- sh helper: prints the cached package file for "name version", trying
    -- the pacman cache first, then paru's and yay's build caches.
    backend.findPkgSh = [[find_pkg() {
for f in /var/cache/pacman/pkg/"$1"-"$2"-*.pkg.tar.zst /var/cache/pacman/pkg/"$1"-"$2"-*.pkg.tar.xz \
    "$HOME"/.cache/paru/clone/*/"$1"-"$2"-*.pkg.tar.zst "$HOME"/.cache/paru/clone/*/"$1"-"$2"-*.pkg.tar.xz \
    "$HOME"/.cache/yay/*/"$1"-"$2"-*.pkg.tar.zst "$HOME"/.cache/yay/*/"$1"-"$2"-*.pkg.tar.xz; do
    if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
done
return 1
}]]

    backend.rollbackInstall = "pkexec pacman -U --noconfirm --noprogressbar --color never"

    -- Recursive dependency list of an installed package, one name per line
    -- (pactree ships with checkupdates in pacman-contrib).
    function backend.depsListCommand(name)
        return "pactree -l " .. shellQuote(name) .. " 2>/dev/null"
    end

    -- Direct reverse dependencies count for "$1"; used by the run probe.
    backend.reverseDepsCountSh = [[n=$(pactree -rd1 "$1" 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] && n=$((n - 1))]]

    return backend
end
