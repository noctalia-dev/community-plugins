--!nonstrict
-- App Launcher panel (UI only, no file access: that blows the per-call CPU budget).
-- Apps are indexed by the "indexer" service (indexer.luau) and shared through plugin
-- state: "pinned" and "all" lists of { id, name, exec, terminal, icon }.
-- Keep PANEL_WIDTH / PANEL_HEIGHT equal to `width` / `height` of the [[panel]] entry
-- in plugin.toml.

local PANEL_WIDTH = 900
local PANEL_HEIGHT = 780
local PANEL_PADDING = 16
-- Space taken by the title row, the tabs row and the gaps between rows. The grid
-- (ui.scroll) does not stretch to the panel height by itself, so it gets an explicit
-- height. If the bottom edge is cut off or too much space is left, tweak this number.
local HEADER_HEIGHT = 145
local SCROLL_HEIGHT = PANEL_HEIGHT - HEADER_HEIGHT - PANEL_PADDING
local SCROLLBAR_ALLOWANCE = 44
local GAP = 8
local MAX_HANDLERS = 400 -- launch_1 .. launch_400 are declared at the end of this file

local currentTab = "pinned"
local currentList = {}
local panelOpen = false
local editMode = false -- pin mode: a click pins / unpins an app instead of launching it
local pinnedSet = {} -- id -> true for the apps that are currently pinned
local pinSeq = 0

local function cfg(key, default)
    local ok, value = pcall(function()
        return panel.getConfig(key)
    end)
    if ok and value ~= nil then
        return value
    end
    ok, value = pcall(function()
        return noctalia.getConfig(key)
    end)
    if ok and value ~= nil then
        return value
    end
    return default
end

local SIZES = {
    small = { 900, 780 },
    medium = { 1100, 880 },
    large = { 1300, 980 },
    xl = { 1900, 980 },
}

-- The panel size is fixed by the [[panel]] entry that button.luau opens, so take the
-- same numbers from the "size" setting. Keep SIZES equal to the entries in plugin.toml.
local function applySize()
    local size = SIZES[cfg("panel_size", "small")]
    if size == nil then
        return
    end
    PANEL_WIDTH = size[1]
    PANEL_HEIGHT = size[2]
    SCROLL_HEIGHT = PANEL_HEIGHT - HEADER_HEIGHT - PANEL_PADDING
end

-- ------------------------------------------------------------------- launch

-- Pinning is stored by the indexer service (it owns the file access). The panel only
-- sends a request through plugin state; the indexer answers by republishing "pinned".
local function togglePin(entry)
    pinSeq = pinSeq + 1
    local ok, now = pcall(function()
        return noctalia.nowMs()
    end)
    noctalia.state.set("pin_request", {
        id = entry.id,
        action = pinnedSet[entry.id] and "unpin" or "pin",
        seq = pinSeq,
        t = ok and now or 0,
    })
end

local function launchIndex(i)
    local entry = currentList[i]
    if not entry then
        return
    end
    if editMode then
        togglePin(entry)
        return
    end
    if entry.terminal then
        noctalia.runInTerminal(entry.exec)
    else
        noctalia.runAsync(entry.exec)
    end
    panelOpen = false
    panel.close()
end

-- ------------------------------------------------------------------- render

local function appCell(entry, index, iconSize, cellW, cellH)
    local visual
    if entry.icon ~= nil and entry.icon ~= "" then
        visual = ui.image({
            path = entry.icon,
            width = iconSize,
            height = iconSize,
            fit = "contain",
        })
    else
        visual = ui.glyph({ name = "apps", size = iconSize })
    end

    -- Cells are retained between renders, and a prop that is simply left out is not
    -- reset. So the border is always passed explicitly (transparent when off), and the
    -- key changes while the pin border is shown so those cells are rebuilt cleanly.
    local border = "#00000000"
    local borderWidth = 0
    local keySuffix = ""
    if editMode and pinnedSet[entry.id] then
        border = "primary"
        borderWidth = 2
        keySuffix = "-pin"
    end

    -- Source badge: a small cube at the bottom right of the icon for Flatpak apps. An
    -- empty box of the same width sits on the left, so the icon stays centered either way.
    -- A ui.box without `fill` is drawn black, so the spacer boxes are made transparent.
    local BADGE = 14
    local function spacer()
        return ui.box({ width = BADGE, height = BADGE, fill = "#00000000" })
    end
    local badge
    if entry.flatpak then
        badge = ui.glyph({ name = "package", size = BADGE, color = "on_surface/0.6" })
    else
        badge = spacer()
    end
    local iconRow = ui.row({ align = "end", justify = "center", gap = 2 }, {
        spacer(),
        visual,
        badge,
    })

    return ui.column({
        key = "app-" .. entry.id .. keySuffix,
        fill = "surface_variant/0.45",
        radius = 12,
        border = border,
        borderWidth = borderWidth,
        padding = 6,
        paddingV = 8,
        gap = 4,
        align = "center",
        justify = "start", -- icons on one line whether the label has one or two rows
        width = cellW,
        height = cellH,
        onClick = "launch_" .. index,
    }, {
        iconRow,
        ui.label({
            text = entry.name,
            fontSize = 13,
            maxWidth = cellW - 14,
            maxLines = 2,
            textAlign = "center",
        }),
    })
