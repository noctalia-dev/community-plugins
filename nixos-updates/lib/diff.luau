--!nonstrict
-- Pure comparisons for the service: flake inputs between two lock files,
-- package versions between two evaluations, Flatpak updates from the TSV
-- files check.sh writes.

local M = {}

-- Links come from flake.lock and package metadata, i.e. from whoever controls
-- an input. Only plain http(s) URLs pass: a host, then a port, path, query or
-- fragment. That rules out file://, local paths, a leading dash xdg-open could
-- take for an option, a user part that disguises the host (https://a.org@b.org),
-- and whitespace and shell metacharacters, should a browser wrapper be careless.
function M.safeUrl(url)
	if type(url) ~= "string" or #url > 2048 then
		return nil
	end
	local rest = url:match("^https?://%w[%w%-%.]*(.*)$")
	if rest == nil or rest:find("[^%w%-%._~:/%?#%[%]@%+,=%%&]") ~= nil then
		return nil
	end
	if rest ~= "" and rest:match("^:%d+$") == nil and rest:match("^:%d+[/%?#]") == nil and rest:match("^[/%?#]") == nil then
		return nil
	end
	return url
end

-- A URL can carry credentials (https://token@host/..., ?token=...); they stay
-- out of the panel and result.json.
local function withoutCredentials(url)
	return (tostring(url):gsub("//[^/@]*@", "//"):gsub("[%?#].*$", ""))
end

local function shortRev(locked)
	if type(locked) ~= "table" then
		return ""
	end
	if type(locked.rev) == "string" then
		return locked.rev:sub(1, 7)
	end
	-- Tarball inputs (channels) have no rev; their URL names the release.
	if type(locked.url) == "string" then
		return withoutCredentials(locked.url):match("([^/]+)/[^/]*$") or ""
	end
	return ""
end

local function source(original)
	if type(original) ~= "table" then
		return ""
	end
	if original.owner ~= nil and original.repo ~= nil then
		local ref = original.ref ~= nil and ("/" .. original.ref) or ""
		return tostring(original.type) .. ":" .. original.owner .. "/" .. original.repo .. ref
	end
	return withoutCredentials(original.url or original.path or original.type or "")
end

-- Web page with the commits between two revisions, where the host has one.
local function compareUrl(original, oldLocked, newLocked)
	if type(original) ~= "table" or type(oldLocked) ~= "table" or type(newLocked) ~= "table" then
		return nil
	end
	if oldLocked.rev == nil or newLocked.rev == nil or original.owner == nil or original.repo == nil then
		return nil
	end
	local hosts = { github = "https://github.com", gitlab = "https://gitlab.com", codeberg = "https://codeberg.org" }
	local base = hosts[original.type]
	if base == nil then
		return nil
	end
	-- Self-hosted instance: github:owner/repo?host=git.example.org
	if original.host ~= nil then
		base = "https://" .. tostring(original.host)
	end
	local sep = original.type == "gitlab" and "/-/compare/" or "/compare/"
	return M.safeUrl(base .. "/" .. original.owner .. "/" .. original.repo .. sep .. oldLocked.rev .. "..." .. newLocked.rev)
end

local function rootInputs(lock)
	if type(lock) ~= "table" or type(lock.nodes) ~= "table" then
		return nil
	end
	local root = lock.nodes[lock.root or "root"]
	if type(root) ~= "table" then
		return nil
	end
	return root.inputs or {}
end

-- Direct inputs of the flake whose locked content differs. Inputs that follow
-- another one (lists in the lock) are left out, they show up under that one.
function M.inputs(oldLock, newLock, ignored)
	local oldInputs = rootInputs(oldLock)
	local newInputs = rootInputs(newLock)
	if oldInputs == nil or newInputs == nil then
		return nil
	end
	local skip = {}
	for _, name in ipairs(ignored or {}) do
		skip[tostring(name):match("^%s*(.-)%s*$")] = true
	end
	local rows = {}
	for name, oldKey in pairs(oldInputs) do
		local newKey = newInputs[name]
		if type(oldKey) == "string" and type(newKey) == "string" then
			local old = oldLock.nodes[oldKey] or {}
			local new = newLock.nodes[newKey] or {}
			local oldHash = old.locked and old.locked.narHash
			local newHash = new.locked and new.locked.narHash
			if not skip[name] and oldHash ~= newHash then
				table.insert(rows, {
					name = name,
					source = source(new.original or old.original),
					oldRev = shortRev(old.locked),
					newRev = shortRev(new.locked),
					oldDate = tonumber(old.locked and old.locked.lastModified) or 0,
					newDate = tonumber(new.locked and new.locked.lastModified) or 0,
					url = compareUrl(new.original or old.original, old.locked, new.locked),
				})
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return rows
end

-- name -> versions joined with ", ", and name -> { c, h } (changelog and
-- homepage, the first non-empty one seen).
local function versions(list)
	local byName = {}
	local meta = {}
	for _, entry in ipairs(type(list) == "table" and list or {}) do
		local name = tostring(entry.n or "")
		if name ~= "" then
			byName[name] = byName[name] or {}
			byName[name][tostring(entry.v or "")] = true
			local m = meta[name] or { c = "", h = "" }
			if m.c == "" then
				m.c = tostring(entry.c or "")
			end
			if m.h == "" then
				m.h = tostring(entry.h or "")
			end
			meta[name] = m
		end
	end
	local out = {}
	for name, set in pairs(byName) do
		local list2 = {}
		for v in pairs(set) do
			table.insert(list2, v)
		end
		table.sort(list2)
		out[name] = table.concat(list2, ", ")
	end
	return out, meta
end

-- Where to read what changed: the package's meta.changelog (often for that
-- very version), else the releases page when the homepage is a GitHub repo.
local function changesUrl(m)
	local changelog = M.safeUrl(m.c)
	if changelog ~= nil then
		return changelog, "changelog"
	end
	local repo = tostring(m.h or ""):match("^https?://github%.com/([%w%._%-]+/[%w%._%-]+)")
	if repo ~= nil then
		local url = M.safeUrl("https://github.com/" .. repo:gsub("%.git$", "") .. "/releases")
		if url ~= nil then
			return url, "releases"
		end
	end
	return nil, nil
end

-- Packages whose version changes, appears or disappears; kind says which
-- ("changed", "added", "removed"), old/new are "" on the side that is missing.
-- The changes link comes from the new side, for removed packages from the old
-- one, and is nil when there is none.
function M.packages(oldList, newList)
	local old, oldMeta = versions(oldList)
	local new, newMeta = versions(newList)
	local rows = {}
	local function add(name, kind, o, n, meta)
		local url, urlKind = changesUrl(meta)
		table.insert(rows, { name = name, kind = kind, old = o, new = n, changes = url, changesKind = urlKind })
	end
	for name, v in pairs(old) do
		if new[name] == nil then
			add(name, "removed", v, "", oldMeta[name])
		elseif new[name] ~= v then
			add(name, "changed", v, new[name], newMeta[name])
		end
	end
	for name, v in pairs(new) do
		if old[name] == nil then
			add(name, "added", "", v, newMeta[name])
		end
	end
	table.sort(rows, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return rows
end

local function tsv(text)
	local rows = {}
	for line in tostring(text or ""):gmatch("[^\n]+") do
		local fields = {}
		for field in (line .. "\t"):gmatch("([^\t]*)\t") do
			table.insert(fields, field)
		end
		table.insert(rows, fields)
	end
	return rows
end

-- installed: installation, application, branch, version, name, origin.
-- updates: installation, application, branch, new version.
function M.flatpak(installedText, updatesText)
	local installed = {}
	for _, f in ipairs(tsv(installedText)) do
		installed[(f[1] or "") .. "|" .. (f[2] or "") .. "|" .. (f[3] or "")] = { version = f[4] or "", name = f[5] or "", origin = f[6] or "" }
	end
	local rows = {}
	for _, f in ipairs(tsv(updatesText)) do
		local app = f[2] or ""
		if app ~= "" then
			local have = installed[(f[1] or "") .. "|" .. app .. "|" .. (f[3] or "")] or {}
			table.insert(rows, {
				installation = f[1] or "",
				app = app,
				branch = f[3] or "",
				name = (have.name ~= nil and have.name ~= "") and have.name or app,
				old = have.version or "",
				new = f[4] or "",
				-- Flathub shows the release notes on the app page; runtimes
				-- (versioned branches) have no such page.
				changes = (have.origin == "flathub" and f[3] == "stable") and M.safeUrl("https://flathub.org/apps/" .. app) or nil,
			})
		end
	end
	table.sort(rows, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return rows
end

-- Every listed row counts: an input with new commits is an update even when
-- no package version changes (a package built from it can keep its version).
-- A list is absent while its check is off or unavailable, hence the lookup by
-- name: ipairs over { r.packages, r.flatpak, r.inputs } would stop at that nil.
function M.pendingCount(r)
	local n = 0
	for _, field in ipairs({ "packages", "flatpak", "inputs" }) do
		local list = r[field]
		if type(list) == "table" then
			n += #list
		end
	end
	return n
end

return M
