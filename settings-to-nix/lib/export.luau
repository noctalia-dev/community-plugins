--!nonstrict
-- Mirrors Noctalia's GUI layer (settings.toml in the state dir) into a Nix file. Every
-- export writes the file anew from settings.toml, so a setting deleted in the GUI also
-- disappears from the file. The file is a small Nix expression that, run by hand, writes
-- the settings back as settings.toml. This only ever writes the target file.

local toml = require("./toml.luau")
local nix = require("./nix.luau")

local M = {}

-- Part of the first line of every file this plugin writes; an existing target without
-- it is not overwritten.
local MARKER = "dmopp/settings-to-nix"
-- Name part of the private temp directories next to the target.
local MARKER_DIR = "settings-to-nix"

-- Left out of the export: the wallpaper paths Noctalia rewrites on every wallpaper
-- change. Dotted paths; `*` matches exactly one level.
local EXCLUDE = { "wallpaper.last.path", "wallpaper.default.path", "wallpaper.monitors.*.path" }

-- Same lookup as Noctalia's FileUtils::stateDir().
function M.settingsPath()
	for _, var in { "NOCTALIA_STATE_HOME", "XDG_STATE_HOME" } do
		local dir = noctalia.getenv(var)
		if dir and dir ~= "" then
			return dir .. "/noctalia/settings.toml"
		end
	end
	return noctalia.expandPath("~/.local/state/noctalia/settings.toml")
end

function M.targetPath(raw)
	raw = noctalia.string.trim(tostring(raw or ""))
	if raw == "" then
		return nil
	end
	return noctalia.expandPath(raw)
end

function M.compilePatterns(list)
	local patterns = {}
	for _, p in list or {} do
		local segs = {}
		for seg in string.gmatch(noctalia.string.trim(tostring(p)), "[^%.]+") do
			table.insert(segs, seg)
		end
		if #segs > 0 then
			table.insert(patterns, segs)
		end
	end
	return patterns
end

function M.excluded(patterns, path)
	for _, segs in patterns do
		if #segs == #path then
			local hit = true
			for n, seg in segs do
				if seg ~= "*" and seg ~= path[n] then
					hit = false
					break
				end
			end
			if hit then
				return true
			end
		end
	end
	return false
end

local function countValues(node)
	if node.t ~= "table" then
		return 1
	end
	local n = 0
	for _, k in node.keys do
		n += countValues(node.map[k])
	end
	return n
end

-- Removes excluded paths and values Nix cannot express (inf/nan); prunes tables left empty.
local function filter(node, path, patterns, stats)
	local kept = {}
	for _, k in node.keys do
		local child = node.map[k]
		local childPath = table.clone(path)
		table.insert(childPath, k)
		if M.excluded(patterns, childPath) then
			stats.excluded += countValues(child)
			node.map[k] = nil
		elseif child.special then
			stats.skipped += 1
			node.map[k] = nil
		elseif child.t == "table" then
			local before = #child.keys
			filter(child, childPath, patterns, stats)
			if before > 0 and #child.keys == 0 then
				node.map[k] = nil
			else
				table.insert(kept, k)
			end
		else
			stats.values += 1
			table.insert(kept, k)
		end
	end
	node.keys = kept
end

local function header(source, name)
	return table.concat({
		"# Noctalia settings, mirrored from the GUI by the " .. MARKER .. " plugin",
		"# (" .. source .. "). Every export overwrites this file.",
		"#",
		"# This file is your backup: keep it somewhere safe, for example in git.",
		"#",
		"# To restore, run this as your user in the directory of this file:",
		"#   $(nix-build --no-out-link ./" .. name .. ")/bin/noctalia-restore-settings",
		"# It replaces settings.toml (the old one is kept as settings.toml.bak-<time>).",
		"# Then restart Noctalia; it installs the plugins listed here again on startup.",
		"",
	}, "\n")
end

-- The restore script around the rendered settings. It writes them back as settings.toml
-- to the state dir Noctalia uses (same lookup as FileUtils::stateDir()). The settings
-- are also exposed as `.settings`, so a configuration can use them directly.
local function script(settings)
	return table.concat({
		"{ pkgs ? import <nixpkgs> { } }:",
		"let",
		"  settings = " .. settings .. ";",
		'  settingsToml = (pkgs.formats.toml { }).generate "noctalia-settings.toml" settings;',
		"in",
		'(pkgs.writeShellScriptBin "noctalia-restore-settings" \'\'',
		"  set -eu",
		"  PATH=${pkgs.coreutils}/bin:$PATH",
		'  if [ -n "\'\'${NOCTALIA_STATE_HOME:-}" ]; then',
		'    dir="$NOCTALIA_STATE_HOME/noctalia"',
		'  elif [ -n "\'\'${XDG_STATE_HOME:-}" ]; then',
		'    dir="$XDG_STATE_HOME/noctalia"',
		"  else",
		'    dir="$HOME/.local/state/noctalia"',
		"  fi",
		'  mkdir -p "$dir"',
		'  if [ -e "$dir/settings.toml" ]; then',
		'    backup="$dir/settings.toml.bak-$(date +%Y%m%d-%H%M%S)"',
		'    cp "$dir/settings.toml" "$backup"',
		'    echo "Previous settings saved to $backup"',
		"  fi",
		'  tmp=$(mktemp "$dir/.settings.toml.XXXXXX")',
		'  cat ${settingsToml} > "$tmp"',
		'  chmod 644 "$tmp"',
		'  mv "$tmp" "$dir/settings.toml"',
		"  # Skip the first-run wizard; it would write its own choices over the restored ones.",
		'  touch "$dir/.setup-complete"',
		'  echo "Noctalia settings restored to $dir/settings.toml."',
		'  echo "Restart Noctalia so it installs the plugins from the restored settings."',
		"\'\') // { inherit settings; }",
		"",
	}, "\n")
