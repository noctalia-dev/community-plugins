--!nonstrict
-- Plugin-wide identity constants, kept in one place so a rename touches a
-- single file. `id` must match `id` in plugin.toml.

return {
    id = "cwhirly/lunar-calendar",

    -- Full entry ids, as used by noctalia.togglePanel() and the IPC commands.
    panel = "cwhirly/lunar-calendar:panel",
    widget = "cwhirly/lunar-calendar:calendar",
    service = "cwhirly/lunar-calendar:holiday-sync",

    -- Upstream of the Chinese statutory-holiday data (MIT licensed).
    holiday_source = "https://github.com/NateScarlet/holiday-cn",
}
