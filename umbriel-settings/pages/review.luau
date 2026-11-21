--!nonstrict
-- Review & save (readable changes, diff, validation) and backups.
local kit = require("../ui/kit.luau")
local drafts = require("../lib/drafts.luau")
local format = require("../ui/format.luau")

local M = {}

local DIFF_LINES = 80  -- lines of one section's diff shown: long diffs stay readable and cheap to render

local function diffBlock(text)
  local lines, count = {}, 0
  for line in string.gmatch(text, "[^\n]*\n?") do
    if line == "" then break end
    count = count + 1
    if count <= DIFF_LINES then table.insert(lines, line) end
  end
  local body = table.concat(lines)
  if count > DIFF_LINES then body = body .. "\n… " .. (count - DIFF_LINES) .. " more lines\n" end
  return "```diff\n" .. body .. "```"
end

-- Messages Umbriel's validation attached to settings; shown on their rows until the next check.
local function setDiagnostics(ctx, report)
  ctx.diagnostics = nil
  for _, item in ipairs(report.validation and report.validation.diagnostics or {}) do
    if item.field then
      ctx.diagnostics = ctx.diagnostics or {}
      ctx.diagnostics[item.field] = item.message
    end
  end
end

-- `check`: also validate when nothing changed (the file as it is on disk).
local function requestPreview(ctx, state, check)
  local store = ctx.store
  state.preview, state.error, state.loading = nil, nil, true
  state.previewSeq = (state.previewSeq or 0) + 1
  local seq = state.previewSeq
  if not store.hasConfigChanges() and not check then
    state.loading = false
    state.preview = { changed = false, summary = {}, sections = {}, validation = { ran = false } }
    return
  end
  ctx.helper.call("preview", { config = store.state.path, changes = store.changeSet(), validate = state.validate,
                               check = check == true },
    function(err, report)
      if seq ~= state.previewSeq then return end  -- an answer for options that were changed again since
      state.loading = false
      if not err and report.validation and report.validation.ran then setDiagnostics(ctx, report) end
      if err then state.error = err.error else state.preview = report end
      ctx.render()
    end, { timeout = 45000 })
end

local function stopSaving(ctx, state)
  state.saving = false
  ctx.savingDone()
end

-- "First part. Second part." with either part possibly empty.
local function sentences(first, second) return first ~= "" and (first .. " " .. second) or second end

local function finishSave(ctx, state, message)
  stopSaving(ctx, state)
  ctx.view.titlebar = nil  -- read again: the save may have started or stopped title bars following Noctalia
  ctx.diagnostics = nil
  ctx.resetInputs()
  drafts.save()  -- drops a draft from an earlier close that held what was just saved
  if ctx.route().name == "review" then ctx.back() end  -- the user may have moved on while it saved
  ctx.flash(message, (state.newer or state.warnings) and "warning" or "info")
end

local function saveDesktop(ctx, state, message)
  local store = ctx.store
  local desktop = store.desktopChanges()
  if not desktop then finishSave(ctx, state, message); return end
  -- answered also after the panel closed (always): the files are written either way, so the store must learn it
  ctx.helper.call("desktop-save", desktop, function(err, result)
    local failed = err and err.error or nil
    if not err then  -- each part that was written: only what this save sent is no longer pending
      for _, part in ipairs({ "userdirs", "apps" }) do
        if result[part] then store.desktopSaved(part, result[part].revision, desktop[part]) end
      end
    end
    if not err and result.errors then
      local texts = {}
      for _, text in pairs(result.errors) do table.insert(texts, text) end
      failed = table.concat(texts, " ")
    end
    drafts.save()
    ctx.publishPending()
    if not ctx.isOpen() then
      stopSaving(ctx, state)
      noctalia.notify("Umbriel Settings", failed and sentences(message, "Desktop settings were not saved: " .. failed)
        or sentences(message, "Desktop settings saved after the panel closed; restart apps to use them."))
      return
    end
    if failed then
      stopSaving(ctx, state)
      state.error = sentences(message, "Desktop settings were not saved: " .. failed)
      ctx.render()
      return
    end
    if not store.desktopChanges() then  -- nothing was edited meanwhile: read both files again
      store.desktopSavedAll()
      ctx.loadDesktop(true)
    end
    finishSave(ctx, state, sentences(message, "Desktop settings saved; restart apps to use them."))
  end, { always = true })
