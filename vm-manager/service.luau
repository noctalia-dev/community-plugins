--!nonstrict
-- service.luau — background poller for libvirt VM state.
--
-- Publishes a plain table on the plugin state channel under the "vms" key.
-- The widget and panel watch that key and re-render when it changes.

-- Reads the configured libvirt connection so URI changes apply on the next poll.
local function connectUri()
	return noctalia.getConfig("connect_uri") or "qemu:///system"
end

local snapshot = {
	vms = {},
	running = 0,
	paused = 0,
	total = 0,
	updatedAt = 0,
	busy = {},
	error = nil,
}

local function publish()
	noctalia.state.set("vms", snapshot)
end

local function parseVirshList(output)
	local vms = {}
	for line in output:gmatch("[^\r\n]+") do
		-- "virsh list --all" rows: "<id>  <name>  <state>"; state may contain spaces.
		-- Tokenize by whitespace; skip header and separator lines (their first
		-- token is neither a domain id nor "-").
		local fields = {}
		for field in line:gmatch("%S+") do
			table.insert(fields, field)
		end
		local id = fields[1]
		if #fields >= 3 and (id == "-" or id:match("^%d+$")) then
			table.insert(vms, {
				id = id,
				name = fields[2],
				state = noctalia.string.trim(table.concat(fields, " ", 3)),
			})
		end
	end
	return vms
end

-- Probes the independent next-boot (once) autostart flag on each candidate
-- via `virsh dominfo` and tags the VM when it is set, then publishes.
local function tagAutostartOnce(candidates)
	local function step(index)
		if index > #candidates then
			publish()
			return
		end
		local vm = candidates[index]
		local launched = noctalia.runAsync({ "virsh", "--connect", connectUri(), "dominfo", vm.name }, function(result)
			if type(result) == "table" and result.exitCode == 0 then
				-- dominfo prints e.g. "Autostart Once:   enable"
				if (result.stdout or ""):match("Autostart Once:%s*(%S+)") == "enable" then
					vm.autostart = true
				end
			end
			step(index + 1)
		end, 10000)
		if not launched then
			step(index + 1)
		end
	end

	step(1)
end

-- Queries the autostart-enabled set and tags each VM, then publishes. A
-- domain counts as autostarted when either the regular flag or the
-- independent next-boot (once) flag is set, since libvirt starts it on the
-- next daemon boot either way; `virsh list --autostart` only reports the
-- regular flag, so the once flag is probed per-VM.
local function mergeAutostart(vms)
	if #vms == 0 then
		publish()
		return
	end

	local launched = noctalia.runAsync({ "virsh", "--connect", connectUri(), "list", "--all", "--autostart" }, function(result)
		local autostartNames = {}
		if type(result) == "table" and result.exitCode == 0 then
			for _, vm in ipairs(parseVirshList(result.stdout or "")) do
				autostartNames[vm.name] = true
			end
		end
		local onceCandidates = {}
		for _, vm in ipairs(vms) do
			if autostartNames[vm.name] == true then
				vm.autostart = true
			else
				table.insert(onceCandidates, vm)
			end
		end
		tagAutostartOnce(onceCandidates)
	end, 10000)

	if not launched then
		publish()
	end
end

-- Turns a failed virsh result into a short, actionable explanation.
local function virshErrorDetail(action, result, name)
	local stderr = (type(result) == "table" and noctalia.string.trim(result.stderr or "")) or ""
	local lower = stderr:lower()
	local uri = connectUri()

	if not noctalia.commandExists("virsh") then
		return noctalia.tr("error.not_installed")
	end
	if lower:match("could not connect") or lower:match("failed to connect") or lower:match("connection refused") or lower:match("cannot connect") then
		return noctalia.tr("error.connect_failed", { uri = uri })
	end
	if lower:match("authentication failed") or lower:match("authorization failed") or lower:match("permission denied") or lower:match("not authorized") then
		return noctalia.tr("error.access_denied", { uri = uri })
	end
	if lower:match("domain not found") or lower:match("does not exist") or lower:match("no domain") then
		if name and name ~= "" then
			return noctalia.tr("error.no_domain", { name = name, uri = uri })
		end
		return noctalia.tr("error.no_domains", { uri = uri })
	end
	if action and action:match("^autostart") and (lower:match("not persistent") or lower:match("persistent") or lower:match("not valid")) then
		return noctalia.tr("error.autostart_persist")
	end
	if stderr ~= "" then
		return stderr
	end
	return noctalia.tr("error.exit_code", { code = tostring(result and result.exitCode or "?") })
end

local function refresh()
	local launched = noctalia.runAsync({ "virsh", "--connect", connectUri(), "list", "--all" }, function(result)
		if type(result) ~= "table" or result.exitCode ~= 0 then
			snapshot.error = virshErrorDetail("list", result)
			publish()
			return
		end

		local vms = parseVirshList(result.stdout or "")
		local running, paused = 0, 0
		for _, vm in ipairs(vms) do
			if vm.state == "running" then
				running = running + 1
			elseif vm.state == "paused" then
				paused = paused + 1
			end
		end

		snapshot.error = nil
		snapshot.vms = vms
		snapshot.running = running
		snapshot.paused = paused
		snapshot.total = #vms
		snapshot.updatedAt = os.time()
		mergeAutostart(vms)
	end, 10000)

	if not launched then
		snapshot.error = noctalia.tr("error.launch_virsh")
		publish()
	end
