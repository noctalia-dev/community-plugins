--!nonstrict
-- Udiskie bar widget: renders the mounted-device count and a tooltip listing.
-- the mounted devices. State comes from the udiskie service via shared state.

local function mountedDevices(data)
    if type(data) ~= "table" or type(data.raw) ~= "table" then
        return {}
    end
    local out = {}
    for _, d in ipairs(data.raw) do
        if d.mounted then
            table.insert(out, d)
        end
    end
    return out
end

local function render()
    local data = noctalia.state.get("udiskie_devices")
    local mounted = mountedDevices(data)
    local glyph = noctalia.getConfig("glyph") or "device-usb"
    local showCount = noctalia.getConfig("show_count")

    barWidget.setGlyph(glyph)

    if type(data) == "table" and data.error then
        barWidget.setGlyphColor("#f59e0b")
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("error_missing_dep"))
        return
    else
        -- Reset to the theme default. The API does not document "" as a reset;
        -- today it clears the role/color. Revisit if the host ever rejects it.
        barWidget.setGlyphColor("")
        barWidget.setColor("")
    end

    local hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true
    local rawCount = (type(data) == "table" and type(data.raw) == "table") and #data.raw or 0
    if hideWhenEmpty and rawCount == 0 then
        barWidget.setVisible(false)
        return
    else
        barWidget.setVisible(true)
    end

    if #mounted == 0 then
        barWidget.setText("")
        barWidget.setTooltip(noctalia.tr("tooltip_empty"))
        return
    end

    if showCount == nil or showCount == true then
        barWidget.setText(tostring(#mounted))
    else
        barWidget.setText("")
    end

    local rows = {}
    for _, d in ipairs(mounted) do
        table.insert(rows, d.label .. (d.mountPath ~= "" and (" (" .. d.mountPath .. ")") or ""))
    end
    barWidget.setTooltip(noctalia.tr("tooltip_mounted") .. "\n" .. table.concat(rows, "\n"))
end

noctalia.state.watch("udiskie_devices", function()
    render()
end)

function onClick()
    noctalia.togglePanel("aristides/udiskie:manager")
end

function onRightClick()
    noctalia.runAsync("noctalia msg plugin aristides/udiskie:service all refresh")
end

render()

