local servicePath = assert(arg[1], "expected transformed service path")
local panelPath = assert(arg[2], "expected transformed panel path")

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

-- Test JSON metadata contains only scalars. Keep real Markdown fixtures and
-- serialized metadata, rather than substituting the persistence functions.
local function encode(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) ~= "table" then return tostring(value) end
  local parts = {}
  for k, v in pairs(value) do parts[#parts + 1] = encode(k) .. ":" .. encode(v) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function decode(value)
  local chunk = load("return " .. value:gsub('"([%w_]+)":', '["%1"]='), "metadata", "t", {})
  return chunk and chunk() or nil
end

local saved = '## Note 1\n\n<!-- sticky-notes {"id":"saved","color":"pink","createdAt":1,"pinned":true,"blurred":true} -->\n\nKeep this note\n'
local empty = '\n---\n\n## Note 2\n\n<!-- sticky-notes {"id":"empty","color":"blue","createdAt":2,"pinned":false,"blurred":false} -->\n\n\n'

local function harness(options)
  options = options or {}
  local h = { state = {}, watchers = {}, queue = {}, processes = {}, writes = 0, open = false }
  local raw = options.raw or saved
  local clock = 1789200000000
  local function enqueue(fn) h.queue[#h.queue + 1] = fn end
  local function set(key, value)
    h.state[key] = copy(value)
    for _, fn in ipairs(h.watchers[key] or {}) do
      local snapshot = copy(value)
      enqueue(function() fn(snapshot) end)
    end
  end
  local function watch(key, fn)
    h.watchers[key] = h.watchers[key] or {}
    table.insert(h.watchers[key], fn)
  end
  function h.flush()
    local calls = 0
    while #h.queue > 0 do
      calls = calls + 1
      assert(calls < 500, "state callbacks should settle")
      table.remove(h.queue, 1)()
    end
  end
  function h.step() assert(#h.queue > 0, "expected a pending host callback"); table.remove(h.queue, 1)() end
  local config = { save_path = "/notes", file_format = "md", default_color = "green", auto_blur = options.autoBlur }
  local function runAsync(argv, callback)
    h.processes[#h.processes + 1] = copy(argv)
    if argv[1] == "sh" then
      h.finishHome = function() callback({ stdout = "/home/test" }) end
      if not options.delayed then enqueue(h.finishHome) end
    elseif argv[1] == "mkdir" then
      enqueue(function() callback({ exitCode = 0 }) end)
    elseif argv[1] == "noctalia" then
      assert(table.concat(argv, " ") == "noctalia msg panel-open ahmedhossamdev/sticky-notes:panel new-note",
        "quick capture must open the panel with context, without toggling it closed")
      enqueue(function()
        h.loadPanel()
        h.open = true
        h.panel.onOpen(argv[5])
        if callback then callback({ exitCode = 0, stdout = "ok\n" }) end
      end)
    else
      error("unexpected process: " .. argv[1])
    end
    return true
  end
  local api = {
    state = { set = set, get = function(key) return copy(h.state[key]) end, watch = watch },
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    json = { encode = encode, decode = decode },
    getConfig = function(key) return config[key] end,
    setUpdateInterval = function() end,
    nowMs = function() clock = clock + 1; return clock end,
    pluginDataDir = function() return "/data" end,
    readFile = function(path) assert(path == "/notes/notes.md"); return raw end,
    writeFile = function(path, data)
      assert(path == "/notes/notes.md")
      raw = data; h.writes = h.writes + 1; return true
    end,
    tr = function(key) return key end,
    focusedOutputName = function() return "test-output" end,
  }
  api.runAsync = runAsync
  h.service = setmetatable({ noctalia = api }, { __index = _G })
  assert(loadfile(servicePath, "t", h.service))()
  function h.loadPanel()
    if h.panel then return end
    local ui = setmetatable({}, { __index = function(_, kind)
      return function(props, children) return { kind = kind, props = props or {}, children = children or {} } end
    end })
    local palette = { refresh = function() end, setOnChanged = function() end }
    h.panel = setmetatable({
      noctalia = api, ui = ui,
      require = function(name) assert(name == "./palette.luau"); return palette end,
      panel = { render = function(tree) h.tree = tree end, close = function() h.open = false; h.panel.onClose() end },
    }, { __index = _G })
    assert(loadfile(panelPath, "t", h.panel))()
  end
  function h.find(predicate)
    local function visit(node)
      if not node then return end
      if predicate(node) then return node end
      for _, child in ipairs(node.children) do
        local found = visit(child)
        if found then return found end
      end
    end
    return visit(h.tree)
  end
  function h.input() return h.find(function(node) return node.kind == "input" end) end
  function h.ipc(event)
    assert(type(h.service.onIpc) == "function", "service should expose the public new-note IPC event")
    h.service.onIpc(event or "new-note", nil)
    h.flush()
  end
  function h.notes() return h.state["sticky_notes.notes"] end
  function h.raw() return raw end
  h.flush()
  return h
end

local tests = {}
function tests.closed_panel_creates_and_focuses_note()
  local h = harness()
  h.ipc()
  assert(h.open, "IPC should open the panel")
  assert(#h.notes() == 2, "IPC should add one note")
  assert(h.notes()[1].id == "saved" and h.notes()[1].content == "Keep this note", "saved pinned note must survive")
  assert(h.notes()[1].blurred == true, "existing note privacy must survive")
  assert(h.notes()[2].color == "green", "new note should use the configured default color")
  assert(h.input() and h.input().props.value == "" and h.input().props.focus == true,
    "new note editor should grab keyboard focus")
  h.input().props.onChange("New capture")
  h.panel.onClose(); h.flush()
  assert(h.notes()[2].content == "New capture" and h.raw():find("New capture", 1, true), "closing should persist the capture")
end

function tests.existing_empty_note_is_reused()
  local h = harness({ raw = saved .. empty })
  h.ipc()
  assert(#h.notes() == 2 and h.notes()[2].id == "empty", "reuse the existing empty note")
  assert(h.input().props.key:find("inp-empty-", 1, true), "edit the reused empty note")
end

function tests.repeated_ipc_refocuses_without_duplicate_notes()
  local h = harness()
  h.ipc()
  local id, key = h.notes()[2].id, h.input().props.key
  h.ipc()
  assert(h.open and #h.notes() == 2 and h.notes()[2].id == id, "repeated shortcut should keep the panel open and reuse its empty note")
  assert(h.input().props.key ~= key and h.input().props.focus == true, "repeated shortcut should recreate the input to restore focus")
end

function tests.rapid_repeat_acknowledgements_preserve_newly_typed_text()
  local h = harness()
  h.ipc()
  h.service.onIpc("new-note", nil)
  h.service.onIpc("new-note", nil)
  h.step(); h.step()
  while not h.input() do h.step() end
  h.input().props.onChange("Typed between acknowledgements")
  h.flush()
  h.panel.onClose(); h.flush()
  assert(#h.notes() == 2 and h.raw():find("Typed between acknowledgements", 1, true),
    "a repeated acknowledgement for the same editor must not discard its live text")
end

function tests.rapid_repeat_does_not_toggle_auto_blur_off()
  local h = harness({ autoBlur = true })
  h.ipc()
  local unblur = assert(h.find(function(node) return node.props.tooltip == "panel.unblur" end))
  unblur.props.onClick(); h.flush()
  assert(h.state["sticky_notes.blurred"] == false)
  h.service.onIpc("new-note", nil)
  h.service.onIpc("new-note", nil)
  h.flush()
  assert(h.state["sticky_notes.blurred"] == true, "rapid shortcuts should enable auto blur once, never toggle it back off")
end

function tests.open_draft_is_saved_before_new_note()
  local h = harness()
  h.ipc()
  local id = h.notes()[2].id
  h.input().props.onChange("Unfinished draft")
  h.ipc()
  assert(#h.notes() == 3, "a nonempty draft should permit a new note")
  local found = false
  for _, note in ipairs(h.notes()) do
    if note.id == id then found = note.content == "Unfinished draft" end
  end
  assert(found and h.raw():find("Unfinished draft", 1, true), "shortcut must persist the open draft before switching editors")
  assert(h.input().props.value == "", "the new editor should be empty")
end

function tests.clearing_an_existing_draft_is_saved_before_capture()
  local visible = saved:gsub('"blurred":true', '"blurred":false')
  local h = harness({ raw = visible })
  h.loadPanel(); h.panel.onOpen(""); h.flush()
  local edit = assert(h.find(function(node) return node.props.tooltip == "panel.edit" end))
  edit.props.onClick()
  h.input().props.onChange("   ")
  h.ipc()
  assert(#h.notes() == 1 and h.notes()[1].id ~= "saved",
    "clearing an existing note should preserve the normal empty-draft deletion behavior")
  assert(not h.raw():find("Keep this note", 1, true), "the cleared draft should not restore old saved text")
  assert(h.input() and h.input().props.value == "", "capture should open a fresh empty editor")
end

function tests.startup_request_waits_for_saved_notes()
  local h = harness({ delayed = true })
  h.ipc()
  assert(h.writes == 0, "IPC during initialization must not overwrite unloaded notes")
  h.finishHome(); h.flush()
  assert(#h.notes() == 2 and h.notes()[1].content == "Keep this note", "initialization should preserve saved notes and honor quick capture")
  assert(h.input() and h.input().props.focus == true, "pending capture should focus after loading")
end

function tests.startup_capture_applies_auto_blur_after_loading()
  local h = harness({ delayed = true, autoBlur = true })
  h.ipc()
  h.finishHome(); h.flush()
  assert(h.state["sticky_notes.blurred"] == true, "loading must not reset auto blur for a pending capture")
  assert(h.input() and h.input().props.value == "", "startup capture should still open the empty editor")
end

function tests.closing_during_startup_cancels_capture()
  local h = harness({ delayed = true })
  h.ipc()
  h.panel.onClose(); h.flush()
  h.finishHome(); h.flush()
  assert(#h.notes() == 1, "closing before the notes load should cancel the pending capture")
end

function tests.closing_before_editor_acknowledgement_removes_new_empty_note()
  local h = harness({ delayed = true })
  h.ipc()
  h.finishHome()
  while not h.notes() or #h.notes() == 1 do h.step() end
  assert(not h.input(), "pause after creation but before the panel receives the new note")
  h.panel.onClose(); h.flush()
  assert(#h.notes() == 1 and h.notes()[1].id == "saved",
    "closing while creation is in flight should remove only the new empty note")
  assert(not h.input(), "a late editor acknowledgement should not open a hidden editor")
end

function tests.closing_before_reuse_acknowledgement_preserves_existing_empty_note()
  local h = harness({ delayed = true, raw = saved .. empty })
  h.ipc()
  h.finishHome()
  while h.state["sticky_notes.edit_note"] == nil do h.step() end
  h.panel.onClose(); h.flush()
  assert(#h.notes() == 2 and h.notes()[2].id == "empty",
    "a cancelled capture should not delete a preexisting empty note before editing begins")
  assert(not h.input(), "cancelled reuse should not open a hidden editor")
end

function tests.auto_blur_keeps_old_notes_private_while_capturing()
  local h = harness({ autoBlur = true })
  h.ipc()
  assert(h.state["sticky_notes.blurred"] == true, "quick capture should retain auto blur")
  assert(h.input() and h.input().props.value == "", "auto blur should allow the requested empty editor")
  h.panel.onClose(); h.flush()
  assert(#h.notes() == 1 and h.notes()[1].blurred == true, "closing an empty capture should remove only the new note")
end

function tests.ordinary_open_does_not_create_a_note()
  local h = harness()
  h.loadPanel(); h.panel.onOpen(""); h.flush()
  assert(#h.notes() == 1 and not h.input(), "ordinary panel opening should stay in the list")
  local add = assert(h.find(function(node) return node.props.tooltip == "panel.add" end))
  add.props.onClick(); h.flush()
  assert(#h.notes() == 2 and h.input(), "the existing plus button should still open a new editor")
end

function tests.unknown_event_does_nothing()
  local h = harness()
  local count = #h.processes
  h.ipc("unknown")
  assert(not h.open and #h.notes() == 1 and h.writes == 0 and #h.processes == count, "unrecognized IPC events should have no effect")
end

local count = 0
for name, test in pairs(tests) do
  test()
  count = count + 1
  print("PASS " .. name)
end
print(string.format("Sticky Notes: %d tests passed", count))