end

local function fail(action, name, result)
	noctalia.notifyError(noctalia.tr("plugin.title"), action .. " " .. name .. ": " .. virshErrorDetail(action, result, name))
end

-- Shared busy-flag + error handling around virsh subprocesses. Runs one
-- command, or a list sequentially (stopping at the first failure); refreshes
-- once after the last command finishes.
local function runVirshAll(cmds, action, name)
	snapshot.busy[name] = action
	publish()

	local function step(index)
		if index > #cmds then
			snapshot.busy[name] = nil
			refresh()
			return
		end
		local launched = noctalia.runAsync(cmds[index], function(result)
			if type(result) ~= "table" or result.exitCode ~= 0 then
				snapshot.busy[name] = nil
				fail(action, name, result)
				return
			end
			step(index + 1)
		end, 15000)
		if not launched then
			snapshot.busy[name] = nil
			noctalia.notifyError(noctalia.tr("plugin.title"), noctalia.tr("error.launch_virsh_for", { action = action, name = name }))
			publish()
		end
	end

	step(1)
end

local function runVirsh(cmd, action, name)
	runVirshAll({ cmd }, action, name)
end

local function runVMAction(action, name)
	if snapshot.busy[name] then
		return
	end

	local cmd
	if action == "start" then
		cmd = { "virsh", "--connect", connectUri(), "start", name }
	elseif action == "shutdown" then
		cmd = { "virsh", "--connect", connectUri(), "shutdown", name }
	elseif action == "force-off" then
		cmd = { "virsh", "--connect", connectUri(), "destroy", name }
	elseif action == "suspend" then
		cmd = { "virsh", "--connect", connectUri(), "suspend", name }
	elseif action == "resume" then
		cmd = { "virsh", "--connect", connectUri(), "resume", name }
	else
		return
	end

	runVirsh(cmd, action, name)
end

-- mode is "enable", "disable", or "once".
local function setAutostart(name, mode)
	if snapshot.busy[name] then
		return
	end

	local cmds
	if mode == "disable" then
		-- Regular autostart and the next-boot (once) flag are independent in
		-- libvirt, so both must be cleared: "--disable" only clears the
		-- regular flag and "--disable --once" only clears a pending once flag.
		cmds = {
			{ "virsh", "--connect", connectUri(), "autostart", name, "--disable", "--once" },
			{ "virsh", "--connect", connectUri(), "autostart", name, "--disable" },
		}
	elseif mode == "once" then
		cmds = { { "virsh", "--connect", connectUri(), "autostart", name, "--once" } }
	else
		cmds = { { "virsh", "--connect", connectUri(), "autostart", name } }
	end

	runVirshAll(cmds, "autostart-" .. mode, name)
end

local function handleAutostart(action, name)
	if action == "autostart" then
		setAutostart(name, "enable")
	elseif action == "autostart-disable" then
		setAutostart(name, "disable")
	elseif action == "autostart-once" then
		setAutostart(name, "once")
	end
end

local function openConsole(name)
	if not noctalia.commandExists("virt-viewer") then
		noctalia.notifyError(noctalia.tr("plugin.title"), noctalia.tr("error.console_failed", { name = name }))
		return
	end
	local uri = connectUri()
	local launched = noctalia.runAsync({ "virt-viewer", "--connect", uri, name })
	if not launched then
		noctalia.notifyError(noctalia.tr("plugin.title"), noctalia.tr("error.launch_viewer", { name = name }))
	end
end

-- The panel pushes { action = ..., name = ... } here instead of talking to virsh directly.
noctalia.state.watch("vm_action", function(action)
	if type(action) ~= "table" then
		return
	end
	if action.action == "refresh" then
		refresh()
		return
	end
	if type(action.name) ~= "string" then
		return
	end
	if action.action == "console" then
		openConsole(action.name)
	elseif action.action == "autostart" or action.action == "autostart-disable" or action.action == "autostart-once" then
		handleAutostart(action.action, action.name)
	else
		runVMAction(action.action, action.name)
	end
end)

local function pollIntervalMs()
	local seconds = tonumber(noctalia.getConfig("poll_interval")) or 3
	return math.max(1, seconds) * 1000
end

noctalia.setUpdateInterval(pollIntervalMs())

function update()
	refresh()
end

function onConfigChanged()
	noctalia.setUpdateInterval(pollIntervalMs())
end

function onIpc(event, payload)
	if event == "refresh" then
		refresh()
	elseif event == "console" and type(payload) == "string" then
		openConsole(payload)
	elseif type(payload) == "string" then
		if event == "autostart" or event == "autostart-disable" or event == "autostart-once" then
			handleAutostart(event, payload)
		else
			runVMAction(event, payload)
		end
	end
end

refresh()