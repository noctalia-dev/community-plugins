--!nonstrict
local common = {}

common.PANEL_ID = "damian-ds7/battery-threshold:panel"

common.BATTERY_FILES = {
    THRESHOLD = "/charge_control_end_threshold",
    MODEL = "/model_name",
}

common.STATE = {
    IS_AVAILABLE = "is_available",
    IS_WRITABLE = "is_writable",
    CURRENT_THRESHOLD = "current_threshold",
    BATTERY_MODEL_NAME = "battery_model_name",
    RUN_SETUP_REQUEST = "run_setup_request",
    SET_THRESHOLD_REQUEST = "set_threshold_request",
}

common.CONFIG = {
    CHARGE_THRESHOLD = "charge_threshold",
    BATTERY_DEVICE = "battery_device",
}

common.MIN_THRESHOLD = 40
common.MAX_THRESHOLD = 100

local data_dir, data_dir_err = noctalia.pluginDataDir()
if not data_dir or data_dir_err then
    noctalia.log("Failed to get plugin data directory: " .. tostring(data_dir_err or "unknown error"))
end

common.THRESHOLD_FILE_PATH = if data_dir then data_dir .. "/threshold.txt" else nil

function common.clamp(value: number): number
    if value < common.MIN_THRESHOLD then
        return common.MIN_THRESHOLD
    end
    if value > common.MAX_THRESHOLD then
        return common.MAX_THRESHOLD
    end
    return value
end

function common.inRange(value: number): boolean
    return value >= common.MIN_THRESHOLD and value <= common.MAX_THRESHOLD
end

-- Asks the service to apply the value and optimistically updates the shown one.
function common.requestThreshold(value: number)
    noctalia.state.set(common.STATE.SET_THRESHOLD_REQUEST, value)
    noctalia.state.set(common.STATE.CURRENT_THRESHOLD, value)
end

return common
