-- Archive behaviour for the Sticky Notes service and panel.

local servicePath = assert(arg[1], "expected transformed service path")
local panelPath = assert(arg[2], "expected transformed panel path")
local testDir = assert(arg[3], "expected tests directory")

local harnessLib = dofile(testDir .. "/harness.lua")
local harness = function(options) return harnessLib.new(servicePath, panelPath, options) end

-- Notes in a saved Markdown file are separated by a `---` line.
local function mdNote(index, id, content)
  return string.format(
    '## Note %d\n\n<!-- sticky-notes {"id":"%s","color":"yellow","createdAt":%d,"pinned":false,"blurred":false} -->\n\n%s\n',
    index, id, index, content
  )
end

local function mdFile(...)
  return table.concat({ ... }, "\n---\n\n")
end

local tests = {}

-- -------------------------------------------------------------------------
-- Service
-- -------------------------------------------------------------------------

function tests.archiving_a_note_moves_it_out_of_the_active_list()
  local h = harness()
  h.cmd({ op = "archive", id = "saved" })
  assert(#h.notes() == 0, "archived note should leave the active list")
  local archived = h.archived() or {}
  assert(#archived == 1 and archived[1].id == "saved", "archived note should appear in the archive list")
  assert(archived[1].content == "Keep this note", "archive must keep the note text")
end

function tests.archived_notes_survive_a_reload_in_every_format()
  local fixtures = {
    md = harnessLib.saved,
    json = '{"notes":[{"id":"saved","content":"Keep this note","color":"pink","createdAt":1,"pinned":true,"blurred":false}]}',
    txt = "[Note 1 | id:saved color:pink pinned:true blurred:false]\nKeep this note",
  }
  for format, fixture in pairs(fixtures) do
    local h = harness({ format = format, raw = fixture })
    h.cmd({ op = "archive", id = "saved" })
    local reloaded = harness({ format = format, raw = h.raw() })
    assert(#reloaded.notes() == 0, format .. ": a reloaded archived note must stay out of the active list")
    local archived = reloaded.archived() or {}
    assert(#archived == 1 and archived[1].id == "saved",
      format .. ": a reloaded archived note must stay in the archive list")
    assert(archived[1].content == "Keep this note", format .. ": archive must keep the note text")
  end
end

-- Guard for the parse fallbacks: files written before archives existed must
-- still load as active notes with their pin and blur flags intact.
function tests.files_without_archive_flags_still_load_as_active_notes()
  local h = harness({ format = "txt", raw = "[Note 1 | id:saved color:pink pinned:true blurred:false]\nKeep this note" })
  assert(#h.notes() == 1 and h.notes()[1].id == "saved", "a file written before archives must load as an active note")
  assert(h.notes()[1].pinned == true and h.notes()[1].blurred == false, "existing flags must survive the new format")
  assert(#(h.archived() or {}) == 0, "an old file has no archived notes")
end

function tests.archive_list_leads_with_the_most_recently_archived_note()
  local h = harness({ raw = mdFile(mdNote(1, "first", "First note"), mdNote(2, "second", "Second note")) })
  h.cmd({ op = "archive", id = "first" })
  h.cmd({ op = "archive", id = "second" })
  local archived = h.archived() or {}
  assert(#archived == 2 and archived[1].id == "second" and archived[2].id == "first",
    "the most recently archived note should lead the archive list")
  assert(#h.notes() == 0, "both notes should leave the active list")
end

function tests.restoring_a_note_returns_it_to_the_active_list()
  local h = harness()
  h.cmd({ op = "archive", id = "saved" })
  h.cmd({ op = "unarchive", id = "saved" })
  assert(#(h.archived() or {}) == 0, "a restored note should leave the archive list")
  assert(#h.notes() == 1 and h.notes()[1].id == "saved", "a restored note should return to the active list")
  assert(h.notes()[1].content == "Keep this note", "restoring must keep the note text")
  assert(h.notes()[1].pinned == false, "a restored note should not come back pinned")
end

function tests.restored_notes_land_at_the_top_of_the_unpinned_group()
  local h = harness({ raw = mdFile(mdNote(1, "pinned-one", "Pinned note"), mdNote(2, "second", "Second note")) })
  h.cmd({ op = "toggle_pin", id = "pinned-one" })
  h.cmd({ op = "archive", id = "second" })
  h.cmd({ op = "unarchive", id = "second" })
  assert(#h.notes() == 2 and h.notes()[1].id == "pinned-one",
    "the pinned note should stay above the restored note")
  assert(h.notes()[2].id == "second" and h.notes()[2].pinned == false,
    "the restored note should lead the unpinned group")
end

function tests.deleting_an_archived_note_removes_it_permanently()
  local h = harness()
  h.cmd({ op = "archive", id = "saved" })
  h.cmd({ op = "remove", id = "saved" })
  assert(#(h.archived() or {}) == 0, "the deleted note should leave the archive list")
  assert(#h.notes() == 0, "the deleted note should not return to the active list")
  assert(h.raw():find("Keep this note", 1, true) == nil, "the notes file must not keep the deleted note")
end

function tests.archiving_a_blank_note_discards_it()
  local h = harness({ raw = harnessLib.empty })
  h.cmd({ op = "archive", id = "empty" })
  assert(#h.notes() == 0, "a blank note should not stay in the active list")
  assert(#(h.archived() or {}) == 0, "a blank note has nothing to archive")
end

-- The read-only rule is also the service's contract: a panel (or any other
-- caller) must not be able to change an archived note through the commands
-- that edit active notes.
function tests.archived_notes_ignore_edit_commands()
  local h = harness()
  h.cmd({ op = "archive", id = "saved" })
  local writes = h.writes
  h.cmd({ op = "update", id = "saved", content = "Changed", color = "blue" })
  h.cmd({ op = "toggle_pin", id = "saved" })
  h.cmd({ op = "move", id = "saved", group = "u", index = 1 })
  h.cmd({ op = "toggle_note_blur", id = "saved" })
  local archived = h.archived() or {}
  assert(#archived == 1 and archived[1].content == "Keep this note" and archived[1].color == "pink",
    "edit commands must not change an archived note")
  assert(archived[1].pinned == false and archived[1].blurred == true,
    "an archived note should keep the flags it was archived with")
  assert(h.writes == writes, "ignored edit commands must not rewrite the notes file")
end

-- -------------------------------------------------------------------------
-- Panel
-- -------------------------------------------------------------------------

local function archivedSection(id, content, blurred)
  return string.format(
    '## Note 9\n\n<!-- sticky-notes {"id":"%s","color":"blue","createdAt":9,"pinned":false,"blurred":%s,"archived":true} -->\n\n%s\n',
    id, blurred and "true" or "false", content
  )
end

-- A saved note with one archived sibling, opened in the panel's list view.
local function panelHarness(archivedNote)
  local h = harness({ raw = harnessLib.saved .. "\n---\n\n" .. (archivedNote or archivedSection("old", "Old reference")) })
  h.loadPanel(); h.panel.onOpen(""); h.flush()
  return h
end

local function clickTooltip(h, tooltip)
  local button = assert(h.find(function(node) return node.props.tooltip == tooltip end),
    "expected a control with tooltip " .. tooltip)
  button.props.onClick()
  h.flush()
end

local function openArchive(h) clickTooltip(h, "panel.archived-tooltip") end
local function card(h, id) return h.find(function(node) return node.props.key == "card-" .. id end) end

function tests.panel_archive_view_lists_only_archived_notes_and_goes_back()
  local h = panelHarness()
  assert(card(h, "saved") ~= nil, "the active note should be listed before opening the archive")
  openArchive(h)
  assert(card(h, "old") ~= nil, "the archive view should list archived notes")
  assert(card(h, "saved") == nil, "the archive view should not list active notes")
  assert(h.find(function(node) return node.props.text == "panel.archived-title" end) ~= nil,
    "the archive view should say which list is open")
  clickTooltip(h, "panel.back")
  assert(card(h, "saved") ~= nil and card(h, "old") == nil, "the back control should return to the notes list")
  assert(h.find(function(node) return node.props.text == "panel.title" end) ~= nil,
    "the notes list should restore its title")
end

function tests.archived_cards_offer_only_restore_and_delete()
  local h = panelHarness()
  openArchive(h)
  local archivedCard = assert(card(h, "old"), "expected the archived card")
  assert(archivedCard.props.onClick == nil, "an archived card must not open the editor")
  assert(h.find(function(node) return node.props.tooltip == "panel.restore" end) ~= nil,
    "an archived card should offer restoring")
  assert(h.find(function(node) return node.props.tooltip == "panel.delete" end) ~= nil,
    "an archived card should still be deletable")
  assert(h.find(function(node) return node.props.tooltip == "panel.edit" end) == nil,
    "archived notes must not be editable")
  assert(h.find(function(node) return node.props.tooltip == "panel.pin" end) == nil,
    "archived notes must not be pinnable")
  assert(h.find(function(node) return node.props.tooltip == "panel.blur-note" end) == nil,
    "archived notes must not be blurred per note")
  assert(h.find(function(node) return node.props.dragType == "sticky-notes-note" end) == nil,
    "archived notes must not be draggable")
  assert(h.find(function(node) return node.kind == "dropZone" end) == nil,
    "the archive must not offer reorder drop zones")
  assert(h.find(function(node) return node.props.tooltip == "panel.add" end) == nil,
    "the archive view should not offer adding a note")
  assert(not h.input(), "the archive view must not render the editor")
end

function tests.archiving_from_the_list_removes_the_note()
  local h = panelHarness()
  clickTooltip(h, "panel.archive")
  assert(card(h, "saved") == nil, "the archived note should leave the notes list")
  assert(#h.notes() == 0, "the archived note should leave the active list")
  local archived = h.archived() or {}
  assert(#archived == 2 and archived[1].id == "saved",
    "the newly archived note should join the archive list above the older one")
end

function tests.restoring_from_the_archive_returns_the_note_to_the_list()
  local h = panelHarness()
  openArchive(h)
  clickTooltip(h, "panel.restore")
  assert(#h.archived() == 0 and #h.notes() == 2, "restoring should move the note back to the active list")
  assert(h.find(function(node) return node.props.text == "panel.empty-archive" end) ~= nil,
    "an emptied archive should explain that it is empty")
end

function tests.archived_previews_respect_privacy()
  local h = panelHarness(archivedSection("old", "Old reference", true))
  openArchive(h)
  assert(h.find(function(node) return node.props.text == "panel.blurred-hint" end) ~= nil,
    "a blurred archived note should hide its text")
  assert(h.find(function(node) return node.props.text == "Old reference" end) == nil,
    "a blurred archived note must not expose its text")
  clickTooltip(h, "panel.blur")
  assert(h.find(function(node) return node.props.text == "panel.all-blurred-hint" end) ~= nil,
    "hiding all notes should hide archived previews too")
end

local count = 0
for name, test in pairs(tests) do
  test()
  count = count + 1
  print("PASS " .. name)
end
print(string.format("Sticky Notes archive: %d tests passed", count))