end

local function save(ctx, state)
  local store = ctx.store
  state.saving, state.error, state.newer, state.warnings = true, nil, false, nil
  ctx.saving = true  -- external file changes wait until the save is done (shell.onExternalChange)
  ctx.render()
  if not store.hasConfigChanges() then saveDesktop(ctx, state, ""); return end
  local generation = ctx.helper.generation
  local mark, path = store.saveMark(), store.state.path
  -- clears what this save wrote; edits made meanwhile stay pending (false when another config is open now)
  local function saved(report)
    if not store.state or store.state.path ~= path then return false end
    if not report.state then ctx.reload() return false end  -- written but not read back: read it again
    local newer = store.markSaved(report.state, mark)
    drafts.save()
    return newer
  end
  local function extra(report, newer)
    local text = ""
    if report.warnings and #report.warnings > 0 then text = text .. " " .. table.concat(report.warnings, " ") end
    if newer then text = text .. " Edits made while saving are still unsaved." end
    return text
  end
  ctx.helper.call("save", { config = store.state.path, changes = store.changeSet(), validate = state.validate },
    function(err, report)
      if generation ~= ctx.helper.generation then
        ctx.savingDone()
        local note = "Saved after the panel closed."
        if not err and report.saved then  -- saved() also rewrites the draft written on close
          note = note .. extra(report, saved(report))
        end
        if store.desktopChanges() then note = note .. " Folder and app changes are still unsaved." end
        ctx.view.titlebar = nil
        ctx.publishPending()  -- the bar widget would keep showing the old count
        noctalia.notify("Umbriel Settings", err and ("Saving failed: " .. err.error)
          or (report.saved and note or "Not saved: Umbriel rejected the config."))
        return
      end
      if err then
        state.error = err.error
        stopSaving(ctx, state)
        ctx.render()
        return
      end
      if not report.saved then
        stopSaving(ctx, state)
        state.preview = report
        setDiagnostics(ctx, report)
        state.error = "Umbriel rejected the new config, so nothing was written. Fix the problems below."
        ctx.render()
        return
      end
      local newer = saved(report)
      state.newer, state.warnings = newer, report.warnings and #report.warnings > 0 or nil
      local warnings = 0
      for _, item in ipairs(report.validation.diagnostics or {}) do
        if item.severity ~= "error" then warnings = warnings + 1 end
      end
      local message = "Saved" .. (warnings > 0 and (" with " .. kit.plural(warnings, "warning")) or "") .. "."
        .. extra(report, newer)
      saveDesktop(ctx, state, message)
    end, { timeout = 60000, always = true })
end

-- A value of the change summary (helper text) with the locale's decimal separator.
local function shown(value)
  if value == nil then return "unset" end
  local number = string.match(tostring(value), "^%-?%d+%.%d+$") and tonumber(value)
  return number and format.number(number) or tostring(value)
end

