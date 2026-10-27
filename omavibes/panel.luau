--!nonstrict
-- OmaVibes — panel entry point.
-- Browse soundpacks, adjust volume, view typing profile/ranks, and inspect analytics.

local activeTab = "packs"
local searchFilter = ""
local currentVolume = 3
local activePack = ""
local isPlaying = false

local PACKS = {
    { name = "Akko Lavender Purples", folder = "akko_lavender_purples" },
    { name = "NK Cream", folder = "nk-cream" },
    { name = "Cherry MX Blue (ABS)", folder = "cherrymx-blue-abs" },
    { name = "Cherry MX Blue (PBT)", folder = "cherrymx-blue-pbt" },
    { name = "Cherry MX Brown (PBT)", folder = "cherrymx-brown-pbt" },
    { name = "Cherry MX Red (ABS)", folder = "cherrymx-red-abs" },
    { name = "Cherry MX Red (PBT)", folder = "cherrymx-red-pbt" },
    { name = "Cherry MX Black (ABS)", folder = "cherrymx-black-abs" },
    { name = "Cherry MX Black (PBT)", folder = "cherrymx-black-pbt" },
    { name = "Lincoln Typewriter", folder = "Lincoln Typewriter" },
    { name = "Topre", folder = "topre" },
    { name = "IBM Buckling Spring", folder = "IBM-buckling-spring" },
    { name = "Banana Split Lubed", folder = "banana split lubed" },
    { name = "Drop Holy Panda", folder = "drop-holy-panda" },
    { name = "Durock Alpaca", folder = "durock-alpaca" },
    { name = "Gateron Ink Black", folder = "gateron-ink-black" },
    { name = "Gateron Ink Red", folder = "gateron-ink-red" },
    { name = "Gateron Turquoise Tealios", folder = "gateron-turquoise-tealios" },
    { name = "Kailh Box Navy", folder = "kailh-box-navy" },
    { name = "NovelKeys Cream", folder = "novelkeys-cream" },
    { name = "Thocks", folder = "Thocks" },
    { name = "Chalks", folder = "chalks" },
    { name = "Box Jade", folder = "boxjade" },
    { name = "Alps SKCM Blue", folder = "alps-skcm-blue" },
    { name = "EG Oreo", folder = "eg-oreo" },
    { name = "Dino Alpacas", folder = "Dino_Alpacas" },
    { name = "Tealios v2 Akira", folder = "tealios-v2_Akira" },
    { name = "Razer Green (Blackwidow Elite)", folder = "Razer Green (Blackwidow Elite) - Akira" },
    { name = "Trust GXT 865 ASTA", folder = "Trust_GXT_865_ASTA" },
    { name = "8 Bit", folder = "8 bit" },
    { name = "Animal Crossing NL", folder = "animal_crossing_nl" },
    { name = "Bullet Passing", folder = "bullet_passing" },
    { name = "Cloth", folder = "cloth" },
    { name = "Farts", folder = "Farts" },
    { name = "Fight", folder = "Fight" },
    { name = "Glass", folder = "Glass" },
    { name = "Glitch", folder = "glitch" },
    { name = "GX Verdock", folder = "gx-verdock" },
    { name = "Horse", folder = "horse" },
    { name = "Kalimba", folder = "Kalimba" },
    { name = "Koala", folder = "Koala" },
    { name = "OSU", folder = "osu" },
    { name = "Penumbra", folder = "penumbra" },
    { name = "Piano", folder = "Piano" },
    { name = "Press", folder = "Press" },
    { name = "Saber", folder = "Saber" },
    { name = "Shadowgun", folder = "shadowgun" },
    { name = "Shutter", folder = "shutter" },
    { name = "Sine Bumps 2", folder = "sine bumps 2" },
    { name = "Sword", folder = "Sword" },
    { name = "Trails in the Sky", folder = "trails-in-the-sky" },
    { name = "Water", folder = "water" },
}

local render

local function sendCmd(action, pack, vol)
    noctalia.state.set("omavibes_cmd", {
        action = action,
        pack = pack,
        volume = vol or currentVolume,
    })
end

local function triggerPlay(folder)
    activePack = folder
    sendCmd("play", folder, currentVolume)
    render()
end

local function triggerStop()
    activePack = ""
    sendCmd("stop")
    render()
end

