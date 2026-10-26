local function tr(key, args) return noctalia.tr(key, args) end

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil or v == "" then return fallback end
  return v
end

local MAX_PROMPT_CHARS = 8000
local MAX_CARD_CHARS = 30000
local MAX_SOURCES = 5
local PUSH_EVERY_MS = 100
local GLOBAL_SCORE = 2047

local function ulen(s) return utf8.len(s) or #s end

local function utf8_cut(s, n)
  local ok, i = pcall(utf8.offset, s, n + 1)
  if ok and i and i <= #s then return s:sub(1, i - 1) .. "…" end
  return s
end

local function is_dir(path)
  local ok, info = pcall(noctalia.fileInfo, path)
  return ok and type(info) == "table" and info.isDir == true
end

local function workdir()
  local dir = noctalia.expandPath(cfg("workdir", "~"))
  if is_dir(dir) then return dir, false end
  return noctalia.expandPath("~"), true
end

local function runtime_dir()
  local base = noctalia.getenv and noctalia.getenv("XDG_RUNTIME_DIR")
  if type(base) ~= "string" or base == "" then base = noctalia.pluginDataDir() end
  return base .. "/ask-claude"
end

local function helper(name) return noctalia.pluginDir() .. "/bin/" .. name end

-- the native installer puts claude in ~/.local/bin, which a graphical session's PATH often lacks
local function claude_cmd()
  if noctalia.commandExists("claude") then return "claude" end
  local path = noctalia.expandPath("~/.local/bin/claude")
  if noctalia.fileExists(path) then return path end
  return nil
end

local MODEL_LABELS = { sonnet = "Sonnet", haiku = "Haiku", opus = "Opus" }

local function model_label()
  return MODEL_LABELS[cfg("model", "sonnet")] or tr("card.model_default")
end

local MULTIPLEXERS = { herdr = true, tmux = true, tuios = true, zellij = true }

-- old configs may still say "foot"
local function target()
  local t = cfg("open_target", "terminal")
  return MULTIPLEXERS[t] and t or "terminal"
end

local function target_label() return tr("card.target." .. target()) end

local function is_auth_error(text)
  return text:find("Please run /login", 1, true) ~= nil
      or text:find("API Error: 401", 1, true) ~= nil
      or text:find("authentication_error", 1, true) ~= nil
end

local function sanitize(s)
  s = s:gsub("\27%[[%d;?]*%a", "")
  s = s:gsub("[%z\1-\8\11-\31\127]", "")
  return s
end

local function strip_md(s)
  s = s:gsub("```[%w_+%-]*\n?", "")
  s = s:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
  s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
  s = s:gsub("`([^`\n]+)`", "%1")
  s = s:gsub("%[([^%]\n]+)%]%((https?://[^%)%s]+)%)", "%1 (%2)")
  return s
end

local function clean_text(s) return strip_md(sanitize(s)) end

local cur = nil
local gen = 0
local last_push = 0

local HISTORY_MAX = 5
local history = {}

local function history_path() return noctalia.pluginDataDir() .. "/history.json" end

