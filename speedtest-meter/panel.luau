--!strict
-- Speedtest Meter — panel entry point.
--
-- Distro-independent by design: it works with either backend it finds on
-- PATH, in this order of preference:
--   1. "ookla"  -> the official Ookla CLI (binary `speedtest`). Streams
--      progress line by line, so the gauge is truly live.
--   2. "legacy" -> the Python `speedtest-cli` package (binary
--      `speedtest-cli`), packaged in Arch's official repos (pacman -S
--      speedtest-cli), Debian/Ubuntu, Fedora, openSUSE and Alpine. No
--      incremental progress is available from this tool, so the gauge
--      pulses instead of tracking a real-time value while it runs.
-- If neither is found, the error screen shows an install command for the
-- detected package manager (pacman/apt/dnf/zypper/apk) instead of a single
-- hardcoded distro's instructions.
--
-- All user-facing strings come from noctalia.tr(...), backed by
-- translations/en.json and translations/pt-BR.json next to this file.

-- ── State ─────────────────────────────────────────────────────────────────

local state = "idle" -- "idle" | "running" | "done" | "error"
local phase = "" -- "ping" | "download" | "upload" (ookla backend only)
local backendInUse: string? = nil -- "ookla" | "legacy"
local liveMbps = 0
local gaugeMax = 100 -- dynamic upper bound for the speedometer scale
local runningElapsed = 0 -- seconds since the current test started (drives the pulse + watchdog)
local errorMessage: string? = nil
local result: any = nil -- normalized result table (see normalizeOokla/normalizeLegacy)
local history: any = {} -- newest-first list, capped at five results
local clientInfo: any = nil -- decoded geolocation JSON for the local client
local panelActive = false
local progressValue = 0 -- 0 to 1 for progress tracking
local timerRunning = false -- flag to control timer updates
local simulatedMbps = 0 -- valor simulado para o backend legacy
local lastDownloadMbps = 0 -- último resultado de download
local lastUploadMbps = 0 -- último resultado de upload

local DATA_FILE = "/last-result.json"
local OOKLA_CMD = "speedtest --accept-license --accept-gdpr --format=json --progress=yes"
local LEGACY_CMD = "speedtest-cli --json --secure"
local LEGACY_TIMEOUT_MS = 60000 -- runAsync's hard ceiling; slow links may not finish in time

-- Best-effort per-distro install command for the (widely packaged) legacy
-- Python speedtest-cli, keyed by the package manager binary that's present.
local INSTALL_COMMANDS = {
	pacman = "sudo pacman -S speedtest-cli",
	apt = "sudo apt install speedtest-cli",
	dnf = "sudo dnf install speedtest-cli",
	zypper = "sudo zypper install speedtest-cli",
	apk = "sudo apk add speedtest-cli",
	unknown = "pip install speedtest-cli",
}

-- Forward declarations so functions can reference each other regardless of
-- definition order below.
local render, renderIdle, renderRunning, renderDone, renderError
local metricRow, renderHistory, renderHistoryCard, speedMetricSquare
local startTest, proceedWithLegacyOrError, runOoklaBackend, runLegacyBackend, onSpeedtestLine
local normalizeOokla, normalizeLegacy
local saveLastResult, loadLastResult, loadHistory, addHistory, fetchClientInfo
local detectPackageManager

-- ── Helpers ───────────────────────────────────────────────────────────────

local function bandwidthBytesToMbps(bandwidthBytesPerSec: number?): number
	if not bandwidthBytesPerSec then
		return 0
	end
	return bandwidthBytesPerSec * 8 / 1000000
end

local function bitsToMbps(bitsPerSec: number?): number
	if not bitsPerSec then
		return 0
	end
	return bitsPerSec / 1000000
end

local function formatMetric(value: number?, fmt: string): string
	if value == nil then
		return "-"
	end
	return string.format(fmt, value)
end

-- Guaranteed-to-render gauge fallback: plain text made of block characters.
-- Doesn't depend on any unconfirmed ui.progress prop.
local function textBar(value: number, width: number): string
	local filled = math.floor(math.max(0, math.min(1, value)) * width + 0.5)
	return string.rep("\u{2588}", filled) .. string.rep("\u{2591}", width - filled)
