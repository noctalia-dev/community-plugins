--!nonstrict
-- Both input methods edit the same per-phone draft. Only an explicit call
-- click dials; history rows and keystrokes never dispatch.
local palette = require("./palette.luau")
local metrics = require("./components.luau").layout.page
local M = {}
local digits = { { "1", "2", "3" }, { "4", "5", "6" }, { "7", "8", "9" }, { "*", "0", "#" } }
local keyNames = { ["*"] = "star", ["#"] = "hash" }

local function validNumber(number)
  return #number <= 128 and number:find("[%d*#]") ~= nil
    and number:find("[^%d+*# ()%-]") == nil
end

function M.new(model, components, actions, items)
  local label = components.label
  local function activeCall(width, online, data)
    local call = data and data.active
    if type(call) ~= "table" or (call.state ~= "active" and call.state ~= "ringing") then
      return nil
    end
    local caller = components.preview(call.name, 72)
    if caller == "" then caller = components.preview(call.number, 72) end
    if caller == "" then caller = noctalia.tr("calls.call") end
    local device = model.selected
    local dispatch = actions.bindAction("page", device)
    local enabled = online and data.control == true and not actions.actionBusy("page")
    local buttons = {}
    for _, def in ipairs({
      { "answer", "calls.answer" }, { "silence", "common.silent" }, { "decline", "calls.end" },
    }) do
      local command, title = def[1], noctalia.tr(def[2])
      if command == "decline" or call.state == "ringing" then
        buttons[#buttons + 1] = ui.button({
          key = "active-" .. command,
          text = title, height = 28, fontSize = 11, controlSize = "sm",
          variant = command == "answer" and "primary" or "ghost", enabled = enabled,
          onClick = enabled and function()
            local live = model.pageView and model.pageView.data
            if not live or not live.control or type(live.active) ~= "table" or live.active.id ~= call.id
              or live.active.state ~= call.state then return end
            dispatch({ action = command, id = call.id })
          end or nil,
        })
      end
    end
    return ui.column({
      key = "active-call-toolbar", width = width, height = 70, paddingH = 7, paddingV = 4, gap = 4,
      radius = 10, fill = "primary/0.12",
    }, {
      ui.row({ height = 28, gap = 6, align = "center" }, {
        components.iconBadge("phone", 26, "primary", "transparent", 17),
        ui.column({ gap = 0 }, {
          label(caller, 12, "on_surface", true, width - 48),
          label(components.directions[call.state], 10, "primary", false, width - 48),
        }),
      }),
      ui.row({ width = width - 14, height = 28, gap = 4 }, buttons),
    })
  end

  local function render(width, online, data, stateNote, refresh)
    local gap, padding, dialWidth = 10, 10, 354
    local historyWidth = width - gap - dialWidth
    local room = dialWidth - 2 * padding
    local device = model.selected
    local scope = model.actionScope
    local dispatch = actions.bindAction("page", device)
    local draftKey = (device or "none") .. "|dial"
    local number = model.pageDrafts[draftKey] or ""
    local function revision()
      return model.pageDraftRevisions[draftKey] or 0
    end
    local displayedRevision = revision()
    local enabled = device ~= nil
    local function currentDialer()
      return enabled and model.opened and model.page == "calls"
        and model.selected == device and model.actionScope == scope
    end
    local function setNumber(value, reseed)
      if not currentDialer() or type(value) ~= "string" then return end
      if model.pageDrafts[draftKey] == value then return end
      model.pageDrafts[draftKey] = value
      -- Noctalia seeds an input only when its key changes. Recreate it for
      -- history/keypad edits, but preserve focus and caret for typed edits.
      if reseed then model.pageDraftRevisions[draftKey] = revision() + 1 end
      actions.render()
    end
    local function press(symbol)
      return function()
        local current = model.pageDrafts[draftKey] or ""
        if #current < 128 then setNumber(current .. symbol, true) end
      end
    end
    local function erase()
      local current = model.pageDrafts[draftKey] or ""
      local ok, start = pcall(utf8.offset, current, -1)
      if current ~= "" then setNumber(current:sub(1, (ok and start or #current) - 1), true) end
    end

    local innerHistory = historyWidth - 2 * padding
    local records = {}
    local function addRecord(node)
      if node then records[#records + 1] = node end
    end
    local pagination
    if data then
      pagination = items.render(addRecord, online, innerHistory, data, refresh, function(value)
        setNumber(value, true)
      end)
    else
      addRecord(stateNote(innerHistory))
    end
    local historyHeading = { label(noctalia.tr("calls.history"), 16, "on_surface", true, innerHistory - 114) }
    if pagination then
      historyHeading[2] = ui.spacer({ flexGrow = 1 })
      historyHeading[3] = pagination
    end
    table.insert(records, 1, ui.row({
      width = innerHistory, height = 34, gap = 8, align = "center",
    }, historyHeading))

    local ongoing = activeCall(room, online, data)
    local padGap, keyHeight = 6, ongoing and 45 or 54
    local keyWidth = math.floor((room - 2 * padGap) / 3)
    local keypad = {}
    for row, symbols in ipairs(digits) do
      local keys = {}
      for _, symbol in ipairs(symbols) do
        keys[#keys + 1] = ui.button({
          key = "dial-key-" .. (keyNames[symbol] or symbol),
          text = symbol, variant = "outline", controlSize = "sm", fontSize = 18,
          width = keyWidth, height = keyHeight,
          enabled = enabled, onClick = enabled and press(symbol) or nil,
        })
      end
      keypad[row] = ui.row({
        width = room, height = keyHeight, gap = padGap, justify = "center",
      }, keys)
    end

    local body = { ui.row({ height = 32, align = "center" }, {
      label(noctalia.tr("calls.new_call"), 16, "on_surface", true, room),
    }) }
    body[#body + 1] = ongoing
    body[#body + 1] = ui.row({
      key = "dial-toolbar", width = room, height = 40, gap = 6, align = "center",
    }, {
      ui.input({
        key = "dial-number-" .. tostring(device) .. "-" .. displayedRevision, value = number,
        placeholder = noctalia.tr("calls.number"), controlSize = "sm",
        height = 36, flexGrow = 1, enabled = enabled,
        onChange = function(value)
          if revision() == displayedRevision then setNumber(value, false) end
        end,
      }),
      ui.button({
        key = "dial-key-plus", glyph = "plus", glyphSize = 18, width = 32, height = 34,
        variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("calls.add_plus"),
        enabled = enabled, onClick = enabled and press("+") or nil,
      }),
      ui.button({
        key = "dial-erase", glyph = "backspace", glyphSize = 19, width = 32, height = 34,
        tooltip = noctalia.tr("calls.erase"), variant = "ghost",
        enabled = enabled and number ~= "", onClick = enabled and number ~= "" and erase or nil,
      }),
    })
    body[#body + 1] = ui.column({
      key = "dial-keypad", width = room, height = 4 * keyHeight + 3 * padGap, gap = padGap,
    }, keypad)
    local waiting, waitingFor = actions.actionBusy("page")
    local canDial = online and data ~= nil and data.dial == true and validNumber(number) and not waiting
    body[#body + 1] = ui.row({ width = room, height = 36, gap = 7, align = "center" }, {
      components.smallButton(noctalia.tr("common.clear"), function()
        setNumber("", true)
      end, enabled and number ~= ""),
      ui.button({
        key = "dial-submit", text = noctalia.tr(waitingFor == "dial" and "common.sending" or "calls.dial"),
        glyph = "phone",
        glyphSize = 17, controlSize = "sm", height = 36, flexGrow = 1,
        variant = "primary", enabled = canDial,
        onClick = canDial and function()
          if not currentDialer() then return end
          local view = model.pageView and model.pageView.data
          local draft = model.pageDrafts[draftKey] or ""
          if not view or view.dial ~= true or not validNumber(draft) then return end
          dispatch({ action = "dial", text = draft })
        end or nil,
      }),
    })
    local hint = not device and "common.connect_phone"
      or (not online and "common.phone_offline")
      or (number ~= "" and not validNumber(number) and "calls.number_hint")
      or (data and data.dial ~= true and "calls.permission_hint" or "calls.dial_hint")
    body[#body + 1] = label(noctalia.tr(hint), 11, "on_surface_variant", false, room)

    return ui.row({
      key = "calls-layout", width = width, height = metrics.body, gap = gap, align = "start",
    }, {
      ui.column({
        key = "call-history", width = historyWidth, height = metrics.body,
        gap = 6, padding = padding, radius = 12, fill = palette("raised", 0.32),
      }, records),
      ui.column({
        key = "dial-form", width = dialWidth, height = metrics.body,
        gap = 6, padding = padding, radius = 12, fill = palette("raised", 0.46),
      }, body),
    })
  end
  return { render = render }
end

return M
