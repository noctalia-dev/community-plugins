--!nonstrict
-- A plugin's settings, wherever Noctalia keeps them: its own and its panels' under
-- plugin_settings."<id>", each bar widget's under widget.<instance>, and each desktop or lock
-- screen widget's under <section>.widget.<instance>.settings. The fields and their labels
-- come from the plugin's manifest and translations, the values from Noctalia's config.
-- Changes are saved with `noctalia msg config-set`, one at a time, as Noctalia reloads its
-- config after each.

local Toml = require("./toml.luau")

local Settings = {}

-- Where Noctalia keeps its copy of a plugin of a git source: it is there while the plugin
-- is installed, on or off, and goes when the plugin is removed.
function Settings.pluginDir(source, id)
  local state = noctalia.getenv("XDG_STATE_HOME")
  if state == nil or state == "" then
    state = noctalia.expandPath("~/.local/state")
  end
  return `{state}/noctalia/plugins/materialized/{source}/{id:match("/(.+)$") or id}`
end

local FIELD_NAMES = {
  key = true,
  type = true,
  label_key = true,
  description_key = true,
  default = true,
  min = true,
  max = true,
  step = true,
  options = true,
  visible_when = true,
  advanced = true,
  secret = true,
}

local queue = {}
local saving = false

-- The language of the shell, such as "tr" or "pt-BR".
local function language()
  -- Read from its table: getSetting logs a warning for a key that is not set.
  local shell = noctalia.getSetting("shell")
  local lang = type(shell) == "table" and shell.lang or nil
  if type(lang) ~= "string" or lang == "" then
    lang = noctalia.getenv("LANG") or "en"
  end
  lang = lang:gsub("[%.@].*$", ""):gsub("_", "-")
  return lang ~= "" and lang or "en"
end

-- "settings.interval.label" in a translation file, flat or nested.
local function flatten(map, prefix, into)
  for key, value in pairs(map) do
    local path = prefix and (prefix .. "." .. key) or key
    if type(value) == "table" then
      flatten(value, path, into)
    elseif type(value) == "string" then
      into[path] = value
    end
  end
  return into
end

local function tableAt(path)
  local value = noctalia.getSetting(path)
  return type(value) == "table" and value or {}
end

-- The bar each widget instance is placed on, also inside a capsule group ("group:<id>").
local function barsOfInstances()
  local where = {}
  for barName, bar in pairs(tableAt("bar")) do
    if type(bar) == "table" then
      local groups = {}
      for _, group in ipairs(type(bar.capsule_group) == "table" and bar.capsule_group or {}) do
        if type(group) == "table" and type(group.id) == "string" and type(group.members) == "table" then
          groups[group.id] = group.members
        end
      end
      for _, side in ipairs({ "start", "center", "end" }) do
        for _, item in ipairs(type(bar[side]) == "table" and bar[side] or {}) do
          local members = type(item) == "string" and groups[item:match("^group:(.+)$") or ""] or { item }
          for _, instance in ipairs(members) do
            where[instance] = where[instance] or barName
          end
        end
      end
    end
  end
  return where
end

-- The setting fields of a manifest, each with its scope ("setting", "panel", "widget" or
-- "desktop_widget"), the id of its entry, and its texts from <translations>.
local function fieldsOf(manifest, translations)
  local fields = {}
  local entryIds = {} -- the id of the last [[widget]], [[panel]] or [[desktop_widget]]
  local last = nil -- the last field, which a [[...setting.options]] table adds to
  for _, section in ipairs(Toml.manifest(manifest)) do
    local header = section.header or ""
    local scope = header == "setting" and "setting" or header:match("^(%a[%w_]*)%.setting$")
    if header == "widget" or header == "panel" or header == "desktop_widget" then
      entryIds[header] = section.values.id
    elseif scope then
      last = { scope = scope, entry = scope ~= "setting" and entryIds[scope] or "" }
      for name, value in pairs(section.values) do
        if FIELD_NAMES[name] then
          last[name] = value
        end
      end
      table.insert(fields, last)
    elseif header:match("setting%.options$") and last then
      last.listed = last.listed or {}
      table.insert(last.listed, section.values)
    end
  end
  local result = {}
  for _, field in ipairs(fields) do
    if type(field.key) == "string" and type(field.type) == "string" then
      local choices = {}
      for _, option in ipairs(type(field.options) == "table" and field.options or field.listed or {}) do
        if type(option) == "table" and option.value ~= nil then
          table.insert(choices, {
            value = tostring(option.value),
            label = translations[option.label_key or ""] or tostring(option.value),
          })
        end
      end
      local visible = type(field.visible_when) == "table" and field.visible_when or nil
      table.insert(result, {
        scope = field.scope,
        entry = field.entry,
        key = field.key,
        type = field.type,
        label = translations[field.label_key or ""] or field.key,
        description = translations[field.description_key or ""],
        default = field.default,
        min = tonumber(field.min),
        max = tonumber(field.max),
        options = choices,
        advanced = field.advanced == true,
        secret = field.secret == true,
        visibleWhen = visible and type(visible.key) == "string" and {
          key = visible.key,
          values = type(visible.values) == "table" and visible.values or {},
        } or nil,
      })
    end
  end
  return result
end

local function withValues(fields, values)
  local list = {}
  for _, field in ipairs(fields) do
    local copy = table.clone(field)
    local value = values[field.key]
    if value == nil then
      value = field.default
    end
    -- A credential stays in Noctalia's config; the hub shows only that it is set.
    copy.value = if field.secret then nil else value
    copy.set = values[field.key] ~= nil
    table.insert(list, copy)
  end
  return list
