-- Q30 (A3028, over-ear) service assertions. Runs after stubs + service.luau
-- with ACTIVE_PROFILE="q30" preset (see tests/run.sh).
print("== q30 snapshot ==")
local snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap, "no snapshot published")
assert(snap.connected == true, "expected connected")
assert(snap.modelId == "SoundcoreA3028", "modelId: " .. tostring(snap.modelId))
assert(snap.modelName == "Soundcore Q30", "modelName: " .. tostring(snap.modelName))
assert(snap.isHeadset == true, "Q30 must detect as headset")
assert(snap.headset.level == 40, "headset expected 40, got " .. tostring(snap.headset.level))
assert(snap.headset.charging == false, "headset should not be charging")
assert(snap.left.level == -1 and snap.right.level == -1, "no per-bud battery on Q30")
assert(snap.caseBattery.level == -1, "no case on Q30")
assert(snap.hasBattery == true, "hasBattery")
assert(snap.primaryText == "40%", "primary expected 40%, got " .. tostring(snap.primaryText))
assert(snap.noiseMode == 1, "noiseMode ANC, got " .. tostring(snap.noiseMode))
assert(snap.topMode == 1, "topMode ANC")
assert(snap.noiseCancelMode == "Outdoor", "cancel mode, got " .. tostring(snap.noiseCancelMode))
assert(#snap.availableModes == 3, "3 top modes, got " .. #snap.availableModes)
assert(#snap.cancelModes == 3, "3 cancel modes, got " .. #snap.cancelModes)
assert(snap.cancelModes[1].value == "Transport", "first cancel option")
assert(snap.supportsManualAnc == false, "no manual ANC on Q30")
assert(snap.supportsAdaptive == false, "no adaptive on Q30")
assert(snap.touch.available == false, "no touch on Q30")
assert(snap.info.serial == "Q30SN001", "serial")
print("q30 snapshot OK")

print("== q30 set-cancel-mode ==")
watchers["sankity/soundcore-buds:command"]({ action = "set-cancel-mode", value = "Indoor", nonce = "q1" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.noiseCancelMode == "Indoor", "cancel Indoor, got " .. tostring(snap.noiseCancelMode))
print("q30 set-cancel-mode OK")

print("== q30 cycle-noise ==")
watchers["sankity/soundcore-buds:command"]({ action = "cycle-noise", nonce = "q2" })
snap = captured.state["sankity/soundcore-buds:snapshot"]
assert(snap.noiseMode == 0, "cycle ANC->Off, got " .. tostring(snap.noiseMode))
assert(snap.topMode == 0, "topMode Off")
print("Q30 SERVICE TESTS PASSED")