end

local function messageBody(text)
    return ui.column({ flexGrow = 1, padding = 8 }, {
        ui.label({ text = text, color = "on_surface/0.6" }),
    })
end

local function buildGrid(apps)
    currentList = apps
    if #apps == 0 then
        return messageBody(noctalia.tr("empty"))
    end

    local columns = cfg("columns", 6)
    local iconSize = cfg("icon_size", 48)

    local usable = PANEL_WIDTH - 2 * PANEL_PADDING - SCROLLBAR_ALLOWANCE
    local cellW = math.floor((usable - GAP * (columns - 1)) / columns)
    local cellH = iconSize + 56

    local rows = {}
    local row = {}
    local total = math.min(#apps, MAX_HANDLERS)
    for i = 1, total do
        table.insert(row, appCell(apps[i], i, iconSize, cellW, cellH))
        if #row == columns or i == total then
            table.insert(rows, ui.row({ gap = GAP, align = "start" }, row))
            row = {}
        end
    end

    -- The host sizes a bare ui.scroll by its content, so the list is wrapped in a row of
    -- fixed height: a row stretches its children across the cross axis (its height).
    return ui.row({ height = SCROLL_HEIGHT }, {
        ui.scroll({ key = "grid-" .. currentTab, flexGrow = 1, gap = GAP, padding = 4 }, rows),
    })
end

-- Top-row button drawn as a filled container (no stock button, so no hover highlight):
-- blue when active, theme grey otherwise. The key includes the state so the retained
-- element is rebuilt when it flips.
local function barButton(key, text, glyph, active, handler)
    local textColor = active and "on_primary" or "on_surface"
    return ui.row({
        key = key .. (active and "-on" or "-off"),
        fill = active and "primary" or "on_surface/0.22",
        radius = 8,
        height = 38,
        flexGrow = 1,
        align = "center",
        justify = "center",
        gap = 6,
        onClick = handler,
    }, {
        ui.glyph({ name = glyph, size = 16, color = textColor }),
        ui.label({ text = text, fontSize = 13, color = textColor }),
    })
end

local function render()
    local pinned = noctalia.state.get("pinned")
    pinnedSet = {}
    if pinned ~= nil then
        for _, e in ipairs(pinned) do
            pinnedSet[e.id] = true
        end
    end
    local busy = (noctalia.state.get("ready") == false) -- the indexer is rebuilding the list
    local apps = noctalia.state.get(currentTab == "pinned" and "pinned" or "all")
    local body
    if apps == nil then
        currentList = {}
        body = messageBody(noctalia.tr("loading"))
    else
        body = buildGrid(apps)
    end

    panel.render(ui.column({ height = PANEL_HEIGHT, gap = 12, padding = PANEL_PADDING }, {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({
                text = editMode and noctalia.tr("title.edit") or noctalia.tr("title"),
                fontSize = 18,
                fontWeight = "bold",
                color = "primary",
                flexGrow = 1,
            }),
            ui.button({ glyph = "x", variant = "ghost", onClick = "onCloseClicked" }),
        }),
        ui.row({ gap = 8 }, {
            barButton("tab-pinned", noctalia.tr("tab.pinned"), "pin", currentTab == "pinned", "onTabPinned"),
            barButton("tab-all", noctalia.tr("tab.all"), "layout-grid", currentTab == "all", "onTabAll"),
            barButton(
                "act-refresh",
                busy and noctalia.tr("refresh.busy") or noctalia.tr("refresh.start"),
                "refresh",
                false,
                busy and "onRefreshBusy" or "onRefresh"
            ),
            barButton(
                "act-edit",
                editMode and noctalia.tr("edit.done") or noctalia.tr("edit.start"),
                editMode and "check" or "pencil",
                editMode,
                "onToggleEdit"
            ),
        }),
        body,
    }))
