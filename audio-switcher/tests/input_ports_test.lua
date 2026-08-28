local sourceFile = assert(io.open("service.luau", "rb"))
local source = sourceFile:read("*a")
sourceFile:close()

local beginMarker = "-- BEGIN INPUT PORT HELPERS"
local endMarker = "-- END INPUT PORT HELPERS"
local beginAt = assert(source:find(beginMarker, 1, true), "input port helper start marker missing")
local bodyAt = assert(source:find("\n", beginAt, true)) + 1
local endAt = assert(source:find(endMarker, bodyAt, true), "input port helper end marker missing")
local helperSource = source:sub(bodyAt, endAt - 1)
local loader = assert(load(helperSource .. "\nreturn parseInputPorts", "input port helpers", "t", _G))
local parseInputPorts = loader()

local ports, active = parseInputPorts({
  active_port = "analog-input-internal-mic",
  ports = {
    { name = "analog-input-internal-mic", description = "Internal Microphone", availability = "available" },
    { name = "analog-input-headset-mic", description = "Headset Microphone", availability = "not available" },
    { name = "analog-input-mic", description = "Microphone", availability = "unknown" },
  },
})

assert(active == "analog-input-internal-mic")
assert(#ports == 3)
assert(ports[1].active and ports[1].available and ports[1].description == "Internal Microphone")
assert(not ports[2].active and not ports[2].available and ports[2].description == "Headset Microphone")
assert(ports[3].available, "unknown availability should remain selectable")

local objectPorts, objectActive = parseInputPorts({
  active_port = { name = "mic" },
  ports = { { name = "mic", description = "", availability = "available" } },
})
assert(objectActive == "mic" and objectPorts[1].active)
assert(objectPorts[1].description == "mic", "port name should be the description fallback")

print("audio input port tests: ok")