local function triggerRandom()
    local candidates = {}
    for _, item in ipairs(PACKS) do
        if searchFilter == "" or item.name:lower():find(searchFilter:lower(), 1, true) then
            table.insert(candidates, item)
        end
    end
    if #candidates > 0 then
        local chosen = candidates[math.random(1, #candidates)]
        triggerPlay(chosen.folder)
    end
end

-- Soundpacks Tab View
local function buildPacksTab()
    local children = {}

    -- Search, Random, Turn Off Bar
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        ui.input({
            key = "pack_search",
            placeholder = noctalia.tr("search_placeholder"),
            text = searchFilter,
            flexGrow = 1,
            onChange = function(val)
                searchFilter = val or ""
                render()
            end,
        }),
        ui.button({
            key = "btn_random",
            glyph = "shuffle",
            tooltip = noctalia.tr("btn_random"),
            variant = "outline",
            onClick = triggerRandom,
        }),
        ui.button({
            key = "btn_off",
            glyph = "power",
            tooltip = noctalia.tr("btn_turn_off"),
            variant = isPlaying and "error" or "ghost",
            onClick = triggerStop,
        }),
    }))

    -- Volume Slider Row
    table.insert(children, ui.row({ gap = 12, align = "center", padding = 4 }, {
        ui.glyph({ name = "volume-2", size = 18, color = "on_surface_variant" }),
        ui.slider({
            key = "volume_slider",
            min = 1,
            max = 10,
            step = 1,
            value = currentVolume,
            flexGrow = 1,
            controlSize = "sm",
            onChange = function(val)
                currentVolume = tonumber(val) or 3
                sendCmd("volume", activePack, currentVolume)
                render()
            end,
        }),
        ui.label({ text = tostring(currentVolume), fontSize = 12, color = "primary", width = 24, textAlign = "end" }),
    }))

    table.insert(children, ui.separator({ thickness = 1 }))

    -- Soundpacks Grid / List
    local cards = {}
    for _, item in ipairs(PACKS) do
        if searchFilter == "" or item.name:lower():find(searchFilter:lower(), 1, true) then
            local isSelected = isPlaying and (activePack == item.folder)
            table.insert(cards, ui.row({
                key = "pack_" .. item.folder,
                gap = 10,
                align = "center",
                padding = 8,
                radius = 8,
                fill = isSelected and "surface_container" or "surface",
                border = isSelected and "primary" or "outline_variant/0.3",
                borderWidth = 1,
            }, {
                ui.glyph({
                    name = isSelected and "disc" or "circle",
                    color = isSelected and "primary" or "outline_variant",
                    size = 16,
                }),
                ui.label({
                    text = item.name,
                    fontWeight = isSelected and "bold" or "normal",
                    color = isSelected and "primary" or "on_surface",
                    flexGrow = 1,
                }),
                ui.button({
                    key = "play_" .. item.folder,
                    glyph = isSelected and "check" or "play",
                    variant = isSelected and "primary" or "ghost",
                    controlSize = "sm",
                    onClick = function()
                        triggerPlay(item.folder)
                    end,
                }),
            }))
        end
    end

    table.insert(children, ui.scroll({ key = "pack_scroll", flexGrow = 1, gap = 6 }, cards))
    return children
end

-- Profile Tab View
local function buildProfileTab()
    return {
        ui.column({ gap = 14, align = "stretch" }, {
            ui.row({ gap = 16, align = "center", padding = 16, radius = 12, fill = "surface_container" }, {
                ui.glyph({ name = "award", size = 36, color = "primary" }),
                ui.column({ gap = 4, flexGrow = 1 }, {
                    ui.label({ text = noctalia.tr("rank_touch"), fontSize = 16, fontWeight = "bold", color = "primary" }),
                    ui.label({ text = "Level 2: 12,450 / 25,000 words to " .. noctalia.tr("rank_enthusiast"), fontSize = 12, color = "on_surface_variant" }),
                }),
            }),
            ui.label({ text = noctalia.tr("achievements"), fontSize = 14, fontWeight = "bold" }),
            ui.row({ gap = 10, padding = 10, radius = 8, fill = "surface_container/0.5", align = "center" }, {
                ui.glyph({ name = "check-circle", color = "primary", size = 20 }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = "First Keystroke", fontWeight = "bold", fontSize = 13 }),
                    ui.label({ text = "Typed your first cozy sentence with OmaVibes", fontSize = 11, color = "on_surface_variant" }),
                }),
            }),
            ui.row({ gap = 10, padding = 10, radius = 8, fill = "surface_container/0.5", align = "center" }, {
                ui.glyph({ name = "check-circle", color = "primary", size = 20 }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = "Marathon Typist", fontWeight = "bold", fontSize = 13 }),
                    ui.label({ text = "Reached over 10,000 lifetime words", fontSize = 11, color = "on_surface_variant" }),
                }),
            }),
            ui.row({ gap = 10, padding = 10, radius = 8, fill = "surface_container/0.5", align = "center" }, {
                ui.glyph({ name = "circle", color = "outline_variant", size = 20 }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = "Speed Demon", fontWeight = "bold", fontSize = 13 }),
                    ui.label({ text = "Maintain 80+ WPM sustained for 5 minutes", fontSize = 11, color = "on_surface_variant" }),
                }),
            }),
        }),
    }
