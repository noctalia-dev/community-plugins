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
local panelActive = false
local progressValue = 0 -- 0 to 1 for progress tracking
local timerRunning = false -- flag to control timer updates
local simulatedMbps = 0
local lastDownloadMbps = 0
local lastUploadMbps = 0
local liveDownloadMbps = 0
local liveUploadMbps = 0
local livePingMs: number? = nil
local liveServerName: string? = nil
local liveServerLocation: string? = nil
local liveIsp: string? = nil
local liveExternalIp: string? = nil
local liveServerHost: string? = nil
local liveServerCountry: string? = nil
local liveServerIp: string? = nil
local liveServerId: string? = nil
local animatedDownloadMbps = 0
local animatedUploadMbps = 0
local testLogs: any = {}
-- Circular speedometer gauge (Python worker + Pillow, same rendering core as
-- the official "processes" plugin). Falls back to plain circles when python3
-- or Pillow is unavailable.
local downGaugePath: string? = nil
local upGaugePath: string? = nil
local gaugeReady = false
local gaugeKey = 0
local gaugeWorkerPid: number? = nil
local gaugeWorkerStarted = false
local gaugeForceWrite = false
local lastGaugeWriteMs = 0
local lastGaugeDownPct = -1
local lastGaugeUpPct = -1
local finishingResult = false
local metadataReady = false
local metadataInFlight = false
local finalizingElapsed = 0
local ipApiCache: any = {}
local ipApiCacheLoaded = false
local ipApiRateLimitedUntil = 0

local DATA_FILE = "/last-result.json"
local IPAPI_CACHE_FILE = "/ipapi-cache.json"
local OOKLA_CMD = "speedtest --accept-license --accept-gdpr --format=json --progress=yes"
local LEGACY_CMD = "speedtest-cli --secure"

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
local addTestLog, parseLegacyLogLine, renderLiveLog, liveMetricCircle, renderLiveInfoCards
local metricRow, renderHistory, renderHistoryCard, speedMetricSquare
local startTest, proceedWithLegacyOrError, runOoklaBackend, runLegacyBackend, onSpeedtestLine, prepareLegacyServerMetadata, fetchLegacyServerMetadataAfterTest
local normalizeOokla, normalizeLegacy
local saveLastResult, loadLastResult, loadHistory, addHistory
local detectPackageManager
local startGaugeWorker, stopGaugeWorker, writeGaugeInput, maybeRefreshGauges, renderGauge, ensureGaugeWorker

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

local gaugeBase: string? = nil
local function gaugeBasePath()
	if gaugeBase == nil then
		local dir = noctalia.getenv("XDG_RUNTIME_DIR")
		if not dir or dir == "" then
			dir = noctalia.getenv("TMPDIR")
		end
		if not dir or dir == "" then
			dir = "/tmp"
		end
		gaugeBase = dir .. "/noctalia_nilsonlinux_speedtest"
	end
	return gaugeBase
end

local function gaugeLivePath()
	return gaugeBasePath() .. "_live.json"
end

local function gaugeDownloadPath()
	return gaugeBasePath() .. "_download.png"
end

local function gaugeUploadPath()
	return gaugeBasePath() .. "_upload.png"
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

