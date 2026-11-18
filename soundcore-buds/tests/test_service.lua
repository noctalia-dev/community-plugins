-- Service assertions. Runs after stubs + service.luau.
print("== service snapshot ==")
local snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap, "no snapshot published")
assert(snap.connected == true, "expected connected")
assert(snap.modelId == "SoundcoreD1202C", "modelId: " .. tostring(snap.modelId))
assert(snap.modelName == "Soundcore R60i NC", "modelName: " .. tostring(snap.modelName))
assert(snap.noiseMode == 3, "noiseMode expected 3 (Adaptive), got " .. tostring(snap.noiseMode))
assert(snap.left.level == 100, "left expected 100, got " .. tostring(snap.left.level))
assert(snap.right.level == 90, "right expected 90, got " .. tostring(snap.right.level))
assert(snap.caseBattery.level == 80, "case expected 80, got " .. tostring(snap.caseBattery.level))
assert(snap.right.charging == true, "right should be charging")
assert(snap.manualAnc == 5, "manualAnc expected 5")
assert(#snap.availableModes == 4, "modes expected 4, got " .. #snap.availableModes)
assert(snap.primaryText == "90%", "primary expected 90%, got " .. tostring(snap.primaryText))
assert(snap.supportsManualAnc == true, "supportsManualAnc")
print("snapshot OK:", snap.primaryText, snap.noiseModeName)

print("== in-case tracking (tws connected: charging implies in case) ==")
-- left not charging + tws connected -> worn; right charging -> in case.
assert(snap.leftMeta == "panel.in_ear", "leftMeta expected in_ear, got " .. tostring(snap.leftMeta))
assert(snap.rightMeta == "panel.charging", "rightMeta expected charging, got " .. tostring(snap.rightMeta))
print("in-case OK")

print("== touch payload ==")
assert(snap.touch.available == true, "touch should be available")
assert(#snap.touch.controls == 8, "expected 8 touch controls, got " .. #snap.touch.controls)
assert(snap.touch.reset == true, "touch reset should be supported")
assert(snap.touch.supportsTone == true, "touch tone should be supported")
assert(snap.touch.tone == true, "touch tone expected true")
local first = snap.touch.controls[1]
assert(first.id == "leftSinglePress", "first control id, got " .. tostring(first.id))
assert(first.label == "panel.touch.left_single", "first control label, got " .. tostring(first.label))
assert(first.value == "PlayPause", "first control value, got " .. tostring(first.value))
assert(#first.options == 5, "first control options (Off + 4), got " .. #first.options)
assert(first.options[1].id == "" and first.options[1].label == "panel.touch.off", "Off option")
assert(first.options[2].label == "Volume Up", "localized label passthrough")
local third = snap.touch.controls[3]
assert(third.options[2].label == "Volume Up", "humanized fallback label, got " .. tostring(third.options[2].label))
print("touch payload OK")

print("== command: cycle-noise (Adaptive -> ANC) ==")
watchers["sankity/soundcore-buds:command"]({ action = "cycle-noise", nonce = "t1" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.noiseMode == 1, "after cycle expected ANC(1), got " .. tostring(snap.noiseMode))
print("cycle-noise OK")

print("== topMode + set-cancel-mode ==")
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.topMode == 1, "topMode ANC, got " .. tostring(snap.topMode))
assert(snap.noiseCancelMode == "Adaptive", "cancel mode, got " .. tostring(snap.noiseCancelMode))
assert(snap.subModeName == "panel.mode.adaptive", "sub name")
watchers["sankity/soundcore-buds:command"]({ action = "set-cancel-mode", value = "Manual", nonce = "c1" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.noiseCancelMode == "Manual", "cancel Manual")
assert(snap.subModeName == "panel.cancel.manual", "sub name manual")
watchers["sankity/soundcore-buds:command"]({ action = "set-cancel-mode", value = "Bogus", nonce = "c2" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.noiseCancelMode == "Manual", "bogus cancel rejected")
print("cancel-mode OK")

print("== command: set-anc-level 3 ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-anc-level", value = 3, nonce = "t2" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.manualAnc == 3, "manualAnc expected 3, got " .. tostring(snap.manualAnc))
assert(snap.noiseMode == 1, "noiseMode should be ANC")
print("set-anc-level OK")

print("== command: set-touch leftDoublePress -> VolumeUp ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-touch", value = { id = "leftDoublePress", value = "VolumeUp" }, nonce = "t3" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
local found = nil
for _, c in ipairs(snap.touch.controls) do
	if c.id == "leftDoublePress" then found = c.value end
end
assert(found == "VolumeUp", "leftDoublePress expected VolumeUp, got " .. tostring(found))
print("set-touch OK")

print("== command: set-touch rejects unknown id/value ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-touch", value = { id = "nope", value = "VolumeUp" }, nonce = "t4" })
watchers["sankity/soundcore-buds:command"]({ action = "set-touch", value = { id = "leftDoublePress", value = "Bogus" }, nonce = "t5" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
found = nil
for _, c in ipairs(snap.touch.controls) do
	if c.id == "leftDoublePress" then found = c.value end
end
assert(found == "VolumeUp", "value must be unchanged, got " .. tostring(found))
print("set-touch validation OK")

print("== command: touch-tone off, touch-reset ==")
watchers["sankity/soundcore-buds:command"]({ action = "touch-tone", value = false, nonce = "t6" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.touch.tone == false, "tone expected false")
watchers["sankity/soundcore-buds:command"]({ action = "touch-reset", value = nil, nonce = "t7" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
for _, c in ipairs(snap.touch.controls) do
	assert(c.value == "PlayPause", "after reset expected PlayPause, got " .. tostring(c.value))
end
print("touch-tone + touch-reset OK")

print("== onIpc refresh ==")
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "still connected after refresh")
print("refresh OK")

print("== find start / switch / complete ==")
DEFER_FIND = true
watchers["sankity/soundcore-buds:command"]({ action = "find", value = "left", nonce = "f1" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.findingSide == "left", "findingSide expected left, got " .. tostring(snap.findingSide))
assert(DEFERRED_CB ~= nil, "find process should be running")
assert(string.find(captured.findCalls[#captured.findCalls], "find.sh left 34:09:C9:6E:F6:D6", 1, true), "find argv")
watchers["sankity/soundcore-buds:command"]({ action = "find", value = "right", nonce = "f2" })
local stops = captured.stopCalls or {}
assert(#stops == 1 and string.find(stops[1], "stop %-%-hold", 1), "switch must stop with --hold")
local cb = DEFERRED_CB; DEFERRED_CB = nil
cb({ exitCode = 0, stdout = "", stderr = "" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.findingSide == "right", "queued find should start, got " .. tostring(snap.findingSide))
cb = DEFERRED_CB; DEFERRED_CB = nil
cb({ exitCode = 0, stdout = "", stderr = "" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.findingSide == "", "findingSide cleared after tone ends")
print("find lifecycle OK")

print("== find validation ==")
watchers["sankity/soundcore-buds:command"]({ action = "find", value = "both", nonce = "f3" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.findingSide == "", "invalid side must be ignored")
watchers["sankity/soundcore-buds:command"]({ action = "stop-find", value = nil, nonce = "f4" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.findingSide == "", "idle stop-find harmless")
DEFER_FIND = false
print("find validation OK")

print("== onIpc allowlist ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-touch", value = { id = "leftDoublePress", value = "VolumeUp" }, nonce = "t8" })
onIpc("touch-reset", nil)
onIpc("set-anc-level", nil)
onIpc("touch-tone", nil)
onIpc("set-noise", 0)
onIpc("bogus-verb", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
local dbl = nil
for _, c in ipairs(snap.touch.controls) do
	if c.id == "leftDoublePress" then dbl = c.value end
end
assert(dbl == "VolumeUp", "IPC touch-reset must be ignored, got " .. tostring(dbl))
assert(snap.manualAnc == 3, "IPC set-anc-level nil must be ignored, got " .. tostring(snap.manualAnc))
assert(snap.noiseMode == 1, "IPC set-noise must be ignored, got " .. tostring(snap.noiseMode))
print("onIpc allowlist OK")

print("== sound selects/toggles ==")
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.sound.selects.transparencyMode.value == "FullyTransparent", "transparency value")
assert(snap.sound.selects.multiSceneNoiseCanceling.value == "Outdoor", "multiscene value")
assert(snap.sound.toggles.windNoiseSuppression == true, "wind toggle")
assert(snap.sound.limitDb == 100, "limit db")
assert(snap.info.fwL == "04.89", "fw left")
assert(snap.info.serial == "ABC123", "serial")
assert(snap.info.adaptive == "Weak", "adaptive level")
assert(#snap.info.dualDevices == 1, "dual devices")
print("sound snapshot OK")

print("== command: set-select / set-toggle / set-int ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-select", value = { id = "autoPowerOff", value = "10m" }, nonce = "s1" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.sound.selects.autoPowerOff.value == "10m", "auto-off after set")
watchers["sankity/soundcore-buds:command"]({ action = "set-select", value = { id = "autoPowerOff", value = "Bogus" }, nonce = "s2" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.sound.selects.autoPowerOff.value == "10m", "bogus select rejected")
watchers["sankity/soundcore-buds:command"]({ action = "set-toggle", value = { id = "windNoiseSuppression", enabled = false }, nonce = "s3" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.sound.toggles.windNoiseSuppression == false, "wind off")
watchers["sankity/soundcore-buds:command"]({ action = "set-int", value = { id = "limitHighVolumeDbLimit", value = 200 }, nonce = "s4" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.sound.limitDb == 100, "limit clamped to max, got " .. tostring(snap.sound.limitDb))
watchers["sankity/soundcore-buds:command"]({ action = "set-int", value = { id = "limitHighVolumeDbLimit", value = 10 }, nonce = "s5" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.sound.limitDb == 75, "limit clamped to min, got " .. tostring(snap.sound.limitDb))
watchers["sankity/soundcore-buds:command"]({ action = "set-select", value = { id = "nope", value = "x" }, nonce = "s6" })
print("sound commands OK")
print("== control busy keeps stale visible ==")
FAIL_NEXT_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "busy must stay connected")
assert(snap.stale == true, "busy must set stale")
assert(string.find(snap.lastError, "errors.control_busy", 1, true), "busy hint, got " .. tostring(snap.lastError))
print("busy state OK")

print("== recovery after busy ==")
FAIL_NEXT_QUERY = false
NOW_MS = NOW_MS + 31000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "recovered")
print("recovery OK")

print("== explicit gone hides immediately ==")
PAIRED_EMPTY = true
NOW_MS = NOW_MS + 31000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == false, "gone must disconnect")
assert(snap.stale == false, "gone must clear stale")
PAIRED_EMPTY = false
NOW_MS = NOW_MS + 5000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "reconnected")
print("gone/reconnect OK")

print("== healthy refresh skips fast-path extra call ==")
INFO_CALLS = 0
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "healthy stays connected")
assert(INFO_CALLS == 1, "healthy refresh must use chain only (1 info call), got " .. tostring(INFO_CALLS))
print("healthy fast-path skip OK")

print("== unknown error stays stale-visible ==")
FAIL_UNKNOWN_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "unknown must stay connected")
assert(snap.stale == true, "unknown must set stale")
assert(snap.hasBattery == true, "unknown must keep battery")
FAIL_UNKNOWN_QUERY = false
NOW_MS = NOW_MS + 31000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "recovered after unknown")
print("unknown error OK")

print("== generic disconnected stays stale-visible ==")
FAIL_GENERIC_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "generic error must stay connected")
assert(snap.stale == true, "generic error must set stale")
FAIL_GENERIC_QUERY = false
NOW_MS = NOW_MS + 31000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "recovered after generic")
print("generic error OK")

print("== gone marker with transport up stays busy ==")
FAIL_GONE_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "unconfirmed gone must stay connected")
assert(snap.stale == true, "unconfirmed gone must set stale")
assert(snap.hasBattery == true, "unconfirmed gone must keep battery")
FAIL_GONE_QUERY = false
NOW_MS = NOW_MS + 31000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "recovered after unconfirmed gone")
print("gone verify-block OK")

print("== gone marker with transport down hides ==")
FAIL_GONE_QUERY = true
BT_DOWN = false
local origRun = noctalia.runAsync
local verifyInfos = 0
noctalia.runAsync = function(argv, cb, timeout)
	if argv[1] == "bluetoothctl" and argv[2] == "info" then
		verifyInfos = verifyInfos + 1
		if verifyInfos >= 2 then BT_DOWN = true end
	end
	return origRun(argv, cb, timeout)
end
onIpc("refresh", nil)
noctalia.runAsync = origRun
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == false, "confirmed gone must disconnect")
assert(snap.stale == false, "confirmed gone must clear stale")
assert(snap.hasBattery == false, "confirmed gone must clear battery")
assert(snap.primaryText == "--", "confirmed gone must reset primary text, got " .. tostring(snap.primaryText))
assert(string.find(tostring(snap.lastError), "device not found", 1, true), "gone keeps raw error, got " .. tostring(snap.lastError))
FAIL_GONE_QUERY = false
BT_DOWN = false
NOW_MS = NOW_MS + 1000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "reconnected after confirmed gone")
print("gone verify-confirm OK")

print("== fast-path disconnect during busy cooldown ==")
FAIL_NEXT_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == true, "busy must stay stale-visible")
BT_DOWN = true
NOW_MS = NOW_MS + 1000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == false, "fast-path must disconnect inside cooldown")
assert(snap.stale == false, "fast-path must clear stale")
BT_DOWN = false
FAIL_NEXT_QUERY = false
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "cooldown must be cleared by gone (immediate reconnect)")
print("fast-path OK")

print("== cased bud quarantines bad id and recovers ==")
FAIL_BAD_ID_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "quarantine retry must stay connected")
assert(snap.stale == false, "quarantine retry must clear stale")
assert(snap.lastError == "", "quarantine retry must clear error, got " .. tostring(snap.lastError))
assert(snap.left.level == -1, "cased bud must show unknown, got " .. tostring(snap.left.level))
assert(snap.leftText == "--", "cased bud text must reset, got " .. tostring(snap.leftText))
assert(snap.right.level == 90, "other bud must keep updating, got " .. tostring(snap.right.level))
assert(snap.hasBattery == true, "hasBattery from remaining pods")
print("quarantine OK")

print("== busy hint names quarantined id ==")
FAIL_NEXT_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == true, "busy stays stale-visible")
assert(string.find(tostring(snap.lastError), "not reporting: batteryLevelLeft", 1, true), "hint must name quarantined id, got " .. tostring(snap.lastError))
FAIL_NEXT_QUERY = false
NOW_MS = NOW_MS + 31000
print("quarantine note OK")

print("== bud out heals fast on topology flip ==")
FAIL_BAD_ID_QUERY = false
GET_VALUES.twsStatus = "Disconnected"
LIST_CALLS = 0
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "topo flip poll must stay connected")
assert(snap.left.level == -1, "id not yet re-queried on trigger poll, got " .. tostring(snap.left.level))
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.left.level == 100, "returned bud reports again, got " .. tostring(snap.left.level))
assert(LIST_CALLS >= 1, "topo flip must force a fresh listing")
GET_VALUES.twsStatus = "Connected"
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "align poll must stay connected")
print("topo heal OK")

print("== re-read drops silently vanished id ==")
FAIL_BAD_ID_QUERY = true
LIST_OMIT_LEFT = true
LIST_CALLS = 0
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "quarantine retry must stay connected")
assert(snap.left.level == -1, "cased bud unknown")
NOW_MS = NOW_MS + 300000
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "re-read must stay connected")
assert(snap.left.level == -1, "vanished id stays unknown, got " .. tostring(snap.left.level))
assert(LIST_CALLS == 1, "expiry must trigger exactly one re-read, got " .. tostring(LIST_CALLS))
LIST_OMIT_LEFT = false
FAIL_BAD_ID_QUERY = false
GET_VALUES.twsStatus = "Disconnected"
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "restore poll must stay connected")
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.left.level == 100, "restored listing heals, got " .. tostring(snap.left.level))
GET_VALUES.twsStatus = "Connected"
print("omit re-read OK")

