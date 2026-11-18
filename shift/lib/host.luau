--!nonstrict
-- The only file that touches the `noctalia` global (spec C10, enforced by `make analyze`).
-- Entries and modules use this table instead, so the tests can pass
-- tests/lib/fake_host.luau in its place, and a change of the beta plugin API is absorbed
-- here. Keep both in sync. The rendering globals of each entry type (`ui`, `barWidget`,
-- `panel`, `shortcut`) are used directly by the entry files.

local Types = require("./types.luau")

local Host = {}

function Host.new(): Types.Host
  return {
    nowMs = noctalia.nowMs,
    formatTime = noctalia.formatTime,
    timeFormat = noctalia.timeFormat,
    dateFormat = noctalia.dateFormat,
    state = noctalia.state,
    json = noctalia.json,
    getConfig = noctalia.getConfig,
    pluginDataDir = noctalia.pluginDataDir,
    readFile = noctalia.readFile,
    writeFile = noctalia.writeFile,
    renameFile = noctalia.renameFile,
    fileExists = noctalia.fileExists,
    mkdirAll = noctalia.mkdirAll,
    listDir = noctalia.listDir,
    removeFile = noctalia.removeFile,
    getColor = noctalia.getColor,
    openSettings = noctalia.openSettings,
    setUpdateInterval = noctalia.setUpdateInterval,
    togglePanel = noctalia.togglePanel,
    runStream = noctalia.runStream,
    runAsync = noctalia.runAsync,
    http = noctalia.http,
    commandExists = noctalia.commandExists,
    getenv = noctalia.getenv,
    log = noctalia.log,
    notify = noctalia.notify,
    notifyError = noctalia.notifyError,
    tr = noctalia.tr,
    trp = noctalia.trp,
  }
end

return Host