end

-- Analytics Tab View
local function buildAnalyticsTab()
    return {
        ui.column({ gap = 14, align = "stretch" }, {
            ui.row({ gap = 12 }, {
                ui.column({ flexGrow = 1, padding = 12, radius = 8, fill = "surface_container" }, {
                    ui.label({ text = noctalia.tr("words_today"), fontSize = 11, color = "on_surface_variant" }),
                    ui.label({ text = "1,842", fontSize = 22, fontWeight = "bold", color = "primary" }),
                }),
                ui.column({ flexGrow = 1, padding = 12, radius = 8, fill = "surface_container" }, {
                    ui.label({ text = noctalia.tr("typing_time"), fontSize = 11, color = "on_surface_variant" }),
                    ui.label({ text = "54m", fontSize = 22, fontWeight = "bold", color = "primary" }),
                }),
                ui.column({ flexGrow = 1, padding = 12, radius = 8, fill = "surface_container" }, {
                    ui.label({ text = noctalia.tr("total_keys"), fontSize = 11, color = "on_surface_variant" }),
                    ui.label({ text = "9,210", fontSize = 22, fontWeight = "bold", color = "primary" }),
                }),
            }),
            ui.label({ text = noctalia.tr("most_used_keys"), fontSize = 14, fontWeight = "bold" }),
            ui.column({ gap = 6, padding = 12, radius = 8, fill = "surface_container" }, {
                ui.row({ justify = "space_between" }, { ui.label({ text = "Space" }), ui.label({ text = "1,420 (15.4%)", color = "primary" }) }),
                ui.row({ justify = "space_between" }, { ui.label({ text = "E" }), ui.label({ text = "1,110 (12.1%)", color = "primary" }) }),
                ui.row({ justify = "space_between" }, { ui.label({ text = "T" }), ui.label({ text = "890 (9.7%)", color = "primary" }) }),
                ui.row({ justify = "space_between" }, { ui.label({ text = "A" }), ui.label({ text = "820 (8.9%)", color = "primary" }) }),
                ui.row({ justify = "space_between" }, { ui.label({ text = "Backspace" }), ui.label({ text = "640 (6.9%)", color = "on_surface_variant" }) }),
            }),
        }),
    }
end

render = function()
    local tabs = {
        { id = "packs", glyph = "music", label = noctalia.tr("tab_packs"), build = buildPacksTab },
        { id = "profile", glyph = "award", label = noctalia.tr("tab_profile"), build = buildProfileTab },
        { id = "analytics", glyph = "bar-chart-2", label = noctalia.tr("tab_analytics"), build = buildAnalyticsTab },
    }

    local tabButtons = {}
    for _, t in ipairs(tabs) do
        table.insert(tabButtons, ui.button({
            key = "tab_" .. t.id,
            text = t.label,
            glyph = t.glyph,
            variant = (activeTab == t.id) and "primary" or "ghost",
            flexGrow = 1,
            onClick = function()
                activeTab = t.id
                render()
            end,
        }))
    end

    local tabContent
    for _, t in ipairs(tabs) do
        if t.id == activeTab then
            tabContent = t.build()
            break
        end
    end

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "keyboard", size = 20, color = "primary" }),
            ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
            ui.button({
                key = "btn_settings",
                glyph = "settings",
                variant = "ghost",
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                key = "btn_close",
                glyph = "close",
                variant = "ghost",
                onClick = function()
                    panel.close()
                end,
            }),
        }),
        ui.row({ gap = 6 }, tabButtons),
        ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, tabContent),
    }

    panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 16, align = "stretch" }, children))
end

noctalia.state.watch("omavibes_playing", function(val)
    isPlaying = (val == true)
    render()
end)

noctalia.state.watch("omavibes_pack", function(val)
    activePack = tostring(val or "")
    render()
end)

noctalia.state.watch("omavibes_volume", function(val)
    if val then
        currentVolume = tonumber(val) or currentVolume
        render()
    end
end)

function onOpen()
    render()
end

function onClose()
end