local function reviewPage(ctx, route)
  local store, view = ctx.store, ctx.view
  route.state = route.state or { validate = ctx.options.validateDefault ~= false }
  local state = route.state
  if state.preview == nil and not state.loading and not state.error then requestPreview(ctx, state) end
  local header = { kit.header(ctx, "Review changes", store.state and store.state.path or "") }
  local content = {}
  if state.error then table.insert(content, kit.notice(state.error, "error", nil, "review-error")) end
  if state.loading then table.insert(content, kit.empty("Checking your changes…", "loader")) end
  local preview = state.preview
  if preview then
    if #preview.summary > 0 then
      table.insert(content, kit.section("Changes"))
      for index, item in ipairs(preview.summary) do
        local text = item.label
        if item.old ~= nil or item.new ~= nil then
          text = text .. ":  " .. shown(item.old) .. "  →  " .. shown(item.new)
        end
        local revert = item.id and store.fieldChanges[item.id] ~= nil
        table.insert(content, ui.row({ key = "sum-" .. index, gap = 4, align = "center" }, {
          kit.badge(item.page or "", "secondary", "sp-" .. index),
          ui.label({ text = text, fontSize = kit.FONT.body, flexGrow = 1, maxLines = 3 }),
          revert and kit.iconButton("arrow-back-up", "Revert this change", function()
            store.revertField(item.id)
            requestPreview(ctx, state)
            ctx.render()
          end, true, "sum-revert-" .. index) or ui.spacer({ width = 1 }),
          item.id and kit.iconButton("arrow-right", "Go to setting", function() ctx.openField(item.id) end, true,
                                     "sum-go-" .. index) or ui.spacer({ width = 1 }),
        }))
      end
    end
    local desktop = store.desktopChanges()
    if desktop then
      table.insert(content, kit.section("Desktop"))
      local rows = {}
      local folders = desktop.userdirs and desktop.userdirs.changes or {}
      for key, value in pairs(folders) do
        table.insert(rows, { part = "userdirs", key = key, value = value, page = "User folders",
                             text = "User folder " .. key })
      end
      for _, change in ipairs(desktop.apps and desktop.apps.changes or {}) do
        table.insert(rows, { part = change.kind == "role" and "roles" or "mimes", key = change.key,
                             value = change.value, page = "Default apps", text = change.key })
      end
      table.sort(rows, function(a, b) return a.page .. a.text < b.page .. b.text end)  -- pairs() order varies
      local d = store.desktop
      local originals = { userdirs = d.userdirs.original, roles = d.apps.originalRoles, mimes = d.apps.originalMimes }
      for index, row in ipairs(rows) do
        table.insert(content, ui.row({ key = "desk-" .. index, gap = 4, align = "center" }, {
          kit.badge(row.page, "secondary", "dp-" .. index),
          kit.label(row.text .. ":  " .. (row.value ~= "" and row.value or "removed"), { flexGrow = 1, maxLines = 2 }),
          kit.iconButton("arrow-back-up", "Revert this change", function()
            local original = originals[row.part][row.key]
            if row.part ~= "userdirs" then original = original or "" end
            store.setDesktop(row.part, row.key, original)
            ctx.render()
          end, true, "desk-revert-" .. index),
          kit.iconButton("arrow-right", "Go to " .. row.page, function() ctx.openPage(row.page) end, true,
                         "desk-go-" .. index),
        }))
      end
    end
    local validation = preview.validation or {}
    if validation.ran then
      table.insert(content, kit.section("Validation"))
      if validation.valid and #(validation.diagnostics or {}) == 0 then
        table.insert(content, kit.notice("Umbriel accepts the new config.", "info", nil, "valid"))
      end
      for index, item in ipairs(validation.diagnostics or {}) do
        local kind = item.severity == "error" and "error" or "warning"
        local text = item.message .. (item.line and ("  (line " .. item.line .. ")") or "")
        table.insert(content, ui.row({ key = "diag-" .. index, gap = 6, align = "center" }, {
          ui.column({ flexGrow = 1 }, { kit.notice(text, kind, nil, "diagn-" .. index) }),
          item.field and ui.button({ text = "Go to setting", controlSize = "sm", variant = "outline",
                                     onClick = function() ctx.openField(item.field) end }) or ui.spacer({ width = 1 }),
        }))
      end
    elseif store.hasConfigChanges() and validation.reason then
      table.insert(content, kit.notice(validation.reason, "warning", nil, "novalid"))
    end
    if #preview.sections > 0 then
      table.insert(content, kit.section("File changes"))
      view.diffOpen = view.diffOpen or {}
      for index, section in ipairs(preview.sections) do
        local open = view.diffOpen[section.title]
        table.insert(content, kit.navRow({ key = "diff-" .. index, title = section.title, bold = true,
          trailing = open and "chevron-up" or "chevron-down", onClick = function()
            view.diffOpen[section.title] = not open or nil
            ctx.render()
          end }))
        if open then table.insert(content, ui.markdown({ key = "diffmd-" .. index, text = diffBlock(section.diff) })) end
      end
    end
  end
  local blocked = state.validate and preview and preview.validation and preview.validation.ran
    and not preview.validation.valid
  local rebuild = store.rebuild
  if rebuild == nil then rebuild = store.state and store.state.rebuild_default end
  table.insert(content, kit.section("Options"))
  table.insert(content, kit.optionRow("opt-validate", "Check with Umbriel before writing (recommended)",
    ui.toggle({ checked = state.validate, onChange = function(value)
      state.validate = value == "true"
      requestPreview(ctx, state)
      ctx.render()
    end })))
  table.insert(content, kit.optionRow("opt-rebuild", "Tidy file layout",
    ui.toggle({ checked = rebuild == true, onChange = function(value)
      store.rebuild = value == "true"
      requestPreview(ctx, state)
      ctx.render()
    end }), "Regroup the file in canonical order with section banners. Settings never change; comments may move."))
  -- not while a display Try runs: its rollback restores the file it wrote, and a save would make it fail
  local canSave = not state.saving and not state.loading and store.pendingCount() > 0 and not blocked
    and ctx.view.tryState == nil and not ctx.saving
  -- Ctrl+S on this page saves (shell.onKey); the header repeats Save so it never scrolls away.
  route.saveNow = function() if canSave then save(ctx, state) end end
  local function saveButton(key)
    return ui.button({ key = key, text = state.saving and "Saving…" or "Save", glyph = "device-floppy",
                       variant = "primary", tooltip = "Ctrl+S", enabled = canSave,
                       onClick = function() save(ctx, state) end })
  end
  header = { kit.header(ctx, "Review changes", store.state and store.state.path or "", { saveButton("save-top") }) }
  if not store.hasConfigChanges() and store.state and not state.loading then
    table.insert(content, kit.optionRow("opt-check", "Check the saved config with Umbriel",
      ui.button({ key = "check-now", text = "Check now", glyph = "checks", controlSize = "sm", variant = "outline",
                  enabled = state.validate, onClick = function()
                    requestPreview(ctx, state, true)
                    ctx.render()
                  end })))
  end
  table.insert(content, ui.row({ key = "review-actions", gap = 8 }, {
    saveButton("save"),
    ui.button({ text = "Keep editing", variant = "ghost", onClick = function() ctx.back() end }),
    ui.spacer({ flexGrow = 1 }),
    kit.confirmButton(ctx, { key = "discard", text = "Discard all", armedText = "Click again to discard",
                             glyph = "trash" }, function()
      ctx.discardAll()
      ctx.home()
    end),
  }))
  if blocked then
    table.insert(content, kit.muted("Saving is disabled until Umbriel accepts the config, or turn off the check."))
  end
  return { header = header, content = content }