end

-- The sections of the plugin <id>: its own settings, then each widget placed somewhere.
local function sectionsOf(id, fields)
  local sections = {}
  local own, byEntry = {}, { widget = {}, desktop_widget = {} }
  for _, field in ipairs(fields) do
    if field.scope == "setting" or field.scope == "panel" then
      table.insert(own, field)
    elseif byEntry[field.scope] then
      byEntry[field.scope][field.entry] = byEntry[field.scope][field.entry] or {}
      table.insert(byEntry[field.scope][field.entry], field)
    end
  end
  if #own > 0 then
    local values = tableAt("plugin_settings")[id]
    table.insert(sections, {
      kind = "plugin",
      fields = withValues(own, type(values) == "table" and values or {}),
    })
  end
  local bars = barsOfInstances()
  local instances = {}
  for instance, config in pairs(tableAt("widget")) do
    if type(config) == "table" and type(config.type) == "string" then
      local entry = config.type:sub(1, #id + 1) == id .. ":" and config.type:sub(#id + 2) or nil
      if entry and byEntry.widget[entry] and bars[instance] then
        table.insert(instances, {
          kind = "widget",
          instance = instance,
          bar = bars[instance],
          fields = withValues(byEntry.widget[entry], config),
        })
      end
    end
  end
  table.sort(instances, function(a, b)
    return a.bar .. a.instance < b.bar .. b.instance
  end)
  for _, section in ipairs(instances) do
    table.insert(sections, section)
  end
  for _, place in ipairs({ "desktop_widgets", "lockscreen_widgets" }) do
    local found = {}
    local widgets = tableAt(place).widget
    for instance, config in pairs(type(widgets) == "table" and widgets or {}) do
      if type(config) == "table" and type(config.type) == "string" and config.type:sub(1, #id + 1) == id .. ":" then
        local entry = config.type:sub(#id + 2)
        if byEntry.desktop_widget[entry] then
          table.insert(found, {
            kind = place == "desktop_widgets" and "desktop" or "lockscreen",
            instance = instance,
            output = config.output,
            fields = withValues(byEntry.desktop_widget[entry], type(config.settings) == "table" and config.settings or {}),
          })
        end
      end
    end
    table.sort(found, function(a, b) return a.instance < b.instance end)
    for _, section in ipairs(found) do
      table.insert(sections, section)
    end
  end
  return sections
end

-- Reads the settings of <plugin> ({ id, source }) and calls <done>(sections) or
-- <done>(nil, error). The translations are English, then the shell's language.
function Settings.load(plugin, done)
  local dir = Settings.pluginDir(plugin.source, plugin.id)
  local lang = language()
  local files = { "en" }
  for _, name in ipairs({ lang:match("^[^-]+"), lang }) do
    if not table.find(files, name) then
      table.insert(files, name)
    end
  end
  local translations = {}
  local function readTranslation(index)
    if index > #files then
      noctalia.readFileAsync(dir .. "/plugin.toml", function(manifest, err)
        if manifest == nil then
          done(nil, err or dir)
          return
        end
        done(sectionsOf(plugin.id, fieldsOf(manifest, translations)))
      end)
      return
    end
    noctalia.readFileAsync(`{dir}/translations/{files[index]}.json`, function(text)
      local decoded = text and noctalia.json.decode(text)
      if type(decoded) == "table" then
        flatten(decoded, nil, translations)
      end
      readTranslation(index + 1)
    end)
  end
  readTranslation(1)
end

-- The `config-set` arguments that save <value> for <field> of the plugin <id> in <section>.
-- The path is one top-level key and the rest an inline table, since a plugin id has a slash
-- that config-set's path cannot hold.
local function configSet(id, section, key, value, kind)
  local encoded = Toml.encode(value, kind)
  if encoded == nil then
    return nil
  end
  local inner = Toml.encode(key, nil) .. " = " .. encoded
  if section.kind == "plugin" then
    return { "plugin_settings", `\{ {Toml.encode(id)} = \{ {inner} } }` }
  elseif section.kind == "widget" then
    return { "widget", `\{ {Toml.encode(section.instance)} = \{ {inner} } }` }
  end
  local place = section.kind == "desktop" and "desktop_widgets" or "lockscreen_widgets"
  return { place, `\{ widget = \{ {Toml.encode(section.instance)} = \{ settings = \{ {inner} } } } }` }
end

local function nextSave()
  local job = table.remove(queue, 1)
  if job == nil then
    saving = false
    return
  end
  saving = true
  noctalia.runAsync({ "noctalia", "msg", "config-set", job.args[1], job.args[2] }, function(result)
    local out = noctalia.string.trim((result.stdout or "") .. (result.stderr or ""))
    if result.exitCode ~= 0 or out:sub(1, 5) == "error" then
      job.done(out ~= "" and out or "config-set failed")
    else
      job.done(nil)
    end
    nextSave()
  end, 10000)
end

-- Saves <value> of type <kind> under <key> in <section> of the plugin <id>, then calls
-- <done>(error or nil).
function Settings.save(id, section, key, value, kind, done)
  local args = configSet(id, section, key, value, kind)
  if args == nil then
    done("invalid value")
    return
  end
  table.insert(queue, { args = args, done = done })
  if not saving then
    nextSave()
  end
end

return Settings