end

-- ----------------------------------------------------------------- callbacks

function onOpen(context)
    panelOpen = true
    currentTab = "pinned"
    editMode = false
    applySize()
    render()
end

function onTabPinned()
    currentTab = "pinned"
    render()
end

function onTabAll()
    currentTab = "all"
    render()
end

function onToggleEdit()
    editMode = not editMode
    render()
end

-- Refresh: ask the indexer service (it owns the file access) to rebuild the lists.
local refreshSeq = 0
function onRefreshBusy()
end

function onRefresh()
    refreshSeq = refreshSeq + 1
    local ok, now = pcall(function()
        return noctalia.nowMs()
    end)
    noctalia.state.set("refresh_request", {
        seq = refreshSeq,
        t = ok and now or 0,
    })
end

function onCloseClicked()
    panelOpen = false
    panel.close()
end

-- Re-render when the indexer publishes data while the panel is already open.
noctalia.state.watch("pinned", function(value)
    if panelOpen then
        pcall(render)
    end
end)
noctalia.state.watch("all", function(value)
    if panelOpen then
        pcall(render)
    end
end)
noctalia.state.watch("ready", function(value)
    if panelOpen then
        pcall(render)
    end
end)

-- ------------------------------------------------- click handlers (generated)
-- Callback props name global functions and globals cannot be created at runtime,
-- so one named function per grid cell is declared statically.
function launch_1() launchIndex(1) end
function launch_2() launchIndex(2) end
function launch_3() launchIndex(3) end
function launch_4() launchIndex(4) end
function launch_5() launchIndex(5) end
function launch_6() launchIndex(6) end
function launch_7() launchIndex(7) end
function launch_8() launchIndex(8) end
function launch_9() launchIndex(9) end
function launch_10() launchIndex(10) end
function launch_11() launchIndex(11) end
function launch_12() launchIndex(12) end
function launch_13() launchIndex(13) end
function launch_14() launchIndex(14) end
function launch_15() launchIndex(15) end
function launch_16() launchIndex(16) end
function launch_17() launchIndex(17) end
function launch_18() launchIndex(18) end
function launch_19() launchIndex(19) end
function launch_20() launchIndex(20) end
function launch_21() launchIndex(21) end
function launch_22() launchIndex(22) end
function launch_23() launchIndex(23) end
function launch_24() launchIndex(24) end
function launch_25() launchIndex(25) end
function launch_26() launchIndex(26) end
function launch_27() launchIndex(27) end
function launch_28() launchIndex(28) end
function launch_29() launchIndex(29) end
function launch_30() launchIndex(30) end
function launch_31() launchIndex(31) end
function launch_32() launchIndex(32) end
function launch_33() launchIndex(33) end
function launch_34() launchIndex(34) end
function launch_35() launchIndex(35) end
function launch_36() launchIndex(36) end
function launch_37() launchIndex(37) end
function launch_38() launchIndex(38) end
function launch_39() launchIndex(39) end
function launch_40() launchIndex(40) end
function launch_41() launchIndex(41) end
function launch_42() launchIndex(42) end
function launch_43() launchIndex(43) end
function launch_44() launchIndex(44) end
function launch_45() launchIndex(45) end
function launch_46() launchIndex(46) end
function launch_47() launchIndex(47) end
function launch_48() launchIndex(48) end
function launch_49() launchIndex(49) end
function launch_50() launchIndex(50) end
function launch_51() launchIndex(51) end
function launch_52() launchIndex(52) end
function launch_53() launchIndex(53) end
function launch_54() launchIndex(54) end
function launch_55() launchIndex(55) end
function launch_56() launchIndex(56) end
function launch_57() launchIndex(57) end
function launch_58() launchIndex(58) end
function launch_59() launchIndex(59) end
function launch_60() launchIndex(60) end
function launch_61() launchIndex(61) end
function launch_62() launchIndex(62) end
function launch_63() launchIndex(63) end
function launch_64() launchIndex(64) end
function launch_65() launchIndex(65) end
function launch_66() launchIndex(66) end
function launch_67() launchIndex(67) end
function launch_68() launchIndex(68) end
function launch_69() launchIndex(69) end
function launch_70() launchIndex(70) end
function launch_71() launchIndex(71) end
function launch_72() launchIndex(72) end
function launch_73() launchIndex(73) end
function launch_74() launchIndex(74) end
function launch_75() launchIndex(75) end
function launch_76() launchIndex(76) end
function launch_77() launchIndex(77) end
function launch_78() launchIndex(78) end
function launch_79() launchIndex(79) end
function launch_80() launchIndex(80) end
function launch_81() launchIndex(81) end
function launch_82() launchIndex(82) end
function launch_83() launchIndex(83) end
function launch_84() launchIndex(84) end
function launch_85() launchIndex(85) end
function launch_86() launchIndex(86) end
function launch_87() launchIndex(87) end
function launch_88() launchIndex(88) end
function launch_89() launchIndex(89) end
function launch_90() launchIndex(90) end
function launch_91() launchIndex(91) end
function launch_92() launchIndex(92) end
function launch_93() launchIndex(93) end
function launch_94() launchIndex(94) end
function launch_95() launchIndex(95) end
function launch_96() launchIndex(96) end
function launch_97() launchIndex(97) end
function launch_98() launchIndex(98) end
function launch_99() launchIndex(99) end
function launch_100() launchIndex(100) end
function launch_101() launchIndex(101) end
function launch_102() launchIndex(102) end
function launch_103() launchIndex(103) end
function launch_104() launchIndex(104) end
function launch_105() launchIndex(105) end
function launch_106() launchIndex(106) end
function launch_107() launchIndex(107) end
function launch_108() launchIndex(108) end
function launch_109() launchIndex(109) end
function launch_110() launchIndex(110) end
function launch_111() launchIndex(111) end
function launch_112() launchIndex(112) end
function launch_113() launchIndex(113) end
function launch_114() launchIndex(114) end
function launch_115() launchIndex(115) end
function launch_116() launchIndex(116) end
function launch_117() launchIndex(117) end
function launch_118() launchIndex(118) end
function launch_119() launchIndex(119) end
function launch_120() launchIndex(120) end
function launch_121() launchIndex(121) end
function launch_122() launchIndex(122) end
function launch_123() launchIndex(123) end
function launch_124() launchIndex(124) end
function launch_125() launchIndex(125) end
function launch_126() launchIndex(126) end
function launch_127() launchIndex(127) end
function launch_128() launchIndex(128) end
function launch_129() launchIndex(129) end
function launch_130() launchIndex(130) end
function launch_131() launchIndex(131) end
function launch_132() launchIndex(132) end
function launch_133() launchIndex(133) end
function launch_134() launchIndex(134) end
function launch_135() launchIndex(135) end
function launch_136() launchIndex(136) end
function launch_137() launchIndex(137) end
function launch_138() launchIndex(138) end
function launch_139() launchIndex(139) end
function launch_140() launchIndex(140) end
function launch_141() launchIndex(141) end
function launch_142() launchIndex(142) end
function launch_143() launchIndex(143) end
function launch_144() launchIndex(144) end
function launch_145() launchIndex(145) end
function launch_146() launchIndex(146) end
function launch_147() launchIndex(147) end
function launch_148() launchIndex(148) end
function launch_149() launchIndex(149) end
function launch_150() launchIndex(150) end
function launch_151() launchIndex(151) end
function launch_152() launchIndex(152) end
function launch_153() launchIndex(153) end
function launch_154() launchIndex(154) end
function launch_155() launchIndex(155) end
function launch_156() launchIndex(156) end
function launch_157() launchIndex(157) end
function launch_158() launchIndex(158) end
function launch_159() launchIndex(159) end
function launch_160() launchIndex(160) end
function launch_161() launchIndex(161) end
function launch_162() launchIndex(162) end
function launch_163() launchIndex(163) end
function launch_164() launchIndex(164) end
function launch_165() launchIndex(165) end
function launch_166() launchIndex(166) end
function launch_167() launchIndex(167) end
function launch_168() launchIndex(168) end
function launch_169() launchIndex(169) end
function launch_170() launchIndex(170) end
function launch_171() launchIndex(171) end
function launch_172() launchIndex(172) end
function launch_173() launchIndex(173) end
function launch_174() launchIndex(174) end
function launch_175() launchIndex(175) end
function launch_176() launchIndex(176) end
function launch_177() launchIndex(177) end
function launch_178() launchIndex(178) end
function launch_179() launchIndex(179) end
function launch_180() launchIndex(180) end
function launch_181() launchIndex(181) end
function launch_182() launchIndex(182) end
function launch_183() launchIndex(183) end
function launch_184() launchIndex(184) end
function launch_185() launchIndex(185) end
function launch_186() launchIndex(186) end
function launch_187() launchIndex(187) end
function launch_188() launchIndex(188) end
function launch_189() launchIndex(189) end
function launch_190() launchIndex(190) end
function launch_191() launchIndex(191) end
function launch_192() launchIndex(192) end
function launch_193() launchIndex(193) end
function launch_194() launchIndex(194) end
function launch_195() launchIndex(195) end
function launch_196() launchIndex(196) end
function launch_197() launchIndex(197) end
function launch_198() launchIndex(198) end
function launch_199() launchIndex(199) end
function launch_200() launchIndex(200) end
function launch_201() launchIndex(201) end
function launch_202() launchIndex(202) end
function launch_203() launchIndex(203) end
function launch_204() launchIndex(204) end
function launch_205() launchIndex(205) end
function launch_206() launchIndex(206) end
function launch_207() launchIndex(207) end
function launch_208() launchIndex(208) end
function launch_209() launchIndex(209) end
function launch_210() launchIndex(210) end
function launch_211() launchIndex(211) end
function launch_212() launchIndex(212) end
function launch_213() launchIndex(213) end
function launch_214() launchIndex(214) end
function launch_215() launchIndex(215) end
function launch_216() launchIndex(216) end
function launch_217() launchIndex(217) end
function launch_218() launchIndex(218) end
function launch_219() launchIndex(219) end
function launch_220() launchIndex(220) end
function launch_221() launchIndex(221) end
function launch_222() launchIndex(222) end
function launch_223() launchIndex(223) end
function launch_224() launchIndex(224) end
function launch_225() launchIndex(225) end
function launch_226() launchIndex(226) end
function launch_227() launchIndex(227) end
function launch_228() launchIndex(228) end
function launch_229() launchIndex(229) end
function launch_230() launchIndex(230) end
function launch_231() launchIndex(231) end
function launch_232() launchIndex(232) end
function launch_233() launchIndex(233) end
function launch_234() launchIndex(234) end
function launch_235() launchIndex(235) end
function launch_236() launchIndex(236) end
function launch_237() launchIndex(237) end
function launch_238() launchIndex(238) end
function launch_239() launchIndex(239) end
function launch_240() launchIndex(240) end
function launch_241() launchIndex(241) end
function launch_242() launchIndex(242) end
function launch_243() launchIndex(243) end
function launch_244() launchIndex(244) end
function launch_245() launchIndex(245) end
function launch_246() launchIndex(246) end
function launch_247() launchIndex(247) end
function launch_248() launchIndex(248) end
function launch_249() launchIndex(249) end
function launch_250() launchIndex(250) end
function launch_251() launchIndex(251) end
function launch_252() launchIndex(252) end
function launch_253() launchIndex(253) end
function launch_254() launchIndex(254) end
function launch_255() launchIndex(255) end
function launch_256() launchIndex(256) end
function launch_257() launchIndex(257) end
function launch_258() launchIndex(258) end
function launch_259() launchIndex(259) end
function launch_260() launchIndex(260) end
function launch_261() launchIndex(261) end
function launch_262() launchIndex(262) end
function launch_263() launchIndex(263) end
function launch_264() launchIndex(264) end
function launch_265() launchIndex(265) end
function launch_266() launchIndex(266) end
function launch_267() launchIndex(267) end
function launch_268() launchIndex(268) end
function launch_269() launchIndex(269) end
function launch_270() launchIndex(270) end
function launch_271() launchIndex(271) end
function launch_272() launchIndex(272) end
function launch_273() launchIndex(273) end
function launch_274() launchIndex(274) end
function launch_275() launchIndex(275) end
function launch_276() launchIndex(276) end
function launch_277() launchIndex(277) end
function launch_278() launchIndex(278) end
function launch_279() launchIndex(279) end
function launch_280() launchIndex(280) end
function launch_281() launchIndex(281) end
function launch_282() launchIndex(282) end
function launch_283() launchIndex(283) end
function launch_284() launchIndex(284) end
function launch_285() launchIndex(285) end
function launch_286() launchIndex(286) end
function launch_287() launchIndex(287) end
function launch_288() launchIndex(288) end
function launch_289() launchIndex(289) end
function launch_290() launchIndex(290) end
function launch_291() launchIndex(291) end
function launch_292() launchIndex(292) end
function launch_293() launchIndex(293) end
function launch_294() launchIndex(294) end
function launch_295() launchIndex(295) end
function launch_296() launchIndex(296) end
function launch_297() launchIndex(297) end
function launch_298() launchIndex(298) end
function launch_299() launchIndex(299) end
function launch_300() launchIndex(300) end
function launch_301() launchIndex(301) end
function launch_302() launchIndex(302) end
function launch_303() launchIndex(303) end
function launch_304() launchIndex(304) end
function launch_305() launchIndex(305) end
function launch_306() launchIndex(306) end
function launch_307() launchIndex(307) end
function launch_308() launchIndex(308) end
function launch_309() launchIndex(309) end
function launch_310() launchIndex(310) end
function launch_311() launchIndex(311) end
function launch_312() launchIndex(312) end
function launch_313() launchIndex(313) end
function launch_314() launchIndex(314) end
function launch_315() launchIndex(315) end
function launch_316() launchIndex(316) end
function launch_317() launchIndex(317) end
function launch_318() launchIndex(318) end
function launch_319() launchIndex(319) end
function launch_320() launchIndex(320) end
function launch_321() launchIndex(321) end
function launch_322() launchIndex(322) end
function launch_323() launchIndex(323) end
function launch_324() launchIndex(324) end
function launch_325() launchIndex(325) end
function launch_326() launchIndex(326) end
function launch_327() launchIndex(327) end
function launch_328() launchIndex(328) end
function launch_329() launchIndex(329) end
function launch_330() launchIndex(330) end
function launch_331() launchIndex(331) end
function launch_332() launchIndex(332) end
function launch_333() launchIndex(333) end
function launch_334() launchIndex(334) end
function launch_335() launchIndex(335) end
function launch_336() launchIndex(336) end
function launch_337() launchIndex(337) end
function launch_338() launchIndex(338) end
function launch_339() launchIndex(339) end
function launch_340() launchIndex(340) end
function launch_341() launchIndex(341) end
function launch_342() launchIndex(342) end
function launch_343() launchIndex(343) end
function launch_344() launchIndex(344) end
function launch_345() launchIndex(345) end
function launch_346() launchIndex(346) end
function launch_347() launchIndex(347) end
function launch_348() launchIndex(348) end
function launch_349() launchIndex(349) end
function launch_350() launchIndex(350) end
function launch_351() launchIndex(351) end
function launch_352() launchIndex(352) end
function launch_353() launchIndex(353) end
function launch_354() launchIndex(354) end
function launch_355() launchIndex(355) end
function launch_356() launchIndex(356) end
function launch_357() launchIndex(357) end
function launch_358() launchIndex(358) end
function launch_359() launchIndex(359) end
function launch_360() launchIndex(360) end
function launch_361() launchIndex(361) end
function launch_362() launchIndex(362) end
function launch_363() launchIndex(363) end
function launch_364() launchIndex(364) end
function launch_365() launchIndex(365) end
function launch_366() launchIndex(366) end
function launch_367() launchIndex(367) end
function launch_368() launchIndex(368) end
function launch_369() launchIndex(369) end
function launch_370() launchIndex(370) end
function launch_371() launchIndex(371) end
function launch_372() launchIndex(372) end
function launch_373() launchIndex(373) end
function launch_374() launchIndex(374) end
function launch_375() launchIndex(375) end
function launch_376() launchIndex(376) end
function launch_377() launchIndex(377) end
function launch_378() launchIndex(378) end
function launch_379() launchIndex(379) end
function launch_380() launchIndex(380) end
function launch_381() launchIndex(381) end
function launch_382() launchIndex(382) end
function launch_383() launchIndex(383) end
function launch_384() launchIndex(384) end
function launch_385() launchIndex(385) end
function launch_386() launchIndex(386) end
function launch_387() launchIndex(387) end
function launch_388() launchIndex(388) end
function launch_389() launchIndex(389) end
function launch_390() launchIndex(390) end
function launch_391() launchIndex(391) end
function launch_392() launchIndex(392) end
function launch_393() launchIndex(393) end
function launch_394() launchIndex(394) end
function launch_395() launchIndex(395) end
function launch_396() launchIndex(396) end
function launch_397() launchIndex(397) end
function launch_398() launchIndex(398) end
function launch_399() launchIndex(399) end
function launch_400() launchIndex(400) end
