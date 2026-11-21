--!nonstrict
-- About: version, schema coverage, the editor "Edit file" uses and (app only) the Noctalia palette template.
local kit = require("../ui/kit.luau")

local M = {}

local SHOWN = 8  -- option paths listed per coverage line

local function pathList(list)
  local shown = {}
  for index, path in ipairs(list) do
    if index > SHOWN then break end
    table.insert(shown, "`" .. tostring(path) .. "`")
  end
  local text = table.concat(shown, ", ")
  if #list > SHOWN then text = text .. " and " .. (#list - SHOWN) .. " more" end
  return text
end

local function schemaText(schema, targets)
  if not schema.available then
    return "Umbriel's option list is unavailable: " .. tostring(schema.reason or "unknown reason")
      .. ". Built-in defaults are shown."
  end
  local lines = { "Using the option list of Umbriel " .. tostring(schema.version) .. " ("
    .. tostring(schema.revision) .. ")." }
  if targets.umbriel and schema.version and tostring(schema.version) ~= targets.umbriel then
    table.insert(lines, "This version of Umbriel Settings was made for Umbriel " .. targets.umbriel .. ".")
  end
  local missing, stale = schema.missing or {}, schema.stale or {}
  if #missing == 0 and #stale == 0 then
    table.insert(lines, "Every option of this version has a setting here.")
  end
  if #missing > 0 then
    table.insert(lines, kit.plural(#missing, "option") .. " can only be edited in the file: " .. pathList(missing) .. ".")
  end
  if #stale > 0 then
    table.insert(lines, kit.plural(#stale, "setting") .. " here " .. (#stale == 1 and "is" or "are")
      .. " not part of this version: " .. pathList(stale) .. ".")
  end
  return table.concat(lines, " ")
end

local function editorSection(ctx, state)
  local function save()
    local command = state.editorDraft
    if command == nil then command = state.editor or "" end
    ctx.helper.call("set-editor", { editor = command }, function(err, data)
      if err then ctx.flash(err.error, "error") return end
      state.editor, state.editorDraft = data.editor, nil
      ctx.flash(data.editor == "" and "Edit file uses the default app." or "Edit file uses " .. data.editor .. ".", "info")
    end)
  end
  return {
    kit.section("Editor", "about-editor"),
    kit.muted("Command for Edit file; the config path is appended. Empty uses the default app (xdg-open). "
      .. "Terminal editors need a terminal, e.g. “kitty nvim”."),
    ui.row({ key = "editor-row", gap = 8, align = "center" }, {
      ui.input({ key = "editor:" .. ctx.gen("editor"), value = state.editor or "", flexGrow = 1,
                 controlSize = "sm", placeholder = "Default app (xdg-open)",
                 onChange = function(text) state.editorDraft = text end,
                 onSubmit = function(text) state.editorDraft = text; save() end }),
      ui.button({ text = "Save", controlSize = "sm", enabled = state.loaded == true, onClick = save }),
    }),
  }
end

local function paletteSection(ctx, state)
  local palette = state.palette or {}
  local rows = { kit.section("Colors", "about-colors") }
  if palette.palette then
    table.insert(rows, kit.muted("The app uses Noctalia's colors from the palette template."))
  elseif not palette.noctalia then
    table.insert(rows, kit.muted("Noctalia's config was not found; the app uses the qt6ct or Qt colors."))
  elseif palette.template and palette.entry then
    table.insert(rows, kit.muted("The palette template is set up; Noctalia writes the colors on its next theme change."))
  else
    table.insert(rows, kit.muted("The app guesses Noctalia's colors from qt6ct. A Noctalia user template gives it the "
      .. "exact colors; setting it up adds one entry to noctalia-config.toml (a copy of the old file is kept)."))
    table.insert(rows, ui.row({ key = "palette-row", gap = 8 }, {
      ui.button({ text = "Set up palette template", glyph = "palette", controlSize = "sm", variant = "outline",
                  onClick = function()
        ctx.helper.call("palette-template", {}, function(err, data)
          if err then ctx.flash(err.error, "error") return end
          state.palette = data.palette
          ctx.flash("Palette template set up.", "info")
        end)
      end }),
    }))
  end
  return rows
end

function M.render(ctx, route)
  route.state = route.state or {}
  local state = route.state
  if not state.loaded and not state.loading then
    state.loading = true
    ctx.helper.call("about", {}, function(err, data)
      state.loading = false
      if err then state.error = err.error else
        state.loaded, state.editor, state.palette = true, data.editor, data.palette
        ctx.bump("editor")
      end
      ctx.render()
    end)
  end
  local meta = ctx.store.meta
  local title = ctx.isApp and ("**Umbriel Settings** — version " .. tostring(ctx.options.appVersion or meta.version))
    or ("**Umbriel Settings** for Noctalia — version " .. tostring(meta.version))
  local targets = meta.targets or {}
  local madeFor = "Made for Umbriel " .. tostring(targets.umbriel)
    .. (ctx.isApp and "." or (" and Noctalia " .. tostring(targets.noctalia) .. " or newer."))
  local lines = {
    title,
    "",
    madeFor,
    "",
    schemaText(meta.schema or {}, targets),
    "",
    "**Keys:** Ctrl+F search · Ctrl+S review and save · Ctrl+Z undo · Alt+Left back · "
      .. (ctx.isApp and "Esc clears the search or goes back." or "Esc closes the panel (edits are kept)."),
    "",
    "Edits stay unsaved until you review them. Before writing, the new file is checked with "
      .. "`umbriel config validate`; a copy of the old file is kept under Backups. Comments and formatting are preserved.",
    "",
    "Needs Python 3 with **tomlkit** (Arch: `python-tomlkit`).",
  }
  local content = { ui.markdown({ key = "about", text = table.concat(lines, "\n") }) }
  if state.error then table.insert(content, kit.notice(state.error, "error", nil, "about-error")) end
  for _, row in ipairs(editorSection(ctx, state)) do table.insert(content, row) end
  if ctx.isApp then
    for _, row in ipairs(paletteSection(ctx, state)) do table.insert(content, row) end
  end
  return { header = { kit.header(ctx, "About") }, content = content }
end

return M
