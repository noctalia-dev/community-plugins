--!nonstrict
-- OCR — control-center quick tile. Mirrors the bar widget's click mapping:
-- left click = OCR a selected region, right click = OCR the focused output.
--
-- Entries run in isolated VMs, so the small capture pipeline is repeated here
-- rather than shared; keep it in sync with ocr.luau.

local busy = false
local available = noctalia.commandExists("grim")
	and noctalia.commandExists("slurp")
	and noctalia.commandExists("tesseract")

local function render()
	shortcut.setLabel(if busy then "OCR — capturing…" else "OCR text grab")
	shortcut.setIcon("scan")
	shortcut.setActive(busy)
	shortcut.setEnabled(available)
end

local function shellQuote(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function buildCommand(wholeOutput)
	local langs = string.gsub(tostring(noctalia.getConfig("languages") or "eng"), "[^%w_+]", "")
	if langs == "" then
		langs = "eng"
	end
	local psm = string.gsub(tostring(noctalia.getConfig("psm") or "6"), "%D", "")
	if psm == "" then
		psm = "6"
	end

	local capture
	if wholeOutput then
		local out = noctalia.focusedOutputName()
		local target = if out then "-o " .. shellQuote(out) .. " " else ""
		capture = 'grim ' .. target .. '"$img"'
	else
		capture = 'geom="$(slurp)" || exit 40; grim -g "$geom" "$img"'
	end

	return 'img="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/noctalia-ocr-XXXXXX.png")" || exit 41; '
		.. capture
		.. ' || { rm -f "$img"; exit 42; }; '
		.. 'txt="$(tesseract "$img" stdout -l ' .. langs .. ' --psm ' .. psm .. ' 2>/dev/null)"; rc=$?; '
		.. 'rm -f "$img"; [ "$rc" -ne 0 ] && exit 43; printf "%s" "$txt"'
end

local function handleResult(result)
	busy = false
	render()

	if result.timedOut then
		noctalia.notifyError("OCR", "Timed out — selection must finish within 60 seconds")
		return
	end
	if result.exitCode == 40 then
		return -- selection cancelled by the user
	end
	if result.exitCode == 42 then
		noctalia.notifyError("OCR", "Screenshot failed (grim)")
		return
	end
	if result.exitCode ~= 0 then
		noctalia.notifyError("OCR", "Text recognition failed (exit " .. tostring(result.exitCode) .. ")")
		return
	end

	local text = noctalia.string.trim(result.stdout)
	if text == "" then
		noctalia.notify("OCR", "No text recognized in the selection")
		return
	end

	if noctalia.getConfig("copy_to_clipboard") ~= false then
		noctalia.copyToClipboard(text, "text/plain")
	end
	if noctalia.getConfig("show_notification") ~= false then
		local preview = if #text > 160 then string.sub(text, 1, 157) .. "…" else text
		local suffix = if result.stdoutTruncated then " (output truncated)" else ""
		noctalia.notify("OCR — copied" .. suffix, preview)
	end
end

local function grab(wholeOutput)
	if not available or busy then
		return
	end
	busy = true
	render()
	if not noctalia.runAsync(buildCommand(wholeOutput), handleResult, 60000) then
		busy = false
		render()
		noctalia.notifyError("OCR", "Failed to launch capture command")
	end
end

function onClick()
	grab(false)
end

function onRightClick()
	grab(true)
end

render()