local function smallStat(labelKey: string, valueText: string, glyphName: string, accent: string, cardWidth: number?, cardHeight: number?)
	local width = cardWidth or 137
	local height = cardHeight or 76
	return ui.column({
		width = width,
		height = height,
		minWidth = width,
		maxWidth = width,
		minHeight = height,
		maxHeight = height,
		gap = 4,
		align = "center",
		justify = "center",
		fill = "surface_variant",
		radius = 12,
		paddingH = 4,
		paddingV = 5,
		border = "outline",
		borderWidth = 1,
	}, {
		ui.glyph({ name = glyphName, size = 18, color = accent }),
		ui.label({ text = noctalia.tr(labelKey), fontSize = 9, color = "on_surface_variant", textAlign = "center", maxLines = 1, maxWidth = width - 12 }),
		ui.label({ text = valueText, fontSize = 12, fontWeight = "bold", color = "on_surface", textAlign = "center", maxLines = 2, maxWidth = width - 12 }),
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

-- ── Live CLI log + metrics ────────────────────────────────────────────────

addTestLog = function(line: string)
	line = noctalia.string.trim(line)
	if line == "" then
		return
	end
	-- Keep the latest 12 lines: enough to show the complete speedtest-cli
	-- sequence without allowing the panel to grow indefinitely.
	if #testLogs >= 12 then
		table.remove(testLogs, 1)
	end
	testLogs[#testLogs + 1] = line
end

local function extractNumber(text: string, pattern: string): number?
	local value = string.match(text, pattern)
	return value and tonumber(value) or nil
end

parseLegacyLogLine = function(line: string)
	local lower = string.lower(line)

	if string.find(lower, "retrieving speedtest.net configuration", 1, true) then
		phase = "ping"
		progressValue = math.max(progressValue, 0.05)
	elseif string.find(lower, "testing from", 1, true) then
		liveIsp = string.match(line, "Testing from%s+(.+)%s+%(([%d%.]+)%)") or liveIsp
		liveExternalIp = string.match(line, "%(([%d%.]+)%)") or liveExternalIp
		progressValue = math.max(progressValue, 0.10)
	elseif string.find(lower, "selecting best server", 1, true) then
		phase = "ping"
		progressValue = math.max(progressValue, 0.20)
	elseif string.find(lower, "hosted by", 1, true) then
		phase = "ping"
		liveServerName, liveServerLocation = string.match(line, "Hosted by%s+(.+)%s+%(([^%)]+)%)")
		livePingMs = extractNumber(line, ":%s*([%d%.]+)%s*ms")
		progressValue = math.max(progressValue, 0.30)
	elseif string.find(lower, "testing download speed", 1, true) then
		phase = "download"
		progressValue = math.max(progressValue, 0.35)
	elseif string.find(lower, "download:", 1, true) then
		phase = "download"
		liveDownloadMbps = extractNumber(line, "Download:%s*([%d%.]+)%s*Mbit/s") or liveDownloadMbps
		progressValue = math.max(progressValue, 0.65)
		lastDownloadMbps = liveDownloadMbps
	elseif string.find(lower, "testing upload speed", 1, true) then
		phase = "upload"
		progressValue = math.max(progressValue, 0.70)
	elseif string.find(lower, "upload:", 1, true) then
		phase = "upload"
		liveUploadMbps = extractNumber(line, "Upload:%s*([%d%.]+)%s*Mbit/s") or liveUploadMbps
		progressValue = 1.0
		lastUploadMbps = liveUploadMbps
	end
end

renderLiveLog = function()
	local logChildren = {}
	for i = 1, #testLogs do
		local line = testLogs[i]
		local isDownload = string.find(string.lower(line), "download", 1, true) ~= nil
		local isUpload = string.find(string.lower(line), "upload", 1, true) ~= nil
		local color = isUpload and "secondary" or (isDownload and "primary" or "on_surface_variant")
		logChildren[#logChildren + 1] = ui.label({
			text = line,
			fontSize = 9,
			fontFamily = "monospace",
			color = color,
			maxLines = 1,
			maxWidth = 420,
		})
	end
	if #logChildren == 0 then
		logChildren[1] = ui.label({ text = noctalia.tr("log_waiting"), fontSize = 9, color = "on_surface_variant" })
	end
	return ui.column({
		gap = 2,
		paddingH = 10,
		paddingV = 8,
		fill = "surface_variant",
		radius = 12,
		border = "outline",
		borderWidth = 1,
		align = "start",
	}, logChildren)
end

liveMetricCircle = function(labelKey: string, value: number, accent: string, soft: string, arrowGlyph: string, active: boolean)
	return ui.column({
		width = 154,
		height = 154,
		radius = 77,
		fill = active and soft or "surface_variant",
		border = active and accent or "outline",
		borderWidth = active and 3 or 1,
		align = "center",
		justify = "center",
		gap = 2,
	}, {
		ui.glyph({ name = arrowGlyph, size = 24, color = accent }),
		ui.label({ text = noctalia.tr(labelKey), fontSize = 11, fontWeight = "bold", color = "on_surface_variant" }),
		ui.label({ text = string.format("%.2f", value or 0), fontSize = 31, fontWeight = "heavy", color = "on_surface" }),
		ui.label({ text = noctalia.tr("unit_mbps"), fontSize = 10, color = "on_surface_variant" }),
	})
end

renderLiveInfoCards = function()
	-- The rows deliberately have NO width/height/min/max constraints.
	-- Only the cards themselves are fixed-size.  This prevents Noctalia's
	-- layout container from drawing/expanding an extra box around the cards
	-- on the first frame after the plugin is reloaded.
	local cardWidth = 146
	local cardHeight = 74

	local row1 = ui.row({
		gap = 8,
		align = "start",
		justify = "center",
		padding = 0,
		fill = "#00000000",
		border = "#00000000",
		borderWidth = 0,
		radius = 0,
	}, {
		smallStat("metric_ping", formatMetric(livePingMs, "%.3f ms"), "clock", "tertiary", cardWidth, cardHeight),
		smallStat("metric_server", tostring(liveServerName or "-"), "server", "primary", cardWidth, cardHeight),
	})

	local row2 = ui.row({
		gap = 8,
		align = "start",
		justify = "center",
		padding = 0,
		fill = "#00000000",
		border = "#00000000",
		borderWidth = 0,
		radius = 0,
	}, {
		smallStat("metric_isp", tostring(liveIsp or "-"), "wifi", "secondary", cardWidth, cardHeight),
		smallStat("metric_location", tostring(liveServerLocation or "-"), "map-pin", "tertiary", cardWidth, cardHeight),
	})

	return ui.column({
		gap = 8,
		align = "center",
		justify = "start",
		padding = 0,
		fill = "#00000000",
		border = "#00000000",
		borderWidth = 0,
		radius = 0,
	}, { row1, row2 })
end

-- ── Circular speedometer (Pillow-rendered dial, processes plugin core) ─────

local function normalizeGaugeMax(value: number): number
	if value <= 0 then
		return 100
	end
	if value <= 10 then
		return 10
	end
	return math.max(50, math.ceil(value / 50) * 50)
end

local function currentGaugeValues(): (number, number, number)
	local down = animatedDownloadMbps
	local up = animatedUploadMbps
	if state == "done" and result then
		down = result.downloadMbps or 0
		up = result.uploadMbps or 0
	end
	local max = math.max(gaugeMax, down, up)
	return down, up, normalizeGaugeMax(max)
end

writeGaugeInput = function()
	local down, up, max = currentGaugeValues()
	local payload = {
		download = {
			percent = math.max(0, math.min(100, down / max * 100)),
			value_text = string.format("%.1f", down),
			unit = noctalia.tr("unit_mbps"),
			label = noctalia.tr("metric_download"),
			accent = "120,180,255",
		},
		upload = {
			percent = math.max(0, math.min(100, up / max * 100)),
			value_text = string.format("%.1f", up),
			unit = noctalia.tr("unit_mbps"),
			label = noctalia.tr("metric_upload"),
			accent = "255,185,120",
		},
		max_label = string.format("%d", math.floor(max)),
	}
	local encoded = noctalia.json.encode(payload, false)
	if encoded then
		noctalia.writeFile(gaugeLivePath(), encoded)
	end
end

startGaugeWorker = function()
	if gaugeWorkerStarted then
		return
	end
	local dir = noctalia.pluginDir()
	if not dir or not noctalia.commandExists("python3") or not noctalia.fileExists(dir .. "/scripts/speed_gauge.py") then
		return
	end
	local skin = noctalia.isDarkMode() and "dark" or "light"
	local cmd = "python3 " .. dir .. "/scripts/speed_gauge.py " .. gaugeLivePath() .. " " .. gaugeDownloadPath() .. " " .. gaugeUploadPath() .. " " .. skin
	local started = noctalia.runStream(cmd, function(line: string)
		local trimmed = noctalia.string.trim(line)
		local pidText = string.match(trimmed, "speedtest%-gauge:pid:(%d+)")
		if pidText then
			gaugeWorkerPid = tonumber(pidText)
			return
		end
		local readyPath = string.match(trimmed, "speedtest%-gauge:ready:(.+)")
		if readyPath then
			if readyPath == gaugeDownloadPath() then
				downGaugePath = readyPath
			elseif readyPath == gaugeUploadPath() then
				upGaugePath = readyPath
			end
			if downGaugePath and upGaugePath then
				gaugeReady = true
			end
			gaugeKey = noctalia.nowMs()
			render()
		end
	end)
	if started then
		gaugeWorkerStarted = true
	end
end

stopGaugeWorker = function()
	if not gaugeWorkerStarted and not gaugeWorkerPid then
		return
	end
	if gaugeWorkerPid then
		noctalia.runAsync("kill " .. tostring(gaugeWorkerPid))
	end
	gaugeWorkerPid = nil
	gaugeWorkerStarted = false
	gaugeReady = false
	downGaugePath = nil
	upGaugePath = nil
	gaugeKey = 0
	local paths = { gaugeLivePath(), gaugeDownloadPath(), gaugeUploadPath() }
	for _, path in ipairs(paths) do
		pcall(noctalia.removeFile, path)
	end
end

ensureGaugeWorker = function()
	if gaugeWorkerStarted then
		return
	end
	if state == "running" or state == "done" then
		startGaugeWorker()
		writeGaugeInput()
		gaugeForceWrite = true
	end
end

maybeRefreshGauges = function()
	if not gaugeWorkerStarted or gaugeForceWrite then
		if gaugeForceWrite then
			gaugeForceWrite = false
			writeGaugeInput()
		end
		return
	end
	if state == "idle" or state == "error" then
		return
	end
	local down, up, max = currentGaugeValues()
	local downPct = math.max(0, math.min(100, down / max * 100))
	local upPct = math.max(0, math.min(100, up / max * 100))
	local now = noctalia.nowMs()
	-- Track the exact (non-floored) eased percentages so the animating
	-- needle gets fed near-continuously, and settle to a slow refresh rate
	-- (1.5 s) while the values sit still.
	local wobble = math.abs(downPct - lastGaugeDownPct) >= 0.15 or math.abs(upPct - lastGaugeUpPct) >= 0.15
	if now - lastGaugeWriteMs >= 60 and (wobble or now - lastGaugeWriteMs >= 1500) then
		lastGaugeDownPct = downPct
		lastGaugeUpPct = upPct
		lastGaugeWriteMs = now
		writeGaugeInput()
	end
end

renderGauge = function(labelKey: string, value: number, accent: string, soft: string, arrowGlyph: string, kind: string, active: boolean)
	-- If the gauge worker is running but images are not ready yet, show a
	-- transparent placeholder instead of the fallback circle to avoid a
	-- visible flash of the old circle before the speedometer appears.
	if gaugeWorkerStarted and not gaugeReady then
		return ui.box({ width = 160, height = 160, fill = "#00000000" })
	end
	local path = gaugeReady and (kind == "download" and downGaugePath or upGaugePath) or nil
	if path and noctalia.fileExists(path) then
		return ui.image({
			key = "gauge-" .. kind .. "-" .. tostring(gaugeKey),
			path = path,
			width = 160,
			height = 160,
		})
	end
	return liveMetricCircle(labelKey, value, accent, soft, arrowGlyph, active)
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
		serverHost = server.host or (server.url and string.match(server.url, "^[a-zA-Z]+://([^/:]+)")),
		serverLocation = server.name,
		serverCountry = server.country or server.country_name or server.cc,
		serverIp = server.ip,
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

-- Metadata enrichment happens only after the real bandwidth test finishes.
-- ipapi.co is a fallback only: when the server host/country are already known,
-- no request is made. Successful ipapi responses are persisted by server IP so
-- repeated tests against the same server do not consume the API quota again.
local function loadIpApiCache()
	if ipApiCacheLoaded then
		return
	end
	ipApiCacheLoaded = true
	ipApiCache = {}
	ipApiRateLimitedUntil = 0

	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local contents = noctalia.readFile(dir .. IPAPI_CACHE_FILE)
	if not contents or contents == "" then
		return
	end

	local data = noctalia.json.decode(contents)
	if type(data) ~= "table" then
		return
	end

	-- Current format: { entries = { [ip] = {...} }, meta = { ... } }
	if type(data.entries) == "table" then
		ipApiCache = data.entries
		if type(data.meta) == "table" then
			ipApiRateLimitedUntil = tonumber(data.meta.rateLimitedUntil or 0) or 0
		end
	else
		-- Backward-compatible with a plain {[ip] = {...}} cache.
		ipApiCache = data
		ipApiCache._meta = nil
	end
end

local function saveIpApiCache()
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local payload = {
		entries = ipApiCache,
		meta = {
			rateLimitedUntil = ipApiRateLimitedUntil,
		},
	}
	local encoded = noctalia.json.encode(payload, false)
	if encoded then
		noctalia.writeFile(dir .. IPAPI_CACHE_FILE, encoded)
	end
end

local function persistServerMetadata()
	if result then
		saveLastResult(result)
	end
	if history[1] then
		history[1].serverHost = liveServerHost
		history[1].serverCountry = liveServerCountry
		history[1].serverIp = liveServerIp
		persistHistory()
	end
	render()
end

local function applyIpApiData(ip: string, data: any)
	if not data then
		return
	end

	local resolvedIp = tostring(data.ip or ip or "")
	if resolvedIp ~= "" then
		liveServerIp = resolvedIp
	end

	local country = data.country_name or data.country
	if country and tostring(country) ~= "" then
		liveServerCountry = tostring(country)
	end

	local hostname = data.hostname
	if hostname and tostring(hostname) ~= "" then
		liveServerHost = tostring(hostname)
	end

	if result then
		result.serverIp = liveServerIp
		result.serverCountry = liveServerCountry
		result.serverHost = liveServerHost
	end
end

local function queryIpApiCached(ip: string, fallbackCountry: string?)
	loadIpApiCache()
	if not ip or ip == "" then
		metadataReady = true
		persistServerMetadata()
		return
	end

	local now = os.time()
	local cached = ipApiCache[ip]
	if type(cached) == "table" then
		if cached.ok == true then
			applyIpApiData(ip, cached)
			metadataReady = true
			persistServerMetadata()
			return
		end
		if cached.retryUntil and tonumber(cached.retryUntil) and now < tonumber(cached.retryUntil) then
			metadataReady = true
			persistServerMetadata()
			return
		end
	end

	-- A 429 applies to the API quota, not just one server. Avoid sending
	-- another request during the cooldown even when a different server is used.
	if ipApiRateLimitedUntil > now then
		metadataReady = true
		persistServerMetadata()
		return
	end

	-- The country already came from Speedtest's server metadata. Only hit
	-- ipapi when it can still add something useful (country/hostname).
	local needCountry = not liveServerCountry or liveServerCountry == ""
	local needHost = not liveServerHost or liveServerHost == ""
	if not needCountry and not needHost then
		metadataReady = true
		persistServerMetadata()
		return
	end

	noctalia.http({ url = "https://ipapi.co/" .. ip .. "/json/" }, function(response)
		local ok = response and response.ok and response.status == 200 and response.body
		if ok then
			local data = noctalia.json.decode(response.body)
			if data and not data.error then
				local entry = {
					ok = true,
					ip = tostring(data.ip or ip),
					country_name = data.country_name,
					country = data.country,
					hostname = data.hostname,
					fetchedAt = os.time(),
				}
				ipApiCache[ip] = entry
				saveIpApiCache()
				applyIpApiData(ip, entry)
			else
				ipApiCache[ip] = {
					ok = false,
					retryUntil = os.time() + 600,
					status = response and response.status or 0,
				}
				saveIpApiCache()
			end
		else
			local status = response and tonumber(response.status) or 0
			local retrySeconds = status == 429 and 3600 or 600
			if status == 429 then
				ipApiRateLimitedUntil = os.time() + retrySeconds
			end
			ipApiCache[ip] = {
				ok = false,
				retryUntil = os.time() + retrySeconds,
				status = status,
			}
			saveIpApiCache()
			-- Keep the server country we already know as a fallback.
			if fallbackCountry and tostring(fallbackCountry) ~= "" and (not liveServerCountry or liveServerCountry == "") then
				liveServerCountry = tostring(fallbackCountry)
			end
		end

		metadataReady = true
		persistServerMetadata()
	end)
end

local function resolveServerIpAndEnrich(serverHost: string, fallbackCountry: string?)
	if not serverHost or serverHost == "" then
		metadataReady = true
		persistServerMetadata()
		return false
	end

	local host = string.match(serverHost, "^[a-zA-Z]+://([^/:]+)") or string.match(serverHost, "^([^:/]+)")
	if not host or host == "" then
		metadataReady = true
		persistServerMetadata()
		return false
	end

	local function parseIpv4(text: string?): string?
		return string.match(text or "", "(%d+%.%d+%.%d+%.%d+)")
	end

	local function gotIp(ip: string?)
		if ip and ip ~= "" then
			liveServerIp = ip
			if result then
				result.serverIp = ip
			end
			-- ipapi is needed only if host or country is still missing.
			queryIpApiCached(ip, fallbackCountry)
		else
			metadataReady = true
			persistServerMetadata()
		end
	end

	local function resolveWithPython()
		if not noctalia.commandExists("python3") then
			metadataReady = true
			persistServerMetadata()
			return
		end
		local safeHost = string.gsub(host, "'", "'\\''")
		local started = noctalia.runAsync("python3 -c \"import socket; print(socket.gethostbyname('" .. safeHost .. "'))\"", function(res)
			gotIp(parseIpv4(res and res.stdout))
		end, 3000)
		if not started then
			metadataReady = true
			persistServerMetadata()
		end
	end

	local started = noctalia.runAsync("getent ahostsv4 " .. host, function(res)
		local ip = parseIpv4(res and res.stdout)
		if ip then
			gotIp(ip)
			return
		end

		local fallbackStarted = noctalia.runAsync("getent hosts " .. host, function(fallback)
			local fallbackIp = parseIpv4(fallback and fallback.stdout)
			if fallbackIp then
				gotIp(fallbackIp)
			else
				resolveWithPython()
			end
		end, 3000)
		if not fallbackStarted then
			resolveWithPython()
		end
	end, 3000)

	if not started then
		resolveWithPython()
	end

	return true
end

-- Build the server metadata from Speedtest.net's current server directory,
-- matching the server actually displayed by the completed test (sponsor + city).
-- This avoids relying on the human-readable speedtest-cli log, which only prints
-- sponsor/city/ping. The resolved host is then used for server-IP resolution and
-- ipapi.co is contacted only when the cached/server metadata cannot complete the cards.
fetchLegacyServerMetadataAfterTest = function(attempt: number?)
	attempt = attempt or 1
	metadataInFlight = true

	local sponsor = tostring(liveServerName or "")
	local city = tostring(liveServerLocation or "")

	local function applyServer(server: any): boolean
		if not server then
			return false
		end
		local host = tostring(server.host or "")
		local country = tostring(server.country or server.country_name or "")
		local name = tostring(server.name or "")
		local serverSponsor = tostring(server.sponsor or "")
		if host == "" and server.url then
			host = string.match(tostring(server.url), "^[a-zA-Z]+://([^/:]+)") or ""
		end

		if host ~= "" then liveServerHost = host end
		if country ~= "" then liveServerCountry = country end
		if name ~= "" then liveServerLocation = name end
		if serverSponsor ~= "" then liveServerName = serverSponsor end
		if server.id then liveServerId = tostring(server.id) end
		if server.ip then liveServerIp = tostring(server.ip) end
		if result then
			result.serverHost = liveServerHost
			result.serverCountry = liveServerCountry
			result.serverLocation = liveServerLocation
			result.serverName = liveServerName
			result.serverIp = liveServerIp
		end
		if history[1] then
			history[1].serverHost = liveServerHost
			history[1].serverCountry = liveServerCountry
			history[1].serverLocation = liveServerLocation
			history[1].serverName = liveServerName
			history[1].serverIp = liveServerIp
		end
		return host ~= ""
	end

	local function finish()
		metadataInFlight = false
		if result then
			saveLastResult(result)
		end
		if history[1] then
			persistHistory()
		end
		render()
		if liveServerIp and liveServerIp ~= "" then
			queryIpApiCached(liveServerIp, liveServerCountry)
		elseif liveServerHost and liveServerHost ~= "" then
			resolveServerIpAndEnrich(liveServerHost, liveServerCountry)
		else
			metadataReady = true
			render()
		end
	end

	local function requestServerList(search: string, onDone: (any) -> boolean)
		local encoded = string.gsub(search or "", " ", "%%20")
		local url = "https://www.speedtest.net/api/js/servers?engine=js&https_functional=true&limit=100&search=" .. encoded
		noctalia.http({ url = url }, function(response)
			if response and response.ok and response.status == 200 and response.body then
				local list = noctalia.json.decode(response.body)
				if type(list) == "table" then
					local best = nil
					for _, server in ipairs(list) do
						local ss = string.lower(tostring(server.sponsor or ""))
						local sn = string.lower(tostring(server.name or ""))
						local wantSponsor = string.lower(sponsor)
						local wantCity = string.lower(city)
						if sponsor ~= "" and city ~= "" and ss == wantSponsor and sn == wantCity then
							best = server
							break
						end
						if not best and sponsor ~= "" and ss == wantSponsor then
							best = server
						end
					end
					if best and onDone(best) then
						finish()
						return
					end
				end
			end

			-- Compatibility fallback: ask speedtest-cli for the same server metadata
			-- without another bandwidth measurement.
			local jsonStarted = noctalia.runAsync("speedtest-cli --json --secure --no-download --no-upload", function(res)
				local output = res and (res.stdout or res.stderr or "") or ""
				local data = res and not res.timedOut and res.exitCode == 0 and output ~= "" and noctalia.json.decode(output) or nil
				if data then
					local normalized = normalizeLegacy(data)
					if normalized.serverHost and normalized.serverHost ~= "" then liveServerHost = normalized.serverHost end
					if normalized.serverCountry and normalized.serverCountry ~= "" then liveServerCountry = normalized.serverCountry end
					if normalized.serverLocation and normalized.serverLocation ~= "" then liveServerLocation = normalized.serverLocation end
					if normalized.serverName and normalized.serverName ~= "" then liveServerName = normalized.serverName end
					if normalized.serverIp and normalized.serverIp ~= "" then liveServerIp = normalized.serverIp end
					if result then
						result.serverHost = liveServerHost
						result.serverCountry = liveServerCountry
						result.serverLocation = liveServerLocation
						result.serverName = liveServerName
						result.serverIp = liveServerIp
						result.isp = normalized.isp or result.isp
						result.externalIp = normalized.externalIp or result.externalIp
					end
					finish()
				else
					if attempt < 3 then
						noctalia.runAsync("sleep 0.5", function()
							fetchLegacyServerMetadataAfterTest(attempt + 1)
						end, 2000)
					else
						finish()
					end
				end
			end, 10000)
			if not jsonStarted and attempt >= 3 then
				finish()
			end
		end)
		return true
	end

	local query = city ~= "" and city or sponsor
	if query == "" then
		finish()
		return
	end

	requestServerList(query, applyServer)
end

-- ── Speedtest run ────────────────────────────────────────────────────────

startTest = function()
	if state == "running" then
		return
	end

	errorMessage = nil
	result = nil
	phase = ""
	liveMbps = 0
	gaugeMax = 100
	runningElapsed = 0
	backendInUse = nil
	progressValue = 0
	simulatedMbps = 0
	liveDownloadMbps = 0
	liveUploadMbps = 0
	livePingMs = nil
	liveServerName = nil
	liveServerLocation = nil
	liveIsp = nil
	liveExternalIp = nil
	liveServerHost = nil
	liveServerCountry = nil
	liveServerIp = nil
	liveServerId = nil
	finishingResult = false
	metadataReady = false
	metadataInFlight = false
	finalizingElapsed = 0
	animatedDownloadMbps = 0
	animatedUploadMbps = 0
	testLogs = {}
	timerRunning = true
	state = "running"
	panel.setNeedsFrameTick(true)
	ensureGaugeWorker()
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
	-- Keep the real speedtest-cli human-readable stream for live logs and
	-- animation. The optional metadata preflight has already selected the server.
	panel.setNeedsFrameTick(true)
	local cmd = "speedtest-cli --secure"
	if liveServerId and liveServerId ~= "" then
		cmd = cmd .. " --server " .. liveServerId
	end
	if noctalia.commandExists("stdbuf") then
		cmd = "stdbuf -oL " .. cmd
	end

	local started = noctalia.runStream(cmd, function(line: string)
		local trimmed = noctalia.string.trim(line)
		if trimmed == "" then
			return
		end

		addTestLog(trimmed)
		parseLegacyLogLine(trimmed)

		if string.find(string.lower(trimmed), "upload:", 1, true) then
			result = {
				downloadMbps = liveDownloadMbps,
				uploadMbps = liveUploadMbps,
				pingMs = livePingMs,
				jitterMs = nil,
				packetLoss = nil,
				serverName = liveServerName,
				serverHost = liveServerHost,
				serverLocation = liveServerLocation,
				serverCountry = liveServerCountry,
				serverIp = liveServerIp,
				isp = liveIsp,
				externalIp = liveExternalIp,
				resultUrl = nil,
			}
			lastDownloadMbps = result.downloadMbps or 0
			lastUploadMbps = result.uploadMbps or 0
			finishingResult = true
			metadataReady = false
			metadataInFlight = false
			finalizingElapsed = 0
			phase = "upload"
			progressValue = 1.0
			timerRunning = true
			saveLastResult(result)
			addHistory(result)
			fetchLegacyServerMetadataAfterTest()
			writeGaugeInput()
			render()
			return
		end

		render()
	end)

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

	addTestLog(trimmed)
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
		local normalized = normalizeOokla(data)
		liveServerHost = normalized.serverHost
		liveServerCountry = normalized.serverCountry
		liveServerIp = normalized.serverIp
		result = normalized
		state = "done"
		phase = ""
		progressValue = 1.0
		timerRunning = false
		saveLastResult(result)
		addHistory(result)
		writeGaugeInput()
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
	if liveDownloadMbps > gaugeMax then
		gaugeMax = math.max(50, math.ceil(liveDownloadMbps / 50) * 50)
	end
	if liveUploadMbps > gaugeMax then
		gaugeMax = math.max(50, math.ceil(liveUploadMbps / 50) * 50)
	end

	local phaseKey = "phase_preparing"
	if phase == "ping" then
		phaseKey = "phase_ping"
	elseif phase == "download" then
		phaseKey = "phase_download"
	elseif phase == "upload" then
		phaseKey = "phase_upload"
	end

	local progress = math.max(0, math.min(1, progressValue))
	local progressPercent = math.floor(progress * 100)
	local barWidth = 300
	local filledWidth = math.floor(barWidth * progress)

	local children = {
		ui.column({ gap = 3, align = "center" }, {
			ui.row({ gap = 8, align = "center" }, {
				ui.glyph({ name = "brand-speedtest", size = 24, color = "primary" }),
				ui.label({ text = noctalia.tr("app_name"), fontSize = 19, fontWeight = "heavy", color = "on_surface" }),
			}),
			ui.label({ text = noctalia.tr(phaseKey), fontSize = 11, color = "on_surface_variant", textAlign = "center" }),
		}),
		ui.row({ gap = 10, align = "center", justify = "center" }, {
			renderGauge("metric_download", animatedDownloadMbps, "primary", "primary/0.12", "arrow-down", "download", phase == "download"),
			renderGauge("metric_upload", animatedUploadMbps, "secondary", "secondary/0.12", "arrow-up", "upload", phase == "upload"),
		}),
		renderLiveInfoCards(),
		ui.column({
			gap = 5,
			width = barWidth,
			align = "stretch",
		}, {
			ui.row({
				width = barWidth,
				height = 14,
				radius = 7,
				fill = "surface_variant",
			}, {
				ui.column({
					width = math.max(1, filledWidth),
					height = 14,
					radius = 7,
					fill = phase == "upload" and "secondary" or "primary",
				}),
			}),
			ui.row({ gap = 6, align = "center", justify = "space_between" }, {
				ui.label({ text = string.format("%d%%", progressPercent), fontSize = 12, fontWeight = "bold", color = phase == "upload" and "secondary" or "primary" }),
				ui.label({ text = string.format("%02d:%02d", math.floor(runningElapsed / 60), math.floor(runningElapsed) % 60), fontSize = 12, color = "on_surface_variant" }),
			}),
		}),
		renderLiveLog(),
	}

	return ui.column({
		gap = 9,
		padding = 14,
		fill = "surface/0.96",
		radius = 18,
		border = "outline",
		borderWidth = 1,
		align = "center",
		minHeight = 670,
	}, children)
end

renderDone = function()
	local r = result or {}
	local children = {
		titleBlock(),
		ui.separator({ thickness = 1, color = "outline", spacing = 4 }),
		ui.row({ gap = 10, align = "center", justify = "center" }, {
			renderGauge("metric_download", r.downloadMbps or 0, "primary", "primary/0.12", "arrow-down", "download", true),
			renderGauge("metric_upload", r.uploadMbps or 0, "secondary", "secondary/0.12", "arrow-up", "upload", true),
		}),
		ui.row({
			width = 312,
			minWidth = 312,
			maxWidth = 312,
			height = 76,
			minHeight = 76,
			maxHeight = 76,
			gap = 6,
			align = "start",
			justify = "start",
		}, {
			smallStat("metric_ping", formatMetric(r.pingMs, "%.1f ms"), "clock", "tertiary", 128, 76),
			smallStat("metric_jitter", formatMetric(r.jitterMs, "%.1f ms"), "activity", "secondary", 128, 76),
			smallStat("metric_packet_loss", formatMetric(r.packetLoss, "%.1f%%"), "shield-check", "error", 128, 76),
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
	loadIpApiCache()
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
	ensureGaugeWorker()
	render()
end

function onClose()
	panelActive = false
	panel.setNeedsFrameTick(false)
	stopGaugeWorker()
end

function onFrameTick(deltaMs: number)
	if state ~= "running" then
		return
	end

	runningElapsed = runningElapsed + (deltaMs / 1000)

	local easing = math.min(1, (deltaMs / 1000) * 5)
	local downloadTarget = liveDownloadMbps
	local uploadTarget = liveUploadMbps
	-- Legacy speedtest-cli only emits the final Download/Upload values. While
	-- waiting for those lines, use a restrained pulse based on the previous
	-- result so the gauge visibly remains active without replacing the final
	-- measured value once it arrives.
	if phase == "download" and liveDownloadMbps <= 0 then
		local base = lastDownloadMbps > 0 and lastDownloadMbps or 10
		downloadTarget = base * (0.18 + 0.10 * (0.5 + 0.5 * math.sin(runningElapsed * 8)))
	elseif phase == "upload" and liveUploadMbps <= 0 then
		local base = lastUploadMbps > 0 and lastUploadMbps or 3
		uploadTarget = base * (0.18 + 0.10 * (0.5 + 0.5 * math.sin(runningElapsed * 8)))
	end
	animatedDownloadMbps = animatedDownloadMbps + (downloadTarget - animatedDownloadMbps) * easing
	animatedUploadMbps = animatedUploadMbps + (uploadTarget - animatedUploadMbps) * easing
	if liveDownloadMbps > 0 and math.abs(liveDownloadMbps - animatedDownloadMbps) < 0.01 then animatedDownloadMbps = liveDownloadMbps end
	if liveUploadMbps > 0 and math.abs(liveUploadMbps - animatedUploadMbps) < 0.01 then animatedUploadMbps = liveUploadMbps end

	if finishingResult and result then
		finalizingElapsed = finalizingElapsed + (deltaMs / 1000)
		local uploadSettled = math.abs((result.uploadMbps or 0) - animatedUploadMbps) < 0.05
		-- Stay on the live Upload screen until the animation has visibly settled
		-- AND metadata lookup has had a chance to populate the result cards.
		-- A hard timeout prevents the panel from getting stuck forever if the
		-- external metadata services are unavailable.
		if uploadSettled and metadataReady and finalizingElapsed >= 1.25 then
			finishingResult = false
			state = "done"
			phase = ""
			timerRunning = false
			animatedDownloadMbps = result.downloadMbps or animatedDownloadMbps
			animatedUploadMbps = result.uploadMbps or animatedUploadMbps
			writeGaugeInput()
		elseif finalizingElapsed >= 10.0 then
			finishingResult = false
			state = "done"
			phase = ""
			timerRunning = false
			animatedDownloadMbps = result.downloadMbps or animatedDownloadMbps
			animatedUploadMbps = result.uploadMbps or animatedUploadMbps
			writeGaugeInput()
		end
	end
	maybeRefreshGauges()
	render()
end
