--!nonstrict
-- Owns both halves of Super Caffeine: Noctalia caffeine (idle inhibit) and a
-- logind lid-switch inhibitor held by a transient user unit. The unit dies on
-- logout/reboot, so the mode always starts OFF. Widget and shortcut talk to
-- this singleton through noctalia.state.
local UNIT = "super-caffeine.service"
local CHECK = `systemctl --user is-active --quiet {UNIT}`
local START = `systemctl --user reset-failed {UNIT} >/dev/null 2>&1 || true; `
    .. `systemd-run --user --quiet --collect --unit={UNIT} --description='Noctalia Super Caffeine' `
    .. `systemd-inhibit --what=handle-lid-switch --mode=block `
    .. `--who='Super Caffeine' --why='Lid closed, stay awake' sleep infinity`
    .. ` && noctalia msg caffeine-enable`
local STOP = `systemctl --user stop {UNIT}; noctalia msg caffeine-disable`

local active = false
local busy = false

local function publish()
    noctalia.state.set("super_caffeine_status", { active = active, busy = busy })
end

local function refresh(callback)
    noctalia.runAsync(CHECK, function(r)
        active = r.exitCode == 0
        publish()
        if callback then callback(active) end
    end)
end

local function setActive(on)
    if busy or on == active then return end
    busy = true
    publish()
    noctalia.runAsync(if on then START else STOP, function(r)
        if r.exitCode ~= 0 then
            noctalia.notifyError(noctalia.tr("title"), noctalia.string.trim(r.stderr or ""))
        end
        refresh(function()
            busy = false
            publish()
        end)
    end)
end

local function handle(action)
    if action == "toggle" then
        refresh(function(cur) setActive(not cur) end)
    elseif action == "enable" then
        setActive(true)
    elseif action == "disable" then
        setActive(false)
    elseif action == "refresh" or action == "status" then
        refresh()
    end
end

noctalia.state.watch("super_caffeine_command", function(cmd)
    if type(cmd) == "table" then handle(cmd.action) end
end)

noctalia.setUpdateInterval(5000)
refresh()

function update()
    if not busy then refresh() end
end

function onIpc(event, _payload)
    handle(event)
end

function onExit(_signal, reason)
    -- Disable/uninstall removes the controls, so release what we own. Launch
    -- without a callback: the VM is torn down as soon as this returns.
    -- Reload/shutdown keep the unit so the mode survives a shell restart.
    if reason == "disable" or reason == "uninstall" then
        noctalia.runAsync("if " .. CHECK .. "; then " .. STOP .. "; fi")
    end
end