end

local function backupsPage(ctx, route)
  local store, view = ctx.store, ctx.view
  route.state = route.state or { marked = {} }
  local state = route.state
  local path = store.state and store.state.path or nil
  local function refresh()
    state.loading = true
    ctx.helper.call("backups", { config = path }, function(err, data)
      state.loading = false
      -- never leave the list nil without an error, or every render would ask again
      if err then state.error = err.error else state.list = data.backups or {}; state.error = nil end
      ctx.render()
    end)
  end
  if state.list == nil and not state.loading and not state.error then refresh() end
  local header = { kit.header(ctx, "Backups", "A copy is taken before every save and restore; the newest 10 are kept") }
  local content = {}
  if state.error then table.insert(content, kit.notice(state.error, "error", nil, "bk-error")) end
  if state.loading then table.insert(content, kit.loading()) end
  local marked = 0
  for _ in pairs(state.marked) do marked = marked + 1 end
  local list = state.list or {}
  if #list > 0 then
    local tools = {
      ui.button({ text = marked == #list and "Clear selection" or "Select all", controlSize = "sm", variant = "outline",
                  glyph = marked == #list and "deselect" or "select-all", onClick = function()
        local all = marked ~= #list
        state.marked = {}
        if all then for _, item in ipairs(list) do state.marked[item.path] = true end end
        ctx.render()
      end }),
    }
    if marked > 0 and marked < #list then
      table.insert(tools, ui.button({ text = "Clear selection", controlSize = "sm", variant = "ghost", onClick = function()
        state.marked = {}
        ctx.render()
      end }))
    end
    if marked > 0 then
      table.insert(tools, ui.button({ text = "Delete " .. kit.plural(marked, "backup"), glyph = "trash",
                                      variant = "destructive", controlSize = "sm", onClick = function()
        local paths = {}
        for snapshot in pairs(state.marked) do table.insert(paths, snapshot) end
        ctx.helper.call("delete-backups", { config = path, snapshots = paths }, function(err, data)
          if err then ctx.tell(err.error, "error") return end
          state.marked = {}
          state.list = data.backups.backups
          if #data.errors > 0 then
            ctx.tell(table.concat(data.errors, "\n"), "warning")
          elseif ctx.isOpen() then
            ctx.render()
          else
            ctx.tell("Deleted " .. kit.plural(#data.deleted, "backup") .. ".", "info")
          end
        end, { always = true })
      end }))
    end
    table.insert(content, ui.row({ key = "bk-tools", gap = 8, align = "center" }, tools))
  end
  for index, item in ipairs(list) do
    local key = "bk-" .. index
    table.insert(content, kit.rowCard({ key = key, gap = 8, align = "center", paddingH = 11, paddingV = 7,
                                        radius = kit.RADIUS.md }, {
      ui.toggle({ checked = state.marked[item.path] == true, onChange = function(value)
        state.marked[item.path] = value == "true" or nil
        ctx.render()
      end }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = item.time, fontSize = kit.FONT.body, fontWeight = "bold" }),
        kit.muted(kit.fileSize(item.size)),
      }),
      ui.button({ text = "Compare", controlSize = "sm", variant = "ghost", onClick = function()
        ctx.helper.call("backup-diff", { config = path, snapshot = item.path }, function(err, data)
          if err then ctx.flash(err.error, "error") return end
          state.diff = { path = item.path, text = data.diff }
          ctx.render()
        end)
      end }),
      kit.confirmButton(ctx, { key = key .. "-restore", text = "Restore", armedText = "Click again to restore",
                               controlSize = "sm", check = function()
                                 if not store.hasConfigChanges() then return true end
                                 ctx.flash("Save or discard your changes before restoring.", "warning")
                               end }, function()
        ctx.helper.call("restore", { config = path, snapshot = item.path, revision = store.state.revision },
          function(err, data)
            if err then ctx.tell(err.error, "error") return end
            if data.state then store.load(data.state) elseif ctx.isOpen() then ctx.reload() end
            state.list = data.backups.backups
            ctx.tell("Backup restored. The previous file was backed up first."
              .. (data.warnings and (" " .. table.concat(data.warnings, " ")) or ""), data.warnings and "warning" or "info")
          end, { always = true })
      end),
    }))
    if state.diff and state.diff.path == item.path then
      table.insert(content, ui.markdown({ key = key .. "-diff", text = state.diff.text ~= "" and diffBlock(state.diff.text)
        or "Identical to the current file." }))
    end
  end
  if state.list and #state.list == 0 then table.insert(content, kit.empty("No backups yet.", "history")) end
  return { header = header, content = content }
end

function M.render(ctx, route)
  if route.name == "backups" then return backupsPage(ctx, route) end
  return reviewPage(ctx, route)
end

return M
