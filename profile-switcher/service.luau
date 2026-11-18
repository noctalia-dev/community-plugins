--!nonstrict

local profiles =
    require("./profiles.luau")

local apply =
    require("./apply.luau")

local scheduler =
    require("./scheduler.luau")


local activeProfile = nil
local lastMinuteKey = nil
local lastTickMs = nil


local function publish(profile)
    activeProfile =
        profile and profile.id or nil

    noctalia.state.set(
        "activeProfile",
        activeProfile
    )

    noctalia.state.set(
        "activeProfileName",
        profile and profile.name or nil
    )
end


local function activate(id, notify)
    local profile =
        profiles.find(id)

    if not profile then
        noctalia.notifyError(
            noctalia.tr("common.plugin_name"),
            noctalia.tr(
                "error.profile_not_found",
                { id = tostring(id) }
            )
        )

        return false
    end

    local ok, err =
        apply.apply(profile)

    if not ok then
        noctalia.notifyError(
            noctalia.tr("common.plugin_name"),
            tostring(err)
        )

        return false
    end

    publish(profile)

    if notify then
        noctalia.notify(
            noctalia.tr("common.plugin_name"),
            noctalia.tr(
                "message.applied",
                { name = tostring(profile.name) }
            )
        )
    end

    return true
end


local function scheduleEnabled(profile)
    return profile
        and profile.schedule
        and profile.schedule.enabled ~= false
end


local function automaticProfiles()
    local result = {}

    for _, profile in ipairs(
        profiles.loadAll()
    ) do
        if scheduleEnabled(profile) then
            table.insert(
                result,
                profile
            )
        end
    end

    return result
end


local function reconcileSchedule()
    local profile =
        scheduler.findCurrent(
            automaticProfiles()
        )

    if profile
        and profile.id ~= activeProfile
    then
        activate(
            profile.id,
            false
        )
    end
end


local function evaluateScheduleStart()
    for _, profile in ipairs(
        automaticProfiles()
    ) do
        if scheduler.startsNow(profile) then
            if profile.id ~= activeProfile then
                activate(
                    profile.id,
                    false
                )
            end

            return
        end
    end
end


reconcileSchedule()

lastMinuteKey =
    noctalia.formatTime(
        "%Y-%m-%d %H:%M"
    )

lastTickMs =
    noctalia.nowMs()

noctalia.setUpdateInterval(15000)


function update()
    local nowMs =
        noctalia.nowMs()

    local minuteKey =
        noctalia.formatTime(
            "%Y-%m-%d %H:%M"
        )

    if lastTickMs
        and nowMs - lastTickMs > 90000
    then
        reconcileSchedule()

        lastTickMs =
            nowMs

        lastMinuteKey =
            minuteKey

        return
    end

    lastTickMs =
        nowMs

    if minuteKey == lastMinuteKey then
        return
    end

    lastMinuteKey =
        minuteKey

    evaluateScheduleStart()
end


function onOutputsChanged()
    if not activeProfile then
        return
    end

    local profile =
        profiles.find(activeProfile)

    if profile then
        apply.apply(profile)
    end
end


function onIpc(event, payload)
    if event == "activate" then
        if not payload
            or payload == ""
        then
            noctalia.notifyError(
                noctalia.tr("common.plugin_name"),
                noctalia.tr("error.missing_profile_id")
            )

            return
        end

        -- Manual activation is ALWAYS allowed.
        -- schedule.enabled only controls automatic activation.
        activate(
            payload,
            true
        )

        return
    end

    if event == "status" then
        noctalia.notify(
            noctalia.tr("common.plugin_name"),
            activeProfile
                and noctalia.tr(
                    "message.active",
                    { id = activeProfile }
                )
                or noctalia.tr(
                    "message.no_active_profile"
                )
        )

        return
    end

    if event == "reconcile" then
        reconcileSchedule()
        return
    end

    if event == "list" then
        local ids = {}

        for _, profile in ipairs(
            profiles.loadAll()
        ) do
            table.insert(
                ids,
                profile.id
            )
        end

        noctalia.notify(
            noctalia.tr("common.plugin_name"),
            table.concat(ids, ", ")
        )

        return
    end

    noctalia.notifyError(
        noctalia.tr("common.plugin_name"),
        noctalia.tr(
            "error.unknown_command",
            { command = tostring(event) }
        )
    )
end
