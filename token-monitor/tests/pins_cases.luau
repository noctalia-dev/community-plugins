local Pins = require("../lib/pins.luau")
local total = 0

local function test(name, fn)
  fn()
  total += 1
  print("PASS " .. name)
end

local function rig()
  local r = { reads = {}, writes = {}, docs = {}, writeOk = true }
  r.engine = Pins.new({
    path = function() return "/private/pins.json" end,
    read = function(path, callback)
      table.insert(r.reads, { path = path, callback = callback })
      return true
    end,
    write = function(path, text)
      table.insert(r.writes, { path = path, text = text })
      return r.writeOk
    end,
    encode = function(value)
      r.encoded = value
      return "record"
    end,
    decode = function(text) return r.docs[text] end,
    publish = function(value) r.state = value end,
  })
  function r.resolve(index, value, error)
    r.reads[index].callback(value, error)
  end
  return r
end

local a = { key = "account-a", provider = "codex" }
local b = { key = "account-b", provider = "codex" }

test("selection follows stable key when provider order changes", function()
  local r = rig(); r.engine.configure("hub-a"); r.resolve(1, nil)
  assert(r.engine.select("account-a", { a, b }))
  assert(r.engine.get().key == "account-a")
  assert(r.encoded.schema == 1 and r.encoded.scope == "hub-a" and r.encoded.key == "account-a")
  assert(r.engine.select("account-a", { b, a }))
  assert(r.engine.get().key == "account-a")
end)

test("unknown and duplicate keys are rejected; empty key clears", function()
  local r = rig(); r.engine.configure("hub-a"); r.resolve(1, nil)
  assert(not r.engine.select("missing", { a }))
  assert(not r.engine.select("account-a", { a, a }))
  assert(r.engine.get().key == "")
  assert(r.engine.select("account-a", { a }))
  assert(r.engine.select("", {}))
  assert(r.engine.get().key == "")
end)

test("accounts without stable identity do not block pinning an identified account", function()
  local r = rig(); r.engine.configure("hub-a"); r.resolve(1, nil)
  local noIdentity = { key = "", provider = "codex" }
  assert(r.engine.select("account-a", { noIdentity, a }))
  assert(r.engine.get().key == "account-a")
end)

test("corrupt and oversized cache are reported without restoring a key", function()
  local r = rig(); r.engine.configure("hub-a")
  r.resolve(1, "bad")
  assert(r.engine.get().ready and r.engine.get().key == "" and r.engine.get().error == "cache_invalid")
  r.engine.configure("hub-b"); r.resolve(2, string.rep("x", 16385))
  assert(r.engine.get().ready and r.engine.get().key == "" and r.engine.get().error == "cache_invalid")
end)

test("source changes discard old callbacks and mismatched records", function()
  local r = rig(); r.engine.configure("hub-a")
  local old = r.reads[1].callback
  r.engine.configure("hub-b")
  r.docs.old = { schema = 1, scope = "hub-a", key = "account-a" }
  old("old")
  assert(not r.engine.get().ready and r.engine.get().scope == "hub-b")
  r.resolve(2, "old")
  assert(r.engine.get().ready and r.engine.get().key == "")
end)

test("a read started before a user selection cannot replace it", function()
  local r = rig(); r.engine.configure("hub-a")
  local late = r.reads[1].callback
  assert(r.engine.select("account-b", { a, b }))
  r.docs.old = { schema = 1, scope = "hub-a", key = "account-a" }
  late("old")
  assert(r.engine.get().key == "account-b")
end)

test("failed persistence does not publish the requested pin", function()
  local r = rig(); r.engine.configure("hub-a"); r.resolve(1, nil)
  r.writeOk = false
  assert(not r.engine.select("account-a", { a }))
  assert(r.engine.get().key == "" and r.engine.get().error == "write_failed")
end)

test("a write without an explicit success result is treated as failed", function()
  local r = rig(); r.engine.configure("hub-a"); r.resolve(1, nil)
  r.writeOk = nil
  assert(not r.engine.select("account-a", { a }))
  assert(r.engine.get().key == "" and r.engine.get().error == "write_failed")
end)

print(tostring(total) .. " pin cases passed")
