--!nonstrict
-- The keybind action catalog: describing and running actions, argument help and pickers, and the searchable
-- action picker page (route `actions`).
local kit = require("../ui/kit.luau")

local M = {}

-- Why "Run now" refuses an action (same rules as the helper's `run_block_reason`), or nil.
local function blockReason(meta, action)
  local words = {}
  -- quotes are dropped like `umbriel msg` gets the words, so a quoted action isn't let through
  local plain = string.gsub(action or "", "[\"']", "")
  for word in string.gmatch(plain, "%S+") do table.insert(words, word) end
  if #words == 0 then return "Enter an action first" end
  local blocked = meta.actions.blocked or { heads = {}, spawn = {} }
  local head, rest = words[1], table.concat(words, " ", 2)
  if blocked.heads[head] then return blocked.heads[head] end
  if head == "submap" and rest ~= "reset" then return blocked.submap end
  if head == "spawn" then
    for phrase, reason in pairs(blocked.spawn) do
      if string.find(rest, phrase, 1, true) then return reason end
    end
  end
  return nil
end

function M.runButton(ctx, action)
  local reason = blockReason(ctx.store.meta, action)
  local view = ctx.view
  return kit.confirmButton(ctx, { key = "kb-run", text = view.kbRunning and "Running…" or "Run now",
                                  armedText = "Click again to run", glyph = "player-play", controlSize = "sm",
                                  enabled = reason == nil and not view.kbRunning,
                                  tooltip = reason or "Send this action to Umbriel once, to see what it does" },
    function()
      view.kbRunning = true
      ctx.render()
      ctx.helper.call("run-action", { action = action }, function(err)
        view.kbRunning = false
        if err then ctx.flash(err.error, "error") else ctx.flash("Sent “" .. action .. "” to Umbriel.", "info") end
        ctx.render()
      end)
    end)
end

local function reduceTemplate(text)
  local head, rest = string.match(text, "^(%S+)%s+(.*)$")
  if not head then return text end
  if string.sub(rest, 1, 1) == "[" then return head end
  if string.sub(rest, 1, 1) == "<" then return head .. " " end
  return text
end

-- Action templates by full text and by first word, built once per meta: the list describes every row
-- on every render, and scanning all actions per row is the costliest loop on a large config.
local actionIndex = { meta = nil, exact = {}, head = {} }
function M.describe(meta, action)
  if actionIndex.meta ~= meta then
    actionIndex = { meta = meta, exact = {}, head = {} }
    for _, category in ipairs(meta.actions.categories) do
      for _, item in ipairs(category[2]) do
        local head = string.match(item[1], "^(%S+)")
        if actionIndex.exact[item[1]] == nil then actionIndex.exact[item[1]] = item end
        if head and actionIndex.head[head] == nil then actionIndex.head[head] = item end
      end
    end
  end
  local item = actionIndex.exact[action or ""] or actionIndex.head[string.match(action or "", "^(%S+)") or ""]
  if item then return item[2], item[1] end
  return nil, nil
end

function M.argHelp(meta, template)
  local lines = {}
  for name in string.gmatch(template or "", "<([%w_.-]+)>") do
    local help = meta.actions.args[name] or meta.actions.args[string.gsub(name, "%.%.%.$", "")]
    if help then table.insert(lines, "<" .. name .. ">: " .. help) end
  end
  return table.concat(lines, "\n")
end

-- Choices for an action's first argument, by its placeholder in the catalog template: names the config defines
-- (and the connected outputs). Base lists are module constants so the store's cache can keep them.
local EFFECT_OFF, SUBMAP_RESET = { "off" }, { "reset" }
local function argumentKind(head, placeholder)
  if placeholder == "output" or placeholder == "destination" then return "output" end
  if placeholder == "pool" or placeholder == "scratchpad" or placeholder == "workspace" then return placeholder end
  if placeholder == "name" and head == "submap" then return "submap", SUBMAP_RESET end
  if placeholder == "name" and string.match(head, "^effect%-") then
    return "effect", string.match(head, "%-set$") and EFFECT_OFF or nil
  end
  return nil
end

-- A select that fills in the first argument of the action (keeping the rest), or nil when there is nothing
-- to offer.
function M.argumentPicker(ctx, action, template, enabled, onPick)
  local head, rest = string.match(template or "", "^(%S+)%s+(.*)$")
  local placeholder = rest and string.match(rest, "^%[?<([%w-]+)>")
  if not placeholder then return nil end
  local kind, base = argumentKind(head, placeholder)
  if not kind then return nil end
  local known = ctx.store.namedChoices(kind, base, kind == "output" and ctx.liveOutputs() or nil)
  if #known == 0 then return nil end
  local words = {}
  for word in string.gmatch(action or "", "%S+") do table.insert(words, word) end
  local current = words[2] and not string.match(words[2], "^%-") and words[2] or nil
  local choices, options, selected = known, { "Choose " .. placeholder .. "…" }, 0
  for i, choice in ipairs(choices) do
    table.insert(options, choice)
    if choice == current then selected = i end
  end
  if current and selected == 0 then  -- a name the config doesn't define (yet) is still shown as chosen
    choices = { table.unpack(known) }
    table.insert(choices, current)
    table.insert(options, current .. " (not defined here)")
    selected = #choices
  end
  return kit.optionRow("kb-arg", "<" .. placeholder .. ">", ui.select({
    key = "kb-arg-select", options = options, selectedIndex = selected, width = 220, controlSize = "sm",
    enabled = enabled, onChange = function(value)
      local choice = choices[tonumber(value) or 0]
      if not choice then return end
      if current then words[2] = choice else table.insert(words, 2, choice) end
      onPick(table.concat(words, " "))
    end }))
end

local ACTION_MATCHES = 60  -- search results listed at most

function M.pickerPage(ctx, route)
  local store, view = ctx.store, ctx.view
  local header = { kit.header(ctx, "Choose an action", "Pick a template, then fill in any <argument>") ,
    kit.filterBox(ctx, "actQuery", { focus = true, placeholder = "Search actions" }) }
  local function choose(template)
    local row = route.target and store.keybinds.rows[route.target] or view.kbNew
    if row then
      row.action = reduceTemplate(template)
      if route.target then store.keybindsChanged() end
    end
    ctx.bump("kbaction")
    view.actQuery = ""
    ctx.back()
  end
  local content = {}
  local query = kit.filterText(ctx, "actQuery")
  local shown = 0
  for _, category in ipairs(store.meta.actions.categories) do
    local name = category[1]
    local open = query ~= "" or view.actOpen == name
    local items = {}
    for index, item in ipairs(category[2]) do
      if query == "" or kit.contains(item[1] .. " " .. item[2], query) then
        if shown < ACTION_MATCHES or query == "" then
          table.insert(items, kit.navRow({ key = "act-" .. name .. "-" .. index, title = item[1], subtitle = item[2],
            trailing = "check", onClick = function() choose(item[1]) end }))
          shown = shown + 1
        end
      end
    end
    if #items > 0 then
      table.insert(content, kit.navRow({ key = "cat-" .. name, title = name, subtitle = kit.plural(#category[2], "action"),
        bold = true, trailing = open and "chevron-up" or "chevron-down", fill = "surface_container_high",
        onClick = function() view.actOpen = view.actOpen ~= name and name or nil; ctx.render() end }))
      if open then for _, item in ipairs(items) do table.insert(content, item) end end
    end
  end
  if #content == 0 then table.insert(content, kit.empty("No action matches. You can also type any action by hand.")) end
  return { header = header, content = content }
end

return M
