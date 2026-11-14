-- commands.luau: argv builders, id validation, forbidden verbs.
local commands = loadModule("commands.luau")

local function joined(argv)
  return table.concat(argv, " ")
end

eq("commands: show argv", joined(commands.show("logonbox-vpn-cli")), "logonbox-vpn-cli show .*")
eq("commands: connect argv", joined(commands.connect("logonbox-vpn-cli", 0)), "logonbox-vpn-cli connect 0")
eq("commands: connect argv string id", joined(commands.connect("cli", "3")), "cli connect 3")
eq("commands: disconnect argv", joined(commands.disconnect("logonbox-vpn-cli", 2)), "logonbox-vpn-cli disconnect 2")
eq("commands: openGui argv", joined(commands.openGui("logonbox-vpn-gui")), "logonbox-vpn-gui")
eq("commands: openGui length", #commands.openGui("logonbox-vpn-gui"), 1)
eq("commands: monitor cmd", commands.MONITOR_CMD, "gdbus monitor --system --dest com.logonbox.vpn")
eq(
  "commands: name owner argv",
  joined(commands.NAME_OWNER_ARGV),
  "gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.logonbox.vpn"
)
eq("commands: read timeout", commands.READ_TIMEOUT_MS, 15000)
eq("commands: connect timeout", commands.CONNECT_TIMEOUT_MS, 60000)
eq("commands: disconnect timeout", commands.DISCONNECT_TIMEOUT_MS, 30000)

-- validId
local list = { { id = 0 }, { id = 4 } }
eq("commands: validId accepts 0", commands.validId(0, list), 0)
eq("commands: validId accepts '0'", commands.validId("0", list), 0)
eq("commands: validId accepts 4", commands.validId(4, list), 4)
eq("commands: validId rejects injection", commands.validId("0; rm", list), nil)
eq("commands: validId rejects -d", commands.validId("-d", list), nil)
eq("commands: validId rejects empty", commands.validId("", list), nil)
eq("commands: validId rejects fraction", commands.validId(1.5, list), nil)
eq("commands: validId rejects negative", commands.validId(-1, list), nil)
eq("commands: validId rejects unknown id", commands.validId(7, list), nil)
eq("commands: validId rejects unknown string id", commands.validId("7", list), nil)
eq("commands: validId rejects nil", commands.validId(nil, list), nil)
eq("commands: validId rejects table", commands.validId({}, list), nil)
eq("commands: validId rejects no list", commands.validId(0, nil), nil)
eq("commands: validId rejects padded", commands.validId(" 0", list), nil)

-- detached
eq("commands: open_gui is detached", commands.detached("open_gui"), true)
eq("commands: connect is not detached", commands.detached("connect"), false)
eq("commands: disconnect is not detached", commands.detached("disconnect"), false)
eq("commands: refresh is not detached", commands.detached("refresh"), false)
eq("commands: nil is not detached", commands.detached(nil), false)

-- no forbidden verbs in any builder output
local forbidden = { "delete", "create", "edit", "config", "update", "shutdown" }
local outputs = {
  commands.show("logonbox-vpn-cli"),
  commands.connect("logonbox-vpn-cli", 0),
  commands.disconnect("logonbox-vpn-cli", 0),
  commands.openGui("logonbox-vpn-gui"),
  commands.NAME_OWNER_ARGV,
}
local clean = true
for _, argv in ipairs(outputs) do
  eq("commands: argv has a command word or is the gui", #argv >= 1, true)
  for _, word in ipairs(argv) do
    if word == "-d" then
      clean = false
    end
    for _, bad in ipairs(forbidden) do
      if word == bad then
        clean = false
      end
    end
  end
end
check("commands: no forbidden verbs", clean)
local cliOnly = { commands.show("c"), commands.connect("c", 1), commands.disconnect("c", 1) }
for _, argv in ipairs(cliOnly) do
  check("commands: cli call is never argument-less " .. joined(argv), #argv >= 3)
end

-- download page (R4)
eq("commands: download url is the official LogonBox docs page",
  commands.DOWNLOAD_URL, "https://docs.logonbox.com/app/logonbox-documentation/en/article/7680932")
eq("commands: openDownload argv", joined(commands.openDownload()), "xdg-open " .. commands.DOWNLOAD_URL)
eq("commands: openDownload length", #commands.openDownload(), 2)
eq("commands: open_download is detached", commands.detached("open_download"), true)
