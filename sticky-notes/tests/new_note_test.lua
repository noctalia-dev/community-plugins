local servicePath = assert(arg[1], "expected transformed service path")
local panelPath = assert(arg[2], "expected transformed panel path")
local testDir = assert(arg[3], "expected tests directory")

local harnessLib = dofile(testDir .. "/harness.lua")
local harness = function(options) return harnessLib.new(servicePath, panelPath, options) end
local saved, empty = harnessLib.saved, harnessLib.empty

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
