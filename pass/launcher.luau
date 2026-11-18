--!nonstrict

local entries = {}

local function shellEscape(str)
  return "'" .. str:gsub("'", "'\\''") .. "'"
end

noctalia.state.watch("entries", function(value)
  entries = value or {}
end)

function onQuery(query)
    local results = {}
    local action = "password"
    local search = query

    if query:match("^otp%s+") then
        action = "otp"
        search = query:gsub("^otp%s+", "")
    end

    for _, entry in ipairs(entries) do
        local score

        if search == "" then
            score = 1
        else
            score = noctalia.fuzzyScore(search, entry.path)
        end

        if score then
            local subtitle = entry.subtitle ~= "" and entry.subtitle or nil

            if action == "otp" then
                table.insert(results, {
                    id = "otp:" .. entry.id,
                    title = "Copy OTP: " .. entry.title,
                    subtitle = subtitle,
                    glyph = "123",
                    score = score,
                })
            else
                table.insert(results, {
                    id = "password:" .. entry.id,
                    title = entry.title,
                    subtitle = subtitle,
                    glyph = "key",
                    score = score,
                })
            end
        end
    end

    launcher.setResults(query, results)
end

local function copyWithPass(command, path, successMessage)
    local escaped = shellEscape(path)

    noctalia.runAsync(command .. " " .. escaped, function(result)
        if result.exitCode == 0 then
            noctalia.notify("Pass", successMessage)
            return
        end

        local stderr = result.stderr or ""
        local err = stderr:lower()

        if err:find("gpg") then
            noctalia.notify("Pass", noctalia.tr("notification.unlocking"))

            noctalia.runInTerminal(command .. " " .. escaped)
            return
        end

        if err == "" then
            err = noctalia.tr("notification.copy_failed")
        else
            err = stderr
        end

        noctalia.notifyError("Pass", err)
    end)
end

function onActivate(id)
    local action, path = id:match("^([^:]+):(.+)$")

    if action == "otp" then
        copyWithPass("pass otp -c", path, "OTP code copied")
    else
        copyWithPass("pass -c", path or id, noctalia.tr("notification.copied"))
    end
end