end

local function fixedSpace(size: number)
	return ui.box({ width = 1, height = size })
end

metricRow = function(labelKey: string, value: string, glyphName: string?)
	return ui.row({
		gap = 10,
		align = "center",
		fill = "surface_variant",
		radius = 10,
		paddingH = 10,
		paddingV = 8,
	}, {
		ui.glyph({ name = glyphName or "circle", size = 17, color = "on_surface_variant" }),
		ui.column({ gap = 2, flexGrow = 1, align = "start" }, {
			ui.label({ text = noctalia.tr(labelKey), fontSize = 11, color = "on_surface_variant" }),
			ui.label({ text = value, fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 2, maxWidth = 320 }),
		}),
	})
end

local function sectionHeader(labelKey: string, glyphName: string)
	return ui.row({ gap = 8, align = "center", paddingV = 2 }, {
		ui.glyph({ name = glyphName, size = 17, color = "primary" }),
		ui.label({ text = noctalia.tr(labelKey), fontSize = 13, fontWeight = "bold", color = "on_surface" }),
	})
end

local function heroCircle(labelKey: string, arrowGlyph: string, valueText: string, accent: string, soft: string)
	return ui.column({ gap = 7, align = "center", flexGrow = 1 }, {
		ui.column({
			width = 136,
			height = 136,
			radius = 68,
			fill = soft,
			border = accent,
			borderWidth = 3,
			align = "center",
			justify = "center",
			gap = 2,
		}, {
			-- Direction icon gets its own circular badge, matching the requested result design.
			ui.column({
				width = 42,
				height = 42,
				radius = 21,
				fill = soft,
				border = accent,
				borderWidth = 1,
				align = "center",
				justify = "center",
			}, {
				ui.glyph({ name = arrowGlyph, size = 23, color = accent }),
			}),
			ui.label({ text = valueText, fontSize = 29, fontWeight = "heavy", color = "on_surface" }),
			ui.label({ text = noctalia.tr("unit_mbps"), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
		}),
		ui.row({
			gap = 5,
			align = "center",
			fill = soft,
			radius = 999,
			paddingH = 12,
			paddingV = 5,
		}, {
			ui.glyph({ name = arrowGlyph, size = 14, color = accent }),
			ui.label({ text = noctalia.tr(labelKey), fontSize = 12, fontWeight = "bold", color = "on_surface" }),
		}),
	})
end

local function smallStat(labelKey: string, valueText: string, glyphName: string, accent: string)
	return ui.column({
		gap = 5,
		align = "center",
		flexGrow = 1,
		fill = "surface_variant",
		radius = 12,
		paddingH = 8,
		paddingV = 10,
		border = "outline",
		borderWidth = 1,
	}, {
		ui.glyph({ name = glyphName, size = 19, color = accent }),
		ui.label({ text = noctalia.tr(labelKey), fontSize = 10, color = "on_surface_variant", textAlign = "center" }),
		ui.label({ text = valueText, fontSize = 15, fontWeight = "bold", color = "on_surface", textAlign = "center" }),
	})
end

local function titleBlock()
	return ui.column({ gap = 3, align = "center", paddingV = 4 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "brand-speedtest", size = 21, color = "primary" }),
			ui.label({ text = noctalia.tr("result_title"), fontSize = 20, fontWeight = "heavy", color = "on_surface" }),
		}),
		ui.label({ text = noctalia.tr("connection_tested_successfully"), fontSize = 11, color = "on_surface_variant" }),
	})
end

-- ── Package manager detection (for install instructions) ──────────────────

detectPackageManager = function(): string
	if noctalia.commandExists("pacman") then
		return "pacman"
	elseif noctalia.commandExists("apt") then
		return "apt"
	elseif noctalia.commandExists("dnf") then
		return "dnf"
	elseif noctalia.commandExists("zypper") then
		return "zypper"
	elseif noctalia.commandExists("apk") then
		return "apk"
	end
	return "unknown"
end

-- ── Result normalization (both backends map into this common shape) ───────

