--!nonstrict
-- The picker itself. Both panel entries run this; each supplies its own shape.
--
-- The shape comes from the ENTRY, not from the `list_mode` setting. A panel's
-- size is fixed in the manifest, so `panel_grid` is a box for three icons across
-- and `panel_list` a box for three stacked buttons. Reading the setting here
-- instead would let the two disagree: opening `panel_list` while the setting
-- said grid drew the grid inside the taller box, and the reverse scrolled.
-- `list_mode` decides which entry the capsule opens; it does not decide what a
-- given entry draws.

local shared = require("./shared.luau")
local LAYOUTS, ORDER, isEnabled = shared.LAYOUTS, shared.ORDER, shared.isEnabled

local COLUMNS = 3
local GAP = 2

local M = {}

-- One picker instance. The entry files each build exactly one and wire the
-- globals the host calls into it.
function M.new(isList: boolean)
    local self = {}
    local selected = ""
    local pickSlots = {}

    -- NOTE: `workspace-set-layout` acts on the FOCUSED workspace -- umbriel has
    -- no output-scoped variant. So a pick applies to whatever holds focus, which
    -- is the capsule that opened this panel only when that monitor is also
    -- focused. The picker highlights the originating bar's layout; it cannot
    -- retarget the write without stealing focus, so it deliberately does not try.
    local function apply(name: string)
        selected = name
        noctalia.runAsync("umbriel msg workspace-set-layout:" .. name)
        -- No optimistic state write: the map is keyed by output and this pick
        -- lands on the focused one, which may not be this capsule's. The windows
        -- event reports the truth about 200ms later, and a wrong echo would be
        -- visible.
        panel.close()
    end

    local function makeGrid(children)
        local rows = {}
        local row = {}
        for i, child in ipairs(children) do
            table.insert(row, child)
            if #row >= COLUMNS or i == #children then
                while #row < COLUMNS do
                    table.insert(row, ui.spacer({ flexGrow = 1 }))
                end
                table.insert(rows, ui.row({ gap = GAP, align = "stretch" }, row))
                row = {}
            end
        end
        return ui.column({ gap = GAP }, rows)
    end

    local function renderButtons()
        local buttons = {}
        local i = 0
        for _, name in ipairs(ORDER) do
            if isEnabled(name) then
                local entry = LAYOUTS[name]
                local slotIndex = i
                local isSelected = selected == name
                pickSlots[slotIndex] = { name = name }

                if isList then
                    table.insert(buttons, ui.button({
                        key     = name,
                        glyph   = entry.glyph,
                        text    = noctalia.tr("name_" .. name),
                        variant = if isSelected then "primary" else "ghost",
                        onClick = `onPick{slotIndex}`,
                    }))
                else
                    table.insert(buttons, ui.column({
                        key      = name,
                        gap      = 2,
                        align    = "center",
                        flexGrow = 1,
                    }, {
                        ui.button({
                            glyph     = entry.glyph,
                            glyphSize = 18,
                            variant   = if isSelected then "primary" else "ghost",
                            onClick   = `onPick{slotIndex}`,
                        }),
                        ui.label({
                            text       = noctalia.tr("name_" .. name),
                            fontSize   = 9,
                            fontWeight = "bold",
                            color      = if isSelected then "primary" else "on_surface_variant",
                            textAlign  = "center",
                            maxLines   = 1,
                        }),
                    }))
                end
                i += 1
            end
        end
        return buttons
    end

    local function render()
        pickSlots = {}

        local content
        if isList then
            content = ui.column({ padding = 8, gap = 4 }, renderButtons())
        else
            content = ui.column({ padding = 12, gap = GAP }, { makeGrid(renderButtons()) })
        end

        panel.render(ui.column({ flexGrow = 1 }, {
            ui.scroll({ flexGrow = 1 }, { content }),
        }))
    end

    function self.onOpen(_context)
        -- Highlight the layout of the bar that opened this, not the focused one
        -- -- the capsule the user clicked is the one they mean. widget.luau
        -- publishes its output on panel_output just before toggling us open.
        local current = nil
        local origin = noctalia.state.get("panel_output")
        if type(origin) == "string" and origin ~= "" then
            local byOutput = noctalia.state.get("layouts")
            if type(byOutput) == "table" then current = byOutput[origin] end
        end
        if current == nil then current = noctalia.state.get("layout") end

        selected = if type(current) == "string" and LAYOUTS[current] ~= nil then current else ""
        render()
    end

    function self.pick(index: number)
        local slot = pickSlots[index]
        if slot == nil then return end
        apply(slot.name)
    end

    return self
end

return M