local function load_history()
  local raw = noctalia.readFile(history_path())
  if type(raw) ~= "string" then return end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then return end
  for _, e in ipairs(data) do
    if type(e) == "table" and type(e.q) == "string" and type(e.text) == "string" and #history < HISTORY_MAX then
      history[#history + 1] = e
    end
  end
end

local function save_history()
  local dir = noctalia.pluginDataDir()
  noctalia.mkdirAll(dir)
  local path = history_path()
  if noctalia.writeFile(path, noctalia.json.encode(history)) then
    noctalia.runAsync({ "chmod", "600", path })
  end
end

load_history()

local function card_body()
  if cur.status == "error" then return cur.err or tr("error.unknown") end
  local body
  if cur.text ~= "" then
    body = clean_text(cur.text)
    if ulen(body) > MAX_CARD_CHARS then
      body = utf8_cut(body, MAX_CARD_CHARS) .. "\n\n" .. tr("card.truncated")
    end
  elseif cur.status == "thinking" then
    body = tr("card.thinking")
  else
    body = tr("error.no_output")
  end
  local extra = {}
  for _, src in ipairs(cur.sources) do
    if not cur.text:find(src, 1, true) then extra[#extra + 1] = "- " .. utf8_cut(src, 120) end
  end
  if #extra > 0 then
    body = body .. "\n\n" .. tr("card.sources") .. "\n" .. table.concat(extra, "\n")
  end
  return body
end

local function card_subtitle()
  local parts = { model_label() }
  if cur.incognito then parts[#parts + 1] = tr("card.incognito") end
  if cur.web then parts[#parts + 1] = tr("card.web_used") end
  if cur.workdir_fallback then parts[#parts + 1] = tr("warn.workdir") end
  if cur.status == "thinking" then
    parts[#parts + 1] = cur.tool and tr("card.tool", { tool = cur.tool }) or tr("card.streaming")
  elseif cur.status == "done" then
    if cur.incognito then
      parts[#parts + 1] = tr("card.enter_copy")
    elseif cur.sid then
      local key = cur.web and "card.continue_manual" or "card.continue"
      parts[#parts + 1] = tr(key, { target = target_label() })
    else
      parts[#parts + 1] = tr("card.done")
    end
  else
    parts[#parts + 1] = tr("card.error")
  end
  return table.concat(parts, " · ")
end

local function detail_row()
  return { id = "open", title = card_body(), subtitle = card_subtitle(), glyph = "sparkles", presentation = "detail" }
end

local function push(force)
  if cur == nil then return end
  local now = noctalia.nowMs and noctalia.nowMs() or 0
  if not force and now ~= 0 and now - last_push < PUSH_EVERY_MS then return end
  last_push = now
  launcher.setResults(cur.key, { detail_row() })
end

local function fail(text)
  text = trim(sanitize(tostring(text or "")))
  if text == "" then text = tr("error.unknown") end
  if is_auth_error(text) then text = tr("error.auth") end
  cur.status = "error"
  cur.err = text
end

local function is_web_tool(name)
  local n = tostring(name or ""):lower()
  return n == "websearch" or n == "webfetch" or n == "web_search" or n == "web_fetch"
end

local function add_source(block)
  local input = type(block.input) == "table" and block.input or {}
  local src = input.url
  if type(src) ~= "string" or src == "" or #cur.sources >= MAX_SOURCES then return end
  src = sanitize(src)
  for _, s in ipairs(cur.sources) do
    if s == src then return end
  end
  cur.sources[#cur.sources + 1] = src
end

local function remember()
  if cur.incognito or cur.sid == nil or cur.text == "" then return end
  local text = cur.text
  if ulen(text) > MAX_CARD_CHARS then text = utf8_cut(text, MAX_CARD_CHARS) end
  local entry = {
    q = cur.q, prompt = cur.prompt, text = text, sid = cur.sid,
    web = cur.web, sources = cur.sources, at = noctalia.formatTime("%d.%m %H:%M"),
  }
  local list = { entry }
  for _, e in ipairs(history) do
    if e.q ~= entry.q and #list < HISTORY_MAX then list[#list + 1] = e end
  end
  history = list
  save_history()
end

local function on_line(g, line)
  if cur == nil or cur.gen ~= g then return end
  local ok, msg = pcall(noctalia.json.decode, line)
  if not ok or type(msg) ~= "table" then
    if line:match("%S") then cur.raw = line end
    return
  end
  local t = msg.type
  if t == "system" then
    if msg.subtype == "init" and type(msg.session_id) == "string" then
      cur.sid = msg.session_id
    end
  elseif t == "assistant" then
    local content = type(msg.message) == "table" and msg.message.content
    if type(content) == "table" then
      for _, block in ipairs(content) do
        if type(block) == "table" and (block.type == "tool_use" or block.type == "server_tool_use")
            and is_web_tool(block.name) then
          cur.web = true
          add_source(block)
        end
      end
    end
  elseif t == "stream_event" and cur.status == "thinking" then
    local ev = msg.event
    if type(ev) ~= "table" then return end
    if ev.type == "content_block_start" and type(ev.content_block) == "table" then
      local block = ev.content_block
      if block.type == "tool_use" or block.type == "server_tool_use" then
        cur.tool = sanitize(tostring(block.name or "tool"))
        if is_web_tool(block.name) then cur.web = true end
        push(true)
      elseif block.type == "text" then
        cur.tool = nil
        if cur.text ~= "" then cur.text ..= "\n\n" end
      end
    elseif ev.type == "content_block_delta" and type(ev.delta) == "table"
        and ev.delta.type == "text_delta" and type(ev.delta.text) == "string" then
      cur.text ..= ev.delta.text
      push(false)
    end
  elseif t == "result" then
    if type(msg.session_id) == "string" then cur.sid = msg.session_id end
    if msg.is_error == true or (msg.subtype and msg.subtype ~= "success") then
      fail(type(msg.result) == "string" and msg.result or cur.raw)
    else
      if type(msg.result) == "string" and msg.result ~= "" then cur.text = msg.result end
      cur.status = "done"
      cur.tool = nil
      remember()
    end
    push(true)
  elseif t == "__exit_" .. cur.nonce then
    if cur.status == "thinking" then
      local code = tonumber(msg.code) or -1
      if code == 124 then
        fail(tr("error.timeout", { seconds = tostring(cfg("timeout_s", 120)) }))
      elseif code == 0 and cur.text ~= "" then
        cur.status = "done"
        remember()
      else
        fail(cur.raw or tr("error.exit", { code = tostring(code) }))
      end
      push(true)
    end
  end
end

local function build_cmd(prompt_file, dir)
  local args = {
    helper("ask"),
    prompt_file,
    dir,
    tostring(math.floor(tonumber(cfg("timeout_s", 120)) or 120)),
    tostring(math.floor(tonumber(cfg("max_turns", 8)) or 8)),
    cfg("model", "sonnet"),
    cfg("tools", "web"),
    cur.nonce,
    cur.incognito and "1" or "0",
    trim(tostring(cfg("extra_prompt", ""))),
  }
  local quoted = {}
  for i, a in ipairs(args) do quoted[i] = shq(a) end
  return "exec " .. table.concat(quoted, " ")
end

local function start(raw)
  local q = trim(raw)
  local incognito = q:sub(1, 1) == "!"
  local prompt = incognito and trim(q:sub(2)) or q
  gen += 1
  cur = {
    gen = gen, key = raw, q = q, prompt = prompt, incognito = incognito,
    text = "", status = "thinking", web = false, sources = {},
    nonce = tostring(gen) .. tostring(noctalia.nowMs and noctalia.nowMs() or 0) .. tostring(math.random(100000, 999999)),
  }
  local dir, fallback = workdir()
  cur.workdir_fallback = fallback

  if ulen(prompt) > MAX_PROMPT_CHARS then
    fail(tr("error.too_long", { max = tostring(MAX_PROMPT_CHARS) }))
  elseif claude_cmd() == nil then
    fail(tr("error.no_claude"))
  else
    local rdir = runtime_dir()
    noctalia.mkdirAll(rdir)
    local prompt_file = rdir .. "/prompt-" .. cur.nonce
    if not noctalia.writeFile(prompt_file, prompt) then
      fail(tr("error.spawn"))
    else
      local g = gen
      local ok = noctalia.runStream(build_cmd(prompt_file, dir), function(line) on_line(g, line) end)
      if not ok then
        noctalia.removeFile(prompt_file)
        fail(tr("error.spawn"))
      end
    end
  end
  launcher.setQuery(raw)
  launcher.setResults(raw, { detail_row() })
end

local function answer_text() return clean_text(cur.text) end

local function copy_answer()
  noctalia.copyToClipboard(answer_text(), "text/plain")
end

local SID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function in_terminal(dir, cmd)
  if not noctalia.runInTerminal("cd " .. shq(dir) .. " && exec " .. cmd) then
    noctalia.notifyError(tr("launcher.ask"), tr("error.no_terminal"))
  end
end

local function open_session()
  local dir = workdir()
  local sid, web = cur.sid, cur.web
  if type(sid) ~= "string" or not sid:match(SID_PATTERN) then return end
  local resume = shq(claude_cmd() or "claude") .. " --resume " .. shq(sid) .. (web and " --permission-mode default" or "")
  local t = target()
  if t == "terminal" then
    in_terminal(dir, resume)
    return
  end
  noctalia.runAsync({
    helper("resume"), t, sid, dir, utf8_cut(cur.prompt, 30), web and "1" or "0",
  }, function(r)
    if r.exitCode == 3 then
      in_terminal(dir, resume)
    elseif r.exitCode == 4 and trim(r.stdout) ~= "" then
      in_terminal(dir, trim(r.stdout)) -- already quoted by bin/resume
    elseif r.exitCode ~= 0 then
      noctalia.notifyError(tr("launcher.ask"), trim(r.stderr) ~= "" and trim(r.stderr) or tr("error.unknown"))
    end
  end, 15000)
end

local function restore(e)
  if cur ~= nil and cur.status == "thinking" then
    noctalia.runAsync({ helper("ask"), "--cancel" })
  end
  gen += 1
  cur = {
    gen = gen, key = e.q, q = e.q, prompt = e.prompt or e.q, incognito = false,
    text = e.text, status = "done", sid = type(e.sid) == "string" and e.sid or nil,
    web = e.web == true, sources = type(e.sources) == "table" and e.sources or {}, nonce = "",
  }
end

local function stay_on_card()
  launcher.setQuery(cur.key)
  launcher.setResults(cur.key, { detail_row() })
end

function onQuery(text)
  local q = trim(text)
  if cur ~= nil and q ~= "" and q == cur.q then
    cur.key = text
    launcher.setResults(text, { detail_row() })
    return
  end
  if q == "" then
    local rows = {
      { id = "_hint", title = tr("launcher.hint_title"), subtitle = tr("launcher.hint_sub"), glyph = "sparkles" },
    }
    if cur ~= nil then
      local in_history = history[1] ~= nil and history[1].q == cur.q and cur.status == "done" and not cur.incognito
      if not in_history then
        rows[#rows + 1] = { id = "_last", title = tr("launcher.last"), subtitle = cur.prompt, glyph = "message-dots", query = cur.q }
      end
      if cur.status == "done" and cur.text ~= "" then
        rows[#rows + 1] = { id = "_copy", title = tr("launcher.copy"), subtitle = utf8_cut(answer_text(), 80), glyph = "copy" }
      end
    end
    for _, e in ipairs(history) do
      local first = clean_text(e.text):match("^%s*([^\n]+)") or ""
      rows[#rows + 1] = {
        id = "h:" .. e.q,
        title = e.prompt or e.q,
        subtitle = (e.at or "") .. " · " .. utf8_cut(first, 70),
        glyph = "history",
      }
    end
    launcher.setResults(text, rows)
    return
  end
  local incognito = q:sub(1, 1) == "!"
  local prompt = incognito and trim(q:sub(2)) or q
  if prompt == "" then
    launcher.setResults(text, {
      { id = "_hint", title = tr("launcher.ask_incognito"), subtitle = tr("launcher.hint_sub"), glyph = "eye-off" },
    })
    return
  end
  launcher.setResults(text, {
    {
      id = "ask:" .. text,
      title = tr(incognito and "launcher.ask_incognito" or "launcher.ask"),
      subtitle = prompt,
      glyph = incognito and "eye-off" or "sparkles",
      score = GLOBAL_SCORE,
    },
  })
end

function onActivate(id)
  if id == "open" then
    if cur == nil then return end
    if cur.status ~= "done" then
      stay_on_card()
      return
    end
    if cur.incognito then
      copy_answer()
      return
    end
    if cur.sid == nil then
      stay_on_card()
      return
    end
    open_session()
    return
  end
  if id == "_copy" then
    if cur ~= nil then copy_answer() end
    return
  end
  if id == "_hint" then
    launcher.setQuery("")
    return
  end
  local hq = id:match("^h:(.*)$")
  if hq ~= nil then
    for _, e in ipairs(history) do
      if e.q == hq then
        restore(e)
        stay_on_card()
        return
      end
    end
    launcher.setQuery("")
    return
  end
  local raw = id:match("^ask:(.*)$")
  if raw ~= nil then
    local q = trim(raw)
    if q ~= "" and q ~= "!" then start(raw) end
  end
end

function onExit()
  noctalia.runAsync({ helper("ask"), "--cancel" })
end