normalizeOokla = function(data: any)
	local server = data.server or {}
	local iface = data.interface or {}
	local res = data.result or {}
	local ping = data.ping or {}
	return {
		downloadMbps = bandwidthBytesToMbps(data.download and data.download.bandwidth),
		uploadMbps = bandwidthBytesToMbps(data.upload and data.upload.bandwidth),
		pingMs = ping.latency,
		jitterMs = ping.jitter,
		packetLoss = data.packetLoss,
		serverName = server.name,
		serverHost = server.host,
		serverLocation = server.location,
		serverCountry = server.country,
		serverIp = server.ip,
		isp = data.isp,
		externalIp = iface.externalIp,
		resultUrl = res.url,
	}
end

-- Python speedtest-cli's --json output: download/upload are already in
-- bits/sec (not bytes/sec like Ookla's), and it has no jitter/packetLoss.
normalizeLegacy = function(data: any)
	local server = data.server or {}
	local client = data.client or {}
	return {
		downloadMbps = bitsToMbps(data.download),
		uploadMbps = bitsToMbps(data.upload),
		pingMs = data.ping,
		jitterMs = nil,
		packetLoss = nil,
		serverName = server.sponsor,
		serverHost = server.host,
		serverLocation = server.name,
		serverCountry = server.country,
		serverIp = nil,
		isp = client.isp,
		externalIp = client.ip,
		resultUrl = data.share,
	}
end

-- ── Persistence (so the last result survives closing the panel) ────────────

saveLastResult = function(data: any)
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local encoded = noctalia.json.encode(data, false)
	if encoded then
		noctalia.writeFile(dir .. DATA_FILE, encoded)
	end
end

loadLastResult = function()
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local contents = noctalia.readFile(dir .. DATA_FILE)
	if not contents then
		return
	end
	local data = noctalia.json.decode(contents)
	if data then
		result = data
		-- Armazena os valores do último resultado para usar na simulação
		if data.downloadMbps then
			lastDownloadMbps = data.downloadMbps
		end
		if data.uploadMbps then
			lastUploadMbps = data.uploadMbps
		end
	end
end

local HISTORY_FILE = "/history.json"

local persistHistory = function()
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local encoded = noctalia.json.encode(history, false)
	if encoded then
		noctalia.writeFile(dir .. HISTORY_FILE, encoded)
	end
end

loadHistory = function()
	local dir = noctalia.pluginDataDir()
	if not dir then
		history = {}
		return
	end

	local contents = noctalia.readFile(dir .. HISTORY_FILE)
	if not contents then
		history = {}
		return
	end

	local data = noctalia.json.decode(contents)
	if type(data) == "table" then
		history = {}
		for i = 1, math.min(#data, 5) do
			history[i] = data[i]
		end
	else
		history = {}
	end
end

addHistory = function(data: any)
	if not data then
		return
	end

	-- Keep a small, newest-first history. The active result is also kept in
	-- /last-result.json for backwards compatibility with older installations.
	local entry = {}
	for key, value in pairs(data) do
		entry[key] = value
	end
	entry.timestamp = os.time()

	local updated = { entry }
	for i = 1, math.min(#history, 4) do
		updated[#updated + 1] = history[i]
	end
	history = updated
	persistHistory()
end

-- Optional enrichment: adds the client's own public IP geolocation
-- (city/region/country/ISP org) alongside whatever the backend reported.
fetchClientInfo = function()
	noctalia.http({ url = "https://ipapi.co/json/" }, function(response)
		if response.ok and response.status == 200 then
			local data = noctalia.json.decode(response.body)
			if data then
				clientInfo = data
				render() -- no-op internally if the panel is closed
			end
		end
	end)
end

-- ── Speedtest run ────────────────────────────────────────────────────────

startTest = function()
	if state == "running" then
		return
	end

	errorMessage = nil
	result = nil
	clientInfo = nil
	phase = ""
	liveMbps = 0
	gaugeMax = 100
	runningElapsed = 0
	backendInUse = nil
	progressValue = 0
	simulatedMbps = 0
	timerRunning = true
	state = "running"
	panel.setNeedsFrameTick(true)
	render()

	-- A binary named `speedtest` isn't proof it's the Ookla CLI: on Arch (and
	-- possibly elsewhere), the official `speedtest-cli` package installs
	-- BOTH `speedtest-cli` and a `speedtest` entry point pointing at the
	-- same Python tool, which doesn't understand Ookla's
	-- `--format=json --progress=yes` flags. So `speedtest` is verified by
	-- its --version output before being trusted, with `speedtest-cli`
	-- (unambiguous) as the fallback either way.
	if noctalia.commandExists("speedtest") then
		local started = noctalia.runAsync("speedtest --version", function(res)
			local versionText = string.lower(res.stdout or "")
			if not res.timedOut and string.find(versionText, "ookla", 1, true) then
				backendInUse = "ookla"
				render()
				runOoklaBackend()
			else
				proceedWithLegacyOrError()
			end
		end, 5000)

		if not started then
			proceedWithLegacyOrError()
		end
	else
		proceedWithLegacyOrError()
	end
end

proceedWithLegacyOrError = function()
	if noctalia.commandExists("speedtest-cli") then
		backendInUse = "legacy"
		render()
		runLegacyBackend()
	else
		state = "error"
		errorMessage = noctalia.tr("error_cli_not_found")
		timerRunning = false
		render()
	end
end

runOoklaBackend = function()
	-- Frame tick drives the "stuck?" watchdog hint below, not just the
	-- legacy backend's pulse.
	panel.setNeedsFrameTick(true)

	-- Many CLI tools fully buffer stdout (instead of line-buffering) once
	-- it's a pipe rather than a real terminal, so `speedtest`'s JSON lines
	-- may not reach onLine until the process exits, or at all if the panel
	-- closes first. `stdbuf -oL` forces line buffering regardless. `stdbuf`
	-- ships in coreutils and is present on effectively every Linux system.
	local cmd = OOKLA_CMD
	if noctalia.commandExists("stdbuf") then
		cmd = "stdbuf -oL " .. OOKLA_CMD
	end

	local started = noctalia.runStream(cmd, onSpeedtestLine)
	if not started then
		state = "error"
		errorMessage = noctalia.tr("error_could_not_start")
		timerRunning = false
		render()
	end
end

runLegacyBackend = function()
	-- No incremental progress from this tool, so pulse the gauge instead.
	panel.setNeedsFrameTick(true)
	local started = noctalia.runAsync(LEGACY_CMD, function(cmdResult)
		panel.setNeedsFrameTick(false)
		timerRunning = false

		if cmdResult.timedOut then
			state = "error"
			errorMessage = noctalia.tr("error_timeout")
			render()
			return
		end

		if cmdResult.exitCode ~= 0 then
			state = "error"
			errorMessage = noctalia.tr("error_cli_reported")
			render()
			return
		end

		local data = noctalia.json.decode(cmdResult.stdout)
		if not data then
			state = "error"
			errorMessage = noctalia.tr("error_cli_reported")
			render()
			return
		end

		result = normalizeLegacy(data)
		state = "done"
		saveLastResult(result)
		addHistory(result)
		fetchClientInfo()
		render()
	end, LEGACY_TIMEOUT_MS)

	if not started then
		panel.setNeedsFrameTick(false)
		timerRunning = false
		state = "error"
		errorMessage = noctalia.tr("error_could_not_start")
		render()
	end
end

onSpeedtestLine = function(line: string)
	local trimmed = noctalia.string.trim(line)
	if trimmed == "" then
		return
	end

	local data = noctalia.json.decode(trimmed)
	if not data then
		return -- ignore partial / malformed lines
	end

	local t = data.type

	if t == "ping" then
		phase = "ping"
		progressValue = 0.15
		render()
	elseif t == "download" then
		phase = "download"
		liveMbps = bandwidthBytesToMbps(data.download and data.download.bandwidth)
		progressValue = 0.50
		render()
	elseif t == "upload" then
		phase = "upload"
		liveMbps = bandwidthBytesToMbps(data.upload and data.upload.bandwidth)
		progressValue = 0.80
		render()
	elseif t == "result" then
		result = normalizeOokla(data)
		state = "done"
		phase = ""
		progressValue = 1.0
		timerRunning = false
		saveLastResult(result)
		addHistory(result)
		fetchClientInfo()
		render()
	elseif t == "error" then
		state = "error"
		errorMessage = data.message or noctalia.tr("error_cli_reported")
		timerRunning = false
		render()
	end
end

-- ── Rendering ────────────────────────────────────────────────────────────

render = function()
	if not panelActive then
		return
	end

	local tree
	if state == "running" then
		tree = renderRunning()
	elseif state == "done" then
		tree = renderDone()
	elseif state == "error" then
		tree = renderError()
	else
		tree = renderIdle()
	end

	panel.render(tree)
end

speedMetricSquare = function(labelKey: string, value: number?, accent: string, soft: string, arrowGlyph: string)
	return ui.column({
		width = 75,
		radius = 10,
		fill = soft,
		border = accent,
		borderWidth = 1,
		paddingH = 6,
		paddingV = 5,
		gap = 1,
		align = "center",
		justify = "center",
	}, {
		ui.row({ gap = 3, align = "center" }, {
			ui.glyph({ name = arrowGlyph, size = 11, color = accent }),
			ui.label({ text = noctalia.tr(labelKey), fontSize = 8, fontWeight = "bold", color = "on_surface_variant" }),
		}),
		ui.label({ text = string.format("%.1f", value or 0), fontSize = 14, fontWeight = "heavy", color = "on_surface" }),
		ui.label({ text = noctalia.tr("unit_mbps"), fontSize = 7, color = "on_surface_variant" }),
	})
end

renderHistoryCard = function(item: any)
	local timestamp = tonumber(item.timestamp or 0) or 0
	local dateText = timestamp > 0 and os.date("%d/%m/%Y  %H:%M", timestamp) or "-"
	local serverText = tostring(item.serverName or "-")
	local locationText = tostring(item.serverLocation or item.serverCountry or "-")
	local countryText = tostring(item.serverCountry or "")
	local locationLine = countryText ~= "" and (locationText .. " - " .. countryText) or locationText

	-- Give the metadata column a real width. On narrow Noctalia panels a
	-- flex-only column can collapse to almost zero, wrapping the date one
	-- character per line and making the whole history card very tall.
	return ui.row({
		gap = 5,
		align = "center",
		fill = "surface_variant",
		radius = 12,
		border = "outline",
		borderWidth = 1,
		paddingH = 9,
		paddingV = 5,
	}, {
		ui.column({
			width = 4,
			height = 50,
			radius = 2,
			fill = "primary",
		}),
		ui.column({ width = 22, align = "center", justify = "center" }, {
			ui.glyph({ name = "brand-speedtest", size = 18, color = "on_surface" }),
		}),
		ui.column({ width = 104, gap = 1, align = "start", justify = "center" }, {
			ui.label({ text = dateText, fontSize = 9, color = "on_surface_variant", maxLines = 1, maxWidth = 104 }),
			ui.label({ text = serverText, fontSize = 10, fontWeight = "bold", color = "on_surface", maxLines = 1, maxWidth = 104 }),
			ui.label({ text = locationLine, fontSize = 8, color = "on_surface_variant", maxLines = 1, maxWidth = 104 }),
		}),
		ui.column({ width = 38, gap = 2, align = "center", justify = "center" }, {
			ui.glyph({ name = "clock", size = 11, color = "tertiary" }),
			ui.label({ text = formatMetric(item.pingMs, "%.1f ms"), fontSize = 8, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
		}),
		speedMetricSquare("metric_download", item.downloadMbps, "primary", "primary/0.12", "arrow-down"),
		speedMetricSquare("metric_upload", item.uploadMbps, "secondary", "secondary/0.12", "arrow-up"),
		ui.column({ width = 12, align = "center", justify = "center" }, {
			ui.glyph({ name = "chevron-right", size = 15, color = "on_surface_variant" }),
		}),
	})
end

renderHistory = function()
	if #history == 0 then
		return nil
	end

	local children = {
		ui.row({ gap = 8, align = "center", justify = "space_between" }, {
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "history", size = 17, color = "primary" }),
				ui.label({ text = noctalia.tr("history_title"), fontSize = 16, fontWeight = "heavy", color = "on_surface" }),
			}),
			ui.label({ text = noctalia.tr("history_limit"), fontSize = 10, color = "on_surface_variant" }),
		}),
		ui.separator({ thickness = 1, color = "outline", spacing = 1 }),
	}

	for i = 1, math.min(#history, 5) do
		children[#children + 1] = renderHistoryCard(history[i])
	end

	return ui.column({
		gap = 5,
		padding = 10,
		fill = "surface/0.96",
		radius = 18,
		border = "outline",
		borderWidth = 1,
	}, children)
end

renderIdle = function()
	local children = {
		ui.column({ gap = 3, align = "center" }, {
			ui.glyph({ name = "brand-speedtest", size = 26, color = "primary" }),
			ui.label({ text = noctalia.tr("app_name"), fontSize = 19, fontWeight = "heavy", color = "on_surface" }),
			ui.label({ text = noctalia.tr("idle_subtitle"), fontSize = 11, color = "on_surface_variant", textAlign = "center", maxWidth = 360 }),
		}),
		fixedSpace(6),
	}

	local historyView = renderHistory()
	if historyView then
		table.insert(children, historyView)
		table.insert(children, fixedSpace(4))
	end

	table.insert(children, ui.button({ text = noctalia.tr("start_test"), glyph = "brand-speedtest", glyphSize = 16, variant = "primary", controlSize = "lg", onClick = startTest }))

	return ui.column({ gap = 6, padding = 14, fill = "surface/0.96", radius = 18, border = "outline", borderWidth = 1, align = "center", minHeight = 670 }, children)
end

renderRunning = function()
	if liveMbps > gaugeMax then
		gaugeMax = math.max(50, math.ceil(liveMbps / 50) * 50)
	end

	local phaseKey = "phase_preparing"
	if backendInUse == "legacy" then
		phaseKey = "phase_legacy_running"
	elseif phase == "ping" then
		phaseKey = "phase_ping"
	elseif phase == "download" then
		phaseKey = "phase_download"
	elseif phase == "upload" then
		phaseKey = "phase_upload"
	end

	local accent = phase == "upload" and "secondary" or "primary"
	local soft = phase == "upload" and "secondary/0.10" or "primary/0.10"
	
	-- Determina qual valor de Mbps mostrar
	local displayMbps = liveMbps
	if backendInUse == "legacy" then
		-- Usa o valor simulado para o backend legacy
		displayMbps = simulatedMbps
	end
	local valueText = string.format("%.1f", displayMbps)

	-- Calcula o progresso baseado no tempo para o legacy backend
	local progress = progressValue
	if backendInUse == "legacy" then
		-- Simula progresso baseado no tempo (0 a 1 em 60 segundos)
		progress = math.min(1.0, runningElapsed / 60)
	end
	
	-- Cria uma barra de progresso em texto (garantido que funciona)
	local barWidth = 30
	local progressPercent = math.floor(progress * 100)
	local filled = math.floor(progress * barWidth)
	local progressBar = string.rep("█", filled) .. string.rep("░", barWidth - filled)

	local children = {
		ui.column({ gap = 4, align = "center" }, {
			ui.glyph({ name = "brand-speedtest", size = 30, color = "primary" }),
			ui.label({ text = noctalia.tr("app_name"), fontSize = 20, fontWeight = "heavy", color = "on_surface" }),
			ui.label({ text = noctalia.tr(phaseKey), fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
		}),
		fixedSpace(8),
		-- Speedometer - sem ícone, apenas o valor em Mbps
		ui.column({
			width = 238,
			height = 238,
			radius = 120,
			fill = soft,
			borderWidth = 0,
			align = "center",
			justify = "center",
			gap = 4,
		}, {
			-- Valor da velocidade em fonte bem grande
			ui.label({ 
				text = valueText, 
				fontSize = 72,  -- Aumentado drasticamente
				fontWeight = "heavy", 
				color = "on_surface" 
			}),
			ui.label({ 
				text = noctalia.tr("unit_mbps"), 
				fontSize = 18,  -- Aumentado também
				fontWeight = "bold", 
				color = "on_surface_variant" 
			}),
		}),
		fixedSpace(6),
		-- Cronômetro padronizado com o tema do Noctalia
		ui.label({ 
			text = string.format("%02d:%02d", math.floor(runningElapsed / 60), math.floor(runningElapsed) % 60), 
			fontSize = 20, 
			fontWeight = "bold", 
			color = "on_surface"
		}),
		-- Barra de progresso em texto (garantida)
		ui.column({
			gap = 4,
			align = "center",
		}, {
			ui.label({ 
				text = progressBar, 
				fontSize = 16, 
				color = accent,
				fontFamily = "monospace"
			}),
			ui.label({ 
				text = string.format("%d%%", progressPercent), 
				fontSize = 24,
				fontWeight = "bold",
				color = accent 
			}),
		}),
	}

	if backendInUse ~= "legacy" then
		table.insert(children, ui.label({ text = noctalia.tr("gauge_scale", { max = gaugeMax }), fontSize = 10, color = "on_surface_variant" }))
	end

	if backendInUse == "ookla" and phase == "" and runningElapsed > 10 then
		table.insert(children, fixedSpace(6))
		table.insert(children, ui.label({ text = noctalia.tr("hint_stuck"), fontSize = 10, color = "on_surface_variant", textAlign = "center" }))
	end

	return ui.column({
		gap = 10,
		padding = 18,
		fill = "surface/0.96",
		radius = 18,
		border = "outline",
		borderWidth = 1,
		align = "center",
		justify = "center",
		minHeight = 670,
	}, children)
end

renderDone = function()
	local r = result or {}
	local children = {
		titleBlock(),
		ui.separator({ thickness = 1, color = "outline", spacing = 4 }),
		ui.row({ gap = 10, align = "center" }, {
			heroCircle("metric_download", "arrow-down", string.format("%.1f", r.downloadMbps or 0), "primary", "primary/0.12"),
			heroCircle("metric_upload", "arrow-up", string.format("%.1f", r.uploadMbps or 0), "secondary", "secondary/0.12"),
		}),
		ui.row({ gap = 8, align = "stretch" }, {
			smallStat("metric_ping", formatMetric(r.pingMs, "%.1f ms"), "clock", "tertiary"),
			smallStat("metric_jitter", formatMetric(r.jitterMs, "%.1f ms"), "activity", "secondary"),
			smallStat("metric_packet_loss", formatMetric(r.packetLoss, "%.1f%%"), "shield-check", "error"),
		}),
		fixedSpace(3),
		sectionHeader("section_server", "server"),
		metricRow("metric_name", tostring(r.serverName or "-"), "server"),
		metricRow("metric_host", tostring(r.serverHost or "-"), "world"),
		metricRow("metric_location", tostring(r.serverLocation or "-"), "map-pin"),
		metricRow("metric_country", tostring(r.serverCountry or "-"), "flag"),
		metricRow("metric_server_ip", tostring(r.serverIp or "-"), "server"),
		fixedSpace(3),
		sectionHeader("section_connection", "wifi"),
		metricRow("metric_isp", tostring(r.isp or "-"), "wifi"),
		metricRow("metric_external_ip", tostring(r.externalIp or "-"), "world"),
	}

	if clientInfo then
		table.insert(children, metricRow("metric_city", tostring(clientInfo.city or "-"), "map-pin"))
		table.insert(children, metricRow("metric_region", tostring(clientInfo.region or "-"), "map"))
		table.insert(children, metricRow("metric_country_ip", tostring(clientInfo.country_name or "-"), "flag"))
		table.insert(children, metricRow("metric_org", tostring(clientInfo.org or "-"), "building"))
	end

	table.insert(children, fixedSpace(4))
	table.insert(children, ui.column({ gap = 8, align = "center", paddingV = 2 }, {
		ui.button({ text = noctalia.tr("test_again"), glyph = "refresh", glyphSize = 15, variant = "primary", controlSize = "md", onClick = startTest }),
		r.resultUrl and ui.button({ text = noctalia.tr("copy_result_link"), glyph = "copy", glyphSize = 14, variant = "outline", controlSize = "md", onClick = function()
			noctalia.copyToClipboard(r.resultUrl, "text/plain")
			noctalia.notify(noctalia.tr("app_name"), noctalia.tr("notify_link_copied"))
		end }) or nil,
	}))

	local historyView = renderHistory()
	if historyView then
		table.insert(children, fixedSpace(7))
		table.insert(children, historyView)
	end

	return ui.scroll({
		gap = 9,
		padding = 14,
		fill = "surface",
		radius = 18,
		border = "outline",
		borderWidth = 1,
		flexGrow = 1,
	}, children)
end

renderError = function()
	local pkgManager = detectPackageManager()
	local installCmd = INSTALL_COMMANDS[pkgManager] or INSTALL_COMMANDS.unknown

	return ui.column({ gap = 10, padding = 18, fill = "surface/0.96", radius = 18, border = "error", borderWidth = 1 }, {
		ui.glyph({ name = "circle-x", size = 30, color = "error" }),
		ui.label({ text = noctalia.tr("error_title"), fontSize = 18, fontWeight = "heavy", color = "on_surface", textAlign = "center" }),
		ui.label({ text = errorMessage or noctalia.tr("error_unknown"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
		ui.separator({ thickness = 1, color = "outline", spacing = 3 }),
		ui.label({ text = noctalia.tr("error_missing_cli"), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
		ui.label({ text = installCmd, fontSize = 11, fontWeight = "bold", color = "on_surface", textAlign = "center" }),
		ui.button({ text = noctalia.tr("copy_install_command"), glyph = "copy", glyphSize = 14, variant = "outline", controlSize = "md", onClick = function()
			noctalia.copyToClipboard(installCmd, "text/plain")
			noctalia.notify(noctalia.tr("app_name"), noctalia.tr("notify_command_copied"))
		end }),
		ui.label({ text = noctalia.tr("error_ookla_hint"), fontSize = 10, color = "on_surface_variant", textAlign = "center" }),
		ui.button({ text = noctalia.tr("try_again"), glyph = "refresh", glyphSize = 14, variant = "primary", controlSize = "md", onClick = startTest }),
	})
end

-- ── Panel lifecycle ──────────────────────────────────────────────────────

function onOpen(context: any)
	panelActive = true
	if state == "idle" and result == nil then
		loadLastResult()
		loadHistory()
	elseif #history == 0 then
		loadHistory()
	end
	if state == "running" then
		-- Reopened while a test was still going (or had already finished
		-- while closed, in which case state is already "done" by now and
		-- this branch is skipped) — resume the pulse/elapsed-timer ticks.
		panel.setNeedsFrameTick(true)
	end
	render()
end

function onClose()
	panelActive = false
	panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs: number)
	if state ~= "running" then
		return
	end
	
	-- Atualiza o tempo
	runningElapsed = runningElapsed + (deltaMs / 1000)
	
	-- Atualiza o progresso para o legacy backend
	if backendInUse == "legacy" then
		progressValue = math.min(1.0, runningElapsed / 60)
		
		-- Usa o último resultado como base para a simulação
		local baseSpeed = lastDownloadMbps
		
		-- Se não houver resultado anterior, usa um valor padrão realista
		if baseSpeed == 0 or baseSpeed == nil then
			baseSpeed = 50 -- valor padrão para conexões comuns
		end
		
		-- Cria variação realista baseada na velocidade real
		-- Quanto maior a velocidade, maior a variação possível
		local variationRange = math.max(5, baseSpeed * 0.3) -- 30% de variação
		local wave = math.sin(runningElapsed * 1.5) * 0.5 + 0.5  -- 0 a 1 oscilando
		
		-- Variação que começa abaixo da velocidade base e vai até acima
		local variation = (wave * 2 - 1) * variationRange
		
		-- A velocidade simulada oscila ao redor da velocidade base
		simulatedMbps = math.max(0.5, baseSpeed + variation)
		
		-- Atualiza o gaugeMax para acomodar a simulação
		if simulatedMbps > gaugeMax then
			gaugeMax = math.max(50, math.ceil(simulatedMbps / 50) * 50)
		end
	end
	
	-- Sempre renderiza para atualizar o cronômetro e a barra de progresso
	render()
end
