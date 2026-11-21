--!nonstrict
-- "Try" on the Outputs page: save display edits right away (Umbriel applies the file it watches), then keep them
-- or go back. Without an answer within SECONDS (a display that shows nothing), the backup the save took is
-- restored and the edits are pending again, also when the panel was closed meanwhile (the store outlives it).
-- The helper starts a watcher before it writes anything (umbriel_core/trial.py) that restores the backup a little
-- later unless Keep or Go back ended the trial first, so the rollback never depends on these callbacks.
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
      if change.unset then store.unsetField(fid, change.follow) else store.setField(fid, change.value, change.follow) end
    end
  end)
end

local function tell(ctx, text, kind) ctx.tell(text, kind) end

-- The tried file is gone again (or the trial ended without the panel): load `state` (read it first when nil),
-- queue the tried edits again and tell the user.
local function ended(ctx, attempt, state, text, kind)
  local store, view = ctx.store, ctx.view
  if view.tryState == attempt then view.tryState = nil end
  local function finish(loaded)
    if loaded and store.state and store.state.path == attempt.path then
      store.load(loaded)
      reapply(store, attempt.edits)
      drafts.save()
      ctx.publishPending()
      if ctx.isOpen() then ctx.resetInputs() end
      text = text .. " Your display edits are unsaved again."
    end
    tell(ctx, text, kind)
  end
  if state then finish(state); return end
  ctx.helper.call("read", { config = attempt.path }, function(err, data) finish(not err and data or nil) end,
                  { always = true })
end

local function revert(ctx, attempt, why)
  attempt.phase = "reverting"
  if ctx.isOpen() then ctx.render() end
  ctx.helper.call("restore", { config = attempt.path, snapshot = attempt.backup, revision = attempt.revision,
                               validate = false, trial = attempt.trial }, function(err, data)
    if err and err.code == "trial_over" then  -- the watcher acted first
      ended(ctx, attempt, nil, err.error, "info")
    elseif err then
      if ctx.view.tryState == attempt then ctx.view.tryState = nil end
      tell(ctx, "Could not restore the previous display settings: " .. err.error .. " Restore them from Backups.",
           "error")
    else
      ended(ctx, attempt, data.state, why .. " The previous display settings are back.", "info")
    end
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
    if ctx.isOpen() then ctx.render() end
    tick(ctx, attempt)
  end, { always = true })
end

local function start(ctx)
  local store, view = ctx.store, ctx.view
  local attempt = { phase = "saving", path = store.state.path,
                    edits = { ops = store.deepCopy(store.entryOps), fields = store.deepCopy(store.fieldChanges) } }
  view.tryState = attempt
  ctx.saving = true
  local mark = store.saveMark()
  ctx.render()
  -- also answered after the panel closed, so the countdown starts and the card never stays at "Applying"
  ctx.helper.call("save", { config = attempt.path, changes = store.changeSet(), validate = true, trial = SECONDS },
                  function(err, report)
    ctx.savingDone()
    local function stop(text, kind)
      if view.tryState == attempt then view.tryState = nil end
      tell(ctx, text, kind or "error")
    end
    if err then stop("Could not try the display settings: " .. err.error); return end
    if not report.saved then stop("Umbriel rejected these display settings, so nothing changed."); return end
    if report.changed == false then
      if report.state then store.markSaved(report.state, mark) end
      ctx.publishPending()
      stop("Nothing to try: the file already has these display settings.", "info")
      return
    end
    if not report.state or not report.backup then
      if ctx.isOpen() then ctx.reload() end
      stop("Saved, but the file could not be read back, so they can't be undone here. Use Backups.", "warning")
      return
    end
    store.markSaved(report.state, mark)
    drafts.save()
    ctx.publishPending()
    attempt.phase, attempt.left = "confirm", SECONDS
    attempt.backup, attempt.revision, attempt.trial = report.backup, report.state.revision, report.trial
    if ctx.isOpen() then
      ctx.resetInputs()
      ctx.render()
    end
    tick(ctx, attempt)
  end, { timeout = 60000, always = true })
end

local function keep(ctx, attempt)
  ctx.view.tryState = nil
  ctx.render()
  if not attempt.trial then
    ctx.flash("Display settings kept.", "info")
    return
  end
  ctx.helper.call("trial-end", { config = attempt.path, trial = attempt.trial }, function(err, data)
    if err then
      tell(ctx, "Could not stop the automatic rollback (" .. err.error .. "), so the previous display settings "
        .. "come back in a few seconds.", "error")
    elseif data.ended then
      tell(ctx, "Display settings kept.", "info")
    else  -- the watcher acted first
      ended(ctx, attempt, nil, "Too late: " .. (data.message or "this Try already ended."), "warning")
    end
  end, { always = true })
end

-- Whether a Try is running (saving, waiting for an answer or going back); Save waits for it.
function M.running(ctx) return ctx.view.tryState ~= nil end

-- The "Try" button for the display tools row.
function M.button(ctx)
  local store = ctx.store
  return ui.button({ key = "display-try", text = "Try", glyph = "player-play", variant = "outline",
                     enabled = ctx.view.tryState == nil and not ctx.saving and available(store),
                     tooltip = "Save the display changes now and keep them only if you confirm within "
                       .. SECONDS .. " seconds", onClick = function() start(ctx) end })
end

-- The confirm card while a try runs (nil otherwise); the shell shows it above every page.
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
      keep(ctx, attempt)
    end }),
    ui.button({ key = "display-try-revert", text = "Go back", glyph = "arrow-back-up", variant = "outline",
                onClick = function() revert(ctx, attempt, "Went back.") end }),
  })
end

return M