print("== repeat rejection re-reads on every expiry ==")
LIST_CALLS = 0
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "settling poll must stay connected")
LIST_CALLS = 0
FAIL_BAD_ID_QUERY = true
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "quarantine must stay connected")
assert(snap.left.level == -1, "cased bud unknown")
NOW_MS = NOW_MS + 300000
LIST_CALLS = 0
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.stale == false, "second rejection must stay connected")
assert(snap.left.level == -1, "cased bud stays unknown")
assert(LIST_CALLS == 1, "expiry must trigger exactly one re-read, got " .. tostring(LIST_CALLS))
FAIL_BAD_ID_QUERY = false
GET_VALUES.twsStatus = "Disconnected"
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "cleanup poll must stay connected")
onIpc("refresh", nil)
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true and snap.left.level == 100, "cleanup heal must restore bud")
GET_VALUES.twsStatus = "Connected"
print("expiry re-read OK")

print("== watchdog resets stuck poll ==")
DEFER_QUERY = true
onIpc("refresh", nil)
NOW_MS = NOW_MS + 1000
DEFER_QUERY = false
NOW_MS = NOW_MS + 61000
update()
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.connected == true, "watchdog must recover")
local sawWatchdog = false
for _, m in ipairs(captured.logs or {}) do
	if string.find(m, "watchdog", 1, true) then sawWatchdog = true end
end
assert(sawWatchdog, "watchdog must log")
print("watchdog OK")
print("SERVICE TESTS PASSED")
