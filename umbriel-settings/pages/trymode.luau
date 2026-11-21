--!nonstrict
-- "Try" on the Outputs page: save display edits right away (Umbriel applies the file it watches), then keep them
-- or go back. Without an answer within SECONDS (a display that shows nothing), the backup the save took is
-- restored and the edits are pending again. The countdown keeps running when the panel closes.
local kit = require("../ui/kit.luau")
local drafts = require("../lib/drafts.luau")

local M = {}

local SECONDS = 15
local PRIMARY_FIELD = "general.xwayland_primary_output"

-- Whether every pending config edit is a display edit (so trying them saves nothing else).
local function available(store)
  if not store.state or store.keybindsDirty or #store.mapOps > 0 then return false end
  for _, op in ipairs(store.entryOps) do
    if op.editor ~= "output" then return false end
  end
  for fid in pairs(store.fieldChanges) do
    if fid ~= PRIMARY_FIELD then return false end
  end
  return #store.entryOps > 0 or next(store.fieldChanges) ~= nil
end

-- Puts the tried edits back as unsaved changes (one undo step).
local function reapply(store, edits)
  store.group(function()
    for _, op in ipairs(edits.ops) do
      local copy = store.deepCopy(op)
      copy.editor = nil
      store.entryOp(op.editor, copy)
    end
    for fid, change in pairs(edits.fields) do
      if change.unset then store.unsetField(fid) else store.setField(fid, change.value) end
    end
  end)
end

local function revert(ctx, attempt, why)
  local store, view = ctx.store, ctx.view
  attempt.phase = "reverting"
  local closed = ctx.helper.generation ~= attempt.generation
  if not closed then ctx.render() end
  ctx.helper.call("restore", { config = attempt.path, snapshot = attempt.backup, revision = attempt.revision,
                               validate = false }, function(err, data)
    if view.tryState == attempt then view.tryState = nil end
    closed = ctx.helper.generation ~= attempt.generation
    if err then
      local text = "Could not restore the previous display settings: " .. err.error .. " Restore it from Backups."
      if closed then noctalia.notify("Umbriel Settings", text) else ctx.flash(text, "error"); ctx.render() end
      return
    end
    if closed then
      noctalia.notify("Umbriel Settings", why .. " The previous display settings are back.")
      return
    end
    if data.state then store.load(data.state) else ctx.reload() end
    if data.state then reapply(store, attempt.edits) end
    drafts.save()
    ctx.resetInputs()
    ctx.flash(why .. " The previous display settings are back; your edits are unsaved again.", "info")
    ctx.render()
  end, { always = true, timeout = 60000 })
end

local function tick(ctx, attempt)
  ctx.helper.call("wait", { seconds = 1 }, function()
    if ctx.view.tryState ~= attempt or attempt.phase ~= "confirm" then return end
    attempt.left = attempt.left - 1
    if attempt.left <= 0 then
      revert(ctx, attempt, "No answer within " .. SECONDS .. " seconds.")
      return
    end
    if ctx.helper.generation == attempt.generation then ctx.render() end
    tick(ctx, attempt)
  end, { always = true })
end

local function start(ctx)
  local store, view = ctx.store, ctx.view
  local attempt = { phase = "saving", path = store.state.path, generation = ctx.helper.generation,
                    edits = { ops = store.deepCopy(store.entryOps), fields = store.deepCopy(store.fieldChanges) } }
  view.tryState = attempt
  ctx.saving = true
  local mark = store.saveMark()
  ctx.render()
  ctx.helper.call("save", { config = attempt.path, changes = store.changeSet(), validate = true }, function(err, report)
    ctx.savingDone()
    local function stop(text)
      if view.tryState == attempt then view.tryState = nil end
      ctx.flash(text, "error")
      ctx.render()
    end
    if err then stop("Could not try the display settings: " .. err.error); return end
    if not report.saved then stop("Umbriel rejected these display settings, so nothing changed."); return end
    if not report.state or not report.backup then
      if view.tryState == attempt then view.tryState = nil end
      ctx.reload()
      ctx.flash("Saved, but the file could not be read back, so they can't be undone here. Use Backups.", "warning")
      return
    end
    store.markSaved(report.state, mark)
    drafts.save()
    attempt.phase, attempt.left = "confirm", SECONDS
    attempt.backup, attempt.revision = report.backup, report.state.revision
    ctx.resetInputs()
    ctx.render()
    tick(ctx, attempt)
  end, { timeout = 60000 })
end

-- The "Try" button for the display tools row.
function M.button(ctx)
  local store = ctx.store
  return ui.button({ key = "display-try", text = "Try", glyph = "player-play", variant = "outline",
                     enabled = ctx.view.tryState == nil and not ctx.saving and available(store),
                     tooltip = "Save the display changes now and keep them only if you confirm within "
                       .. SECONDS .. " seconds", onClick = function() start(ctx) end })
end

-- The confirm card while a try runs (nil otherwise).
function M.card(ctx)
  local attempt = ctx.view.tryState
  if not attempt then return nil end
  if attempt.phase ~= "confirm" then
    return kit.notice(attempt.phase == "saving" and "Applying the display settings…"
      or "Restoring the previous display settings…", "info", nil, "display-try-busy")
  end
  return ui.row({ key = "display-try-card", gap = 8, align = "center", padding = 10, radius = kit.RADIUS.md,
                  fill = "primary/0.12" }, {
    ui.glyph({ name = "device-desktop-question", size = kit.GLYPH.large, color = "primary" }),
    kit.label("Keep these display settings? Going back in " .. kit.plural(attempt.left, "second") .. ".",
              { flexGrow = 1, maxLines = 2 }),
    ui.button({ key = "display-try-keep", text = "Keep", glyph = "check", variant = "primary", onClick = function()
      ctx.view.tryState = nil
      ctx.flash("Display settings kept.", "info")
      ctx.render()
    end }),
    ui.button({ key = "display-try-revert", text = "Go back", glyph = "arrow-back-up", variant = "outline",
                onClick = function() revert(ctx, attempt, "Went back.") end }),
  })
end

return M
