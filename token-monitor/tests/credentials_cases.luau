local Credentials = require("../lib/credentials.luau")
local total = 0
local function test(name, fn) fn(); total += 1; print("PASS " .. name) end
local function rig()
  local r = { paths = {}, reads = {}, documents = {}, files = {}, variables = { HOME = "/home/test", XDG_CONFIG_HOME = "/xdg" }, names = {}, active = true }
  r.env = {
    getenv = function(name) return r.variables[name] end,
    expandPath = function(path) return path:gsub("^~", "/home/test") end,
    listDir = function(path) assert(path == "/home/test/distrobox"); r.listed = true; return r.names end,
    exists = function(path) return r.files[path] ~= nil end,
    decode = function(value) if value == "throw" then error("decode") end; return r.documents[value] end,
    read = function(path, callback)
      r.paths[#r.paths + 1] = path
      r.reads[#r.reads + 1] = callback
      if r.reject then return false end
      if not r.delayed then callback(r.files[path]) end
      return true
    end,
  }
  function r.resolve(url, manual, auto)
    Credentials.resolve(r.env, {url = url or "http://127.0.0.1:17321", credentialFile = manual or "", autoDiscover = auto ~= false},
      function() return r.active end, function(secret, info, err) r.secret, r.info, r.error = secret, info, err end)
  end
  function r.json(key, secret) r.documents[key] = {credentials = {hub = {hostSecret = secret}}} end
  return r
end

test("automatic loopback allowlist rejects lookalikes and arbitrary hosts", function()
  for _, url in ipairs({"http://127.0.0.1", "https://127.0.0.1:123", "http://[::1]:17321", "http://localhost:17321", "http://LOCALHOST"}) do
    assert(Credentials.loopback(url), url)
  end
  for _, url in ipairs({"http://127.0.0.2", "http://127.1", "http://127.0.0.1.evil", "http://localhost.evil", "http://remote", "http://[::ffff:127.0.0.1]", "http://localhost@evil", "http://localhost/path"}) do
    assert(not Credentials.loopback(url), url)
    local r = rig(); r.resolve(url); assert(#r.reads == 0 and r.info.discovery == "remote" and not r.listed)
  end
end)

test("native priority and dedup, no plaintext auto discovery", function()
  local r = rig(); r.json("native", "secret-a"); r.files["/xdg/Token Monitor/credentials.json"] = "native"
  r.resolve(); assert(r.secret == "secret-a" and #r.reads == 1 and r.info.credentialSource == "automatic" and not r.listed)
  local d = rig(); d.variables.XDG_CONFIG_HOME = "/home/test/.config"; d.files["/home/test/.config/Token Monitor/credentials.json"] = "plaintext"
  d.resolve(); assert(#d.reads == 1 and d.info.discovery == "invalid" and d.secret == nil)
end)

test("unusable high-priority candidates fall through to the native home then containers", function()
  local r = rig(); r.files["/xdg/Token Monitor/credentials.json"] = "broken"
  r.files["/home/test/.config/Token Monitor/credentials.json"] = "home"; r.json("home", "home-secret")
  r.resolve(); assert(r.secret == "home-secret" and #r.reads == 2 and not r.listed)
  local c = rig(); c.names = {"box"}; c.files["/home/test/distrobox/box/.config/Token Monitor/credentials.json"] = "container"; c.json("container", "container-secret")
  c.resolve(); assert(c.secret == "container-secret" and #c.reads == 1 and c.info.discovery == "found")
end)

test("manual override supports legacy plaintext and never falls back", function()
  local r = rig(); r.files["/home/test/key"] = "manual-secret"; r.json("native", "automatic-secret"); r.files["/xdg/Token Monitor/credentials.json"] = "native"
  r.resolve("http://remote", "~/key"); assert(r.secret == "manual-secret" and r.paths[1] == "/home/test/key" and #r.reads == 1 and r.info.discovery == "manual")
  local b = rig(); b.files["/key"] = "{"; b.resolve(nil, "/key")
  assert(b.error == "credentials_invalid" and #b.reads == 1 and not b.listed)
  local m = rig(); m.resolve(nil, "/missing"); assert(m.error == "credentials_unreadable" and #m.reads == 1)
  local q = rig(); q.reject = true; q.resolve(nil, "/key"); assert(q.error == "request_rejected")
end)

test("bounded sorted containers sanitize every basename", function()
  local r = rig(); r.variables.XDG_CONFIG_HOME = "relative"
  r.names = {"z", "../evil", "/etc", "a/b", "a\\b", ".", "..", "bad\nname", "b", "a"}
  for i = 40, 1, -1 do r.names[#r.names + 1] = string.format("box%02d", i) end
  r.env.exists = nil
  r.resolve()
  assert(#r.reads == 33 and r.paths[1] == "/home/test/.config/Token Monitor/credentials.json")
  assert(r.paths[2] == "/home/test/distrobox/a/.config/Token Monitor/credentials.json")
  assert(r.paths[3] == "/home/test/distrobox/b/.config/Token Monitor/credentials.json")
  assert(r.paths[33] == "/home/test/distrobox/box30/.config/Token Monitor/credentials.json")
  assert(r.info.discovery == "unreadable")
end)

test("missing, invalid, rejected, disabled and absent environment diagnostics", function()
  local r = rig(); r.resolve(); assert(r.info.discovery == "not_found" and #r.reads == 0)
  local b = rig(); b.files["/xdg/Token Monitor/credentials.json"] = "throw"; b.resolve(); assert(b.info.discovery == "invalid")
  local q = rig(); q.files["/xdg/Token Monitor/credentials.json"] = "anything"; q.reject = true; q.resolve(); assert(q.info.discovery == "unreadable" and q.secret == nil)
  local d = rig(); d.resolve(nil, nil, false); assert(d.info.discovery == "disabled" and #d.reads == 0 and not d.listed)
  local a = rig(); a.variables = {}; a.resolve(); assert(a.info.discovery == "not_found" and #a.reads == 0)
end)

test("automatic credential JSON shape is strict", function()
  for _, document in ipairs({{}, {hostSecret = "secret"}, {credentials = {}}, {credentials = {hub = {hostSecret = "bad\nsecret"}}}, {credentials = {hub = {hostSecret = 42}}}}) do
    local r = rig(); r.files["/xdg/Token Monitor/credentials.json"] = "json"; r.documents.json = document; r.resolve()
    assert(r.info.discovery == "invalid" and r.secret == nil)
  end
end)

test("rotation is reread and old credential callback cannot complete", function()
  local r = rig(); local path = "/xdg/Token Monitor/credentials.json"; r.json("first", "one"); r.json("second", "two")
  r.files[path] = "first"; r.resolve(); assert(r.secret == "one")
  r.files[path] = "second"; r.resolve(); assert(r.secret == "two" and #r.reads == 2)
  local d = rig(); d.files[path] = "first"; d.json("first", "one"); d.delayed = true; d.resolve(); d.active = false
  d.reads[1]("first"); assert(d.info == nil and d.secret == nil)
end)
print(tostring(total) .. " credentials cases passed")
