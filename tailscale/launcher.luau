--!nonstrict
-- Tailscale launcher provider — type `/ts` in the launcher.
--
-- The fast path for "give me that host's IP": fuzzy-search the tailnet by
-- host name / IP / OS, Enter copies the peer's Tailscale IP. Prefix the query
-- with "n " (e.g. `/ts n pc-c`) to copy the host name instead.

local function decodeSnapshot()
  local encoded = noctalia.state.get("ts.snapshot")
  return encoded and noctalia.json.decode(encoded) or nil
end

local OS_GLYPHS = {
  linux = "device-desktop",
  windows = "device-desktop",
  macos = "device-laptop",
  ios = "device-mobile",
  android = "device-mobile",
}

local function entries(snapshot)
  local list = {}
  table.insert(list, {
    name = snapshot.self.name,
    shortName = snapshot.self.dnsName,
    ip = snapshot.self.ip,
    online = true,
    os = "",
    isSelf = true,
  })
  for _, peer in snapshot.peers do
    table.insert(list, peer)
  end
  return list
end

function onQuery(text)
  local snapshot = decodeSnapshot()
  if not snapshot or snapshot.state ~= "running" then
    launcher.setResults(text, {
      {
        id = "noop",
        title = noctalia.tr(`state.{snapshot and snapshot.state or "stopped"}`),
        glyph = "topology-star-3",
      },
    })
    return
  end

  local copyName = false
  local query = noctalia.string.trim(text)
  local rest = query:match("^[nN]%s+(.*)$")
  if rest or query == "n" or query == "N" then
    copyName = true
    query = rest or ""
  end

  local results = {}
  for _, host in entries(snapshot) do
    local haystack = `{host.name} {host.ip} {host.os}`
    local score = 0
    if query ~= "" then
      score = noctalia.fuzzyScore(query, haystack)
      if not score then
        continue
      end
    end
    local target = copyName and host.shortName or host.ip
    table.insert(results, {
      id = `{copyName and "name" or "ip"}|{target}|{host.name}`,
      title = host.isSelf and `{host.name} ({noctalia.tr("launcher.this-host")})` or host.name,
      subtitle = copyName
        and noctalia.tr("launcher.copy-name", { value = host.shortName })
        or noctalia.tr("launcher.copy-ip", { value = host.ip }),
      glyph = OS_GLYPHS[host.os:lower()] or "device-desktop",
      badge = host.online and noctalia.tr("launcher.online") or noctalia.tr("launcher.offline"),
      score = score + (host.online and 1 or 0),
    })
  end
  launcher.setResults(text, results)
end

function onActivate(id)
  local kind, value, name = id:match("^(%w+)|([^|]*)|(.*)$")
  if not kind or value == "" then
    return
  end
  noctalia.copyToClipboard(value, "text/plain")
  noctalia.notify(noctalia.tr("toast.title"),
    noctalia.tr(kind == "name" and "toast.copied-name" or "toast.copied-ip", { host = name, value = value }))
end
