--!nonstrict
-- Pure argv builders and constants. No noctalia calls.
-- Never builds: disconnect -d, delete, create, edit, config, update, shutdown, or an
-- argument-less connect/disconnect/show (the bare CLI opens an interactive shell).

local M = {}

M.MONITOR_CMD = "gdbus monitor --system --dest com.logonbox.vpn"

M.NAME_OWNER_ARGV = {
  "gdbus", "call", "--system", "--dest", "org.freedesktop.DBus",
  "--object-path", "/org/freedesktop/DBus",
  "--method", "org.freedesktop.DBus.NameHasOwner", "com.logonbox.vpn",
}

M.READ_TIMEOUT_MS = 15000
M.CONNECT_TIMEOUT_MS = 60000
M.DISCONNECT_TIMEOUT_MS = 30000

-- LogonBox publishes no public installer: the client comes from each organisation's
-- own LogonBox server (User Portal > Download). This official LogonBox article says
-- how to get and install the Linux client.
M.DOWNLOAD_URL = "https://docs.logonbox.com/app/logonbox-documentation/en/article/7680932"

function M.show(cli)
  return { cli, "show", ".*" }
end

function M.connect(cli, id)
  return { cli, "connect", tostring(id) }
end

function M.disconnect(cli, id)
  return { cli, "disconnect", tostring(id) }
end

function M.openGui(gui)
  return { gui }
end

function M.openDownload()
  return { "xdg-open", M.DOWNLOAD_URL }
end

-- A connection id that is digits only and present in the snapshot, or nil.
function M.validId(value, connections)
  local id = nil
  if type(value) == "number" then
    if value >= 0 and value == math.floor(value) then
      id = value
    end
  elseif type(value) == "string" then
    if value:match("^%d+$") then
      id = tonumber(value)
    end
  end
  if id == nil or type(connections) ~= "table" then
    return nil
  end
  for _, conn in ipairs(connections) do
    if conn.id == id then
      return id
    end
  end
  return nil
end

-- Requests that launch a program (the GUI, the browser) instead of waiting for a result.
function M.detached(request)
  return request == "open_gui" or request == "open_download"
end

return M
