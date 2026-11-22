--!nonstrict
-- Pure shell helpers: quoting and argv builders. No noctalia.* here.
local shell = {}

shell.CLONE_SCRIPT = [[
echo $$ > "$3/pid"
GIT_TERMINAL_PROMPT=0 git clone --progress -- "$1" "$2" 2> "$3/log"
echo $? > "$3/status.tmp" && mv "$3/status.tmp" "$3/status"
:
]]

shell.PICK_SCRIPT = [[
p=$(zenity --file-selection --directory --title="$2") || exit 0
printf '%s' "$p" > "$1/picked.tmp" && mv "$1/picked.tmp" "$1/picked"
]]

function shell.quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function shell.terminalCommand(path)
  return "cd -- " .. shell.quote(path) .. " && exec \"${SHELL:-sh}\""
end

function shell.cloneArgv(url, dest, jobDir)
  return { "setsid", "sh", "-c", shell.CLONE_SCRIPT, "vscode-clone", url, dest, jobDir }
end

function shell.pickArgv(outDir, title)
  return { "setsid", "sh", "-c", shell.PICK_SCRIPT, "vscode-pick", outDir, title }
end

function shell.cancelArgv(pid)
  return { "kill", "-TERM", "--", "-" .. tostring(pid) }
end

-- git --progress rewrites its line with \r many times a second, so a long clone's log
-- holds thousands of segments. Only the tail is parsed: the newest progress line and
-- git's final fatal:/error: lines are always in the last few hundred bytes, and a
-- whole-log scan overran the host's per-callback CPU budget on a large clone.
shell.LOG_TAIL = 2048
shell.PROGRESS_MAX = 120

local function tail(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  if #text <= shell.LOG_TAIL then
    return text
  end
  local t = text:sub(-shell.LOG_TAIL)
  -- Drop the first, probably partial, segment.
  local cut = t:find("[\r\n]")
  if cut then
    t = t:sub(cut + 1)
  end
  return t
end

local function segments(text)
  local out = {}
  for seg in text:gmatch("[^\r\n]+") do
    local s = seg:match("^%s*(.-)%s*$")
    if s ~= "" then
      out[#out + 1] = s
    end
  end
  return out
end

function shell.cloneProgress(logText)
  local t = tail(logText)
  if t == nil then
    return nil
  end
  local segs = segments(t)
  local last = segs[#segs]
  if last and #last > shell.PROGRESS_MAX then
    last = last:sub(1, shell.PROGRESS_MAX)
    -- Don't end on a cut UTF-8 sequence.
    last = last:gsub("[\192-\255][\128-\191]*$", "")
  end
  return last
end

function shell.cloneError(logText)
  local t = tail(logText)
  if t == nil then
    return nil
  end
  local found
  for _, s in ipairs(segments(t)) do
    if s:match("^fatal:") or s:match("^error:") then
      found = s
    end
  end
  return found
end

function shell.parseJob(pidText, statusText)
  local job = {}
  if pidText ~= nil then
    job.pid = tonumber((pidText:gsub("%s+", "")))
  end
  if statusText ~= nil then
    job.exit = tonumber((statusText:gsub("%s+", "")))
  end
  return job
end

return shell
