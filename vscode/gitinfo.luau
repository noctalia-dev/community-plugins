--!nonstrict
-- Pure parser for `git status --porcelain=v2 --branch`. No noctalia.* here.
local gitinfo = {}

function gitinfo.argv(path)
  return { "git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path, "status", "--porcelain=v2", "--branch" }
end

-- Returns { branch = string | nil, detached = bool, dirty = bool }.
-- Header lines start with "#". Any other non-empty line is a change, except
-- "! " (ignored), which does not count. Detached HEAD shows the first 7 chars
-- of the commit id as the branch.
function gitinfo.parse(stdout)
  local result = { branch = nil, detached = false, dirty = false }
  local oid = nil
  local head = nil
  local text = tostring(stdout or "") .. "\n"
  for raw in text:gmatch("([^\n]*)\n") do
    local line = (raw:gsub("\r$", ""))
    if line:sub(1, 1) == "#" then
      local value = line:match("^# branch%.oid (.*)$")
      if value then
        oid = value
      end
      value = line:match("^# branch%.head (.*)$")
      if value then
        head = value
      end
    elseif line ~= "" and line:sub(1, 1) ~= "!" then
      result.dirty = true
    end
  end
  if head == "(detached)" then
    result.detached = true
    if oid and oid ~= "" and oid:sub(1, 1) ~= "(" then
      result.branch = oid:sub(1, 7)
    end
  elseif head and head ~= "" then
    result.branch = head
  end
  return result
end

return gitinfo