end

local function splitPath(path)
	local dir, name = string.match(path, "^(.*)/([^/]*)$")
	return (dir == "" and "/" or dir), name or path
end

-- Checks the target before it is replaced. Returns the current content when this plugin
-- wrote it, nil when nothing is there, or nil, err when something is there whose
-- ownership cannot be verified: a file without the marker, an unreadable file, a
-- directory or a dangling symlink.
function M.inspectTarget(target)
	local dir, name = splitPath(target)
	local present = noctalia.fileExists(target)
	if not present and noctalia.fileExists(dir) then
		-- fileExists follows symlinks; the listing also shows a dangling one.
		local entries = noctalia.listDir(dir)
		if entries == nil then
			return nil, noctalia.tr("errors.unverifiable", { path = target, error = "cannot list " .. dir })
		end
		present = table.find(entries, name) ~= nil
	end
	if not present then
		return nil
	end

	local info, infoErr = noctalia.fileInfo(target)
	if not info then
		return nil, noctalia.tr("errors.unverifiable", { path = target, error = tostring(infoErr) })
	end
	if info.isDir then
		return nil, noctalia.tr("errors.foreign", { path = target })
	end
	local text, readErr = noctalia.readFile(target)
	if not text then
		return nil, noctalia.tr("errors.unverifiable", { path = target, error = tostring(readErr) })
	end
	local firstLine = string.match(text, "^[^\n]*") or ""
	if not string.find(firstLine, MARKER, 1, true) then
		return nil, noctalia.tr("errors.foreign", { path = target })
	end
	return text
end

-- Builds the file content from the current settings.toml.
-- Returns { content, current, target, stats } or nil, err.
function M.plan(cfg)
	local target = M.targetPath(cfg.target)
	if not target then
		return nil, noctalia.tr("errors.no_target")
	end

	local current, targetErr = M.inspectTarget(target)
	if targetErr then
		return nil, targetErr
	end

	local source = M.settingsPath()
	local root = { t = "table", map = {}, keys = {} }
	if noctalia.fileExists(source) then
		local text, readErr = noctalia.readFile(source)
		if not text then
			return nil, noctalia.tr("errors.read", { path = source, error = tostring(readErr) })
		end
		local parsed, parseErr = toml.parse(text)
		if not parsed then
			return nil, noctalia.tr("errors.parse", { path = source, error = parseErr })
		end
		root = parsed
	end

	local stats = { values = 0, excluded = 0, skipped = 0 }
	filter(root, {}, M.compilePatterns(EXCLUDE), stats)

	return {
		content = header(source, string.match(target, "[^/]*$")) .. script(nix.render(root, "  ")),
		current = current,
		target = target,
		stats = stats,
	}
end

-- Writes plan.content to plan.target. The content goes into a private directory that
-- `mktemp -d` creates exclusively next to the target (mode 0700, so nothing can be
-- waiting there, neither a file nor a symlink), is checked with `nix-instantiate --parse`
-- when the tool exists, and is then renamed over the target, which is checked again
-- right before. Calls done(true) or done(false, err).
function M.write(plan, done)
	local target = plan.target
	local dir, name = splitPath(target)
	local ok, err = noctalia.mkdirAll(dir)
	if not ok then
		return done(false, noctalia.tr("errors.write", { path = dir, error = tostring(err) }))
	end

	local prefix = dir .. "/." .. MARKER_DIR .. "."
	local started = noctalia.runAsync({ "mktemp", "-d", prefix .. "XXXXXX" }, function(made)
		local tmpDir = noctalia.string.trim(made.stdout or "")
		if made.exitCode ~= 0 or string.sub(tmpDir, 1, #prefix) ~= prefix or string.find(tmpDir, "/", #prefix + 1, true) then
			local reason = noctalia.string.trim(made.stderr or "")
			return done(false, noctalia.tr("errors.write", { path = dir, error = reason ~= "" and reason or "mktemp failed" }))
		end
		local tmp = tmpDir .. "/" .. name

		local function finish(success, message)
			if noctalia.fileExists(tmp) then
				noctalia.removeFile(tmp)
			end
			noctalia.runAsync({ "rmdir", tmpDir })
			done(success, message)
		end

		local written, writeErr = noctalia.writeFile(tmp, plan.content)
		if not written then
			return finish(false, noctalia.tr("errors.write", { path = tmp, error = tostring(writeErr) }))
		end

		local function commit()
			local _, targetErr = M.inspectTarget(target)
			if targetErr then
				return finish(false, targetErr)
			end
			local renamed, renameErr = noctalia.renameFile(tmp, target)
			if not renamed then
				return finish(false, noctalia.tr("errors.write", { path = target, error = tostring(renameErr) }))
			end
			finish(true)
		end

		if not noctalia.commandExists("nix-instantiate") then
			return commit()
		end
		local checking = noctalia.runAsync({ "nix-instantiate", "--parse", tmp }, function(result)
			if result.exitCode ~= 0 then
				return finish(false, noctalia.tr("errors.invalid", { error = noctalia.string.trim(result.stderr or "") }))
			end
			commit()
		end)
		if not checking then
			commit()
		end
	end)
	if not started then
		done(false, noctalia.tr("errors.write", { path = dir, error = "could not start mktemp" }))
	end
end

return M
