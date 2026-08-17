--!nonstrict
-- dnf backend: native Fedora-family support. Chosen over the generic
-- PackageKit backend because dnf brings two things PackageKit cannot:
-- old-version info for the check list (via rpm) and a real transaction
-- rollback (`dnf history undo`), which is safer than any file-cache
-- approach — dnf reverses the exact transaction, dependencies included.
--
-- caps.rollback = "native": the engine records the dnf transaction id
-- after a successful run (txIdCommand/parseTxId) and undoes whole runs
-- with rollbackNativeCommand; per-package rollback is not offered.

return function(env)
    local MAX_LISTED = env.MAX_LISTED

    local backend = {
        id = "dnf",
        caps = { bgUpdate = true, size = false, rollback = "native", news = false, aur = false },
        checkTool = "dnf",
        missingToolKey = "err_no_dnf",
        nativeLabelKey = "source.system",
        escalateProgram = "/usr/bin/dnf",
        -- dnf5: "[ 3/12] Upgrading name-..." (per package; the paired
        -- "Removing" of the old version is deliberately not counted).
        -- dnf4: "  Upgrading        : name-...". The summary header
        -- ("Upgrading:" / " Upgrading:  5 packages") matches neither branch.
        progressPattern = "^\\[ *[0-9]+/[0-9]+\\] (Upgrading|Installing|Downgrading|Reinstalling) |^ +(Upgrading|Installing|Downgrading|Reinstalling) +: ",
        news = nil,
        polkitRuleName = "49-linux-updater-dnf.rules",
    }

    backend.polkitRule = [=[/* Installed by the linux-updater Noctalia plugin (one password per update
 * run instead of one per dnf transaction). Authentication is kept for
 * ~5 minutes, like sudo's timestamp. Scope: only pkexec launching dnf,
 * only for an active local session of a wheel member.
 * Remove: sudo rm /etc/polkit-1/rules.d/49-linux-updater-dnf.rules
 */
polkit.addRule(function(action, subject) {
    var prog = action.lookup("program");
    if (action.id == "org.freedesktop.policykit.exec" &&
        (prog == "/usr/bin/dnf" || prog == "/usr/bin/dnf5" ||
         prog == "/usr/bin/dnf-3") &&
        subject.active && subject.local &&
        subject.isInGroup("wheel")) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
]=]

    -- `dnf check-update` exits 100 when updates exist, 0 when none, 1 on a
    -- real failure — and prints only the NEW version. The old one comes
    -- from rpm, joined in the shell so Lua parses a small "name|old|new"
    -- list instead of the whole rpm database.
    backend.checkCommand = [[out=$(LC_ALL=C dnf -q check-update 2>/dev/null); code=$?
if [ "$code" -eq 0 ]; then exit 0; fi
if [ "$code" -ne 100 ]; then exit "$code"; fi
printf '%s\n' "$out" | awk 'NF>=3 && $1 ~ /\./ && $2 ~ /^[0-9]/ {print $1, $2}' | while read -r na ver; do
    name=${na%.*}
    old=$(rpm -q --qf '%{EVR}\n' "$name" 2>/dev/null | head -n 1)
    printf '%s|%s|%s\n' "$name" "$old" "$ver"
done
exit 0]]

    function backend.parseCheck(output, ignored, ignoredOut)
        local items = {}
        local n = 0
        for line in (output or ""):gmatch("[^\n]+") do
            local name, from, to = line:match("^([^|]+)|([^|]*)|(.+)$")
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
        return n, items
    end

    local function excludeFlags(ignored)
        local flags = ""
        for _, name in ipairs(ignored) do
            flags = flags .. " --exclude=" .. name
        end
        return flags
    end

    function backend.buildBackgroundCommand(ignored)
        return "pkexec dnf -y --refresh upgrade" .. excludeFlags(ignored)
    end

    function backend.buildTerminalCommand(ignored)
        return "sudo dnf --refresh upgrade" .. excludeFlags(ignored)
    end

    backend.sizeCommand = nil

    -- "name version" per line for the given (quoted) names; the engine uses
    -- it after an interactive terminal run to keep only the packages whose
    -- installed version actually moved. %{EVR} matches the check's rpm side.
    function backend.installedVersionsCommand(quotedNames)
        return "rpm -q --qf '%{NAME} %{EVR}\\n' " .. table.concat(quotedNames, " ") .. " 2>/dev/null"
    end

    -- needs-restarting (dnf-utils) knows about services and libraries, not
    -- just the kernel; fall back to the kernel-modules check without it.
    backend.rebootCommand = [[if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1; [ "$?" -eq 1 ] && echo missing || echo present
else
    test -d "/usr/lib/modules/$(uname -r)" && echo present || echo missing
fi]]

    -- Newest transaction id, queried right after a successful run; the
    -- history strip's whole-run rollback undoes exactly that transaction.
    backend.txIdCommand = "LC_ALL=C dnf history list 2>/dev/null | head -n 6"

    function backend.parseTxId(output)
        for line in (output or ""):gmatch("[^\n]+") do
            local id = line:match("^%s*(%d+)%s")
            if id ~= nil then
                return tonumber(id)
            end
        end
        return nil
    end

    function backend.rollbackNativeCommand(txId)
        return "pkexec dnf -y history undo " .. tostring(txId)
    end

    return backend
end
