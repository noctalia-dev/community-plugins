--!nonstrict
-- The shell sends exactly one short line per copy. Streaming raw content line
-- by line overruns the runtime's per-callback CPU budget and event queue on
-- large copies.

-- Enough for the tooltip, which shows at most three lines.
local PREVIEW_BYTES = 512
local displayMax = noctalia.getConfig("max_length")
local last = nil

-- The shell cuts by bytes and can split the last character. Drop it only when
-- the invalid byte is in the last three; text that was never UTF-8 is kept.
local function utf8Safe(s)
    local valid, badAt = utf8.len(s)
    if valid == nil and badAt > #s - 3 then
        return s:sub(1, badAt - 1)
    end
    return s
end

local function truncate(s, max)
    local length = utf8.len(s)
    if length == nil then
        return #s > max and s:sub(1, max) or s
    end
    if length <= max then
        return s
    end
    return s:sub(1, utf8.offset(s, max - 2) - 1) .. "..."
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Each line is <kind><payload>: t = text, m = non-text (payload is the MIME
-- type), s = sensitive (no payload).
local function applyPreview(line)
    if line == last then
        return
    end
    last = line

    local kind = line:sub(1, 1)
    local payload = trim(utf8Safe(line:sub(2)))

    if kind == "s" then
        barWidget.setText(noctalia.tr("bar.sensitive"))
        barWidget.setTooltip(noctalia.tr("tooltip.sensitive"))
    elseif kind == "m" then
        barWidget.setText(noctalia.tr("bar.binary", { type = payload }))
        barWidget.setTooltip(noctalia.tr("tooltip.binary", { type = payload }))
    elseif payload == "" then
        barWidget.setText(noctalia.tr("bar.empty"))
        barWidget.setTooltip(noctalia.tr("tooltip.empty"))
    else
        barWidget.setText(truncate(payload, displayMax))
        barWidget.setTooltip(payload)
    end
end

-- wl-paste sets CLIPBOARD_STATE=sensitive for password-manager copies; older
-- versions don't, so the MIME hint is checked too. The type list decides the
-- branch, because without a text type wl-paste pipes whatever is offered (PNG
-- bytes for an image). Text is read only as far as the preview needs, but
-- every branch drains stdin: a source app blocks writing to an undrained
-- pipe. Electron can announce a selection before its data is
-- ready, so empty text is read once more. The loop restarts wl-paste if it
-- exits.
local WATCH = [==[while :; do
  wl-paste --watch sh -c '
    types=$(wl-paste --list-types 2>/dev/null)
    case "$CLIPBOARD_STATE|$types" in
      sensitive\|*|*x-kde-passwordManagerHint*)
        cat >/dev/null
        c=
        k=s
        ;;
      *text/*)
        c=$(head -c 8192)
        cat >/dev/null
        [ -n "$c" ] || c=$(wl-paste --no-newline -t text 2>/dev/null | head -c 8192)
        k=t
        ;;
      *\|?*)
        cat >/dev/null
        c=$(printf "%s" "$types" | head -n1)
        k=m
        ;;
      *)
        cat >/dev/null
        c=
        k=t
        ;;
    esac
    printf "%s%s\n" "$k" "$(printf "%s" "$c" | tr -s "\n\r\t " " " | head -c @MAX@)"
  '
  sleep 2
done]==]

-- runStream only fails when /bin/sh can't start, so check for wl-paste first.
if not noctalia.commandExists("wl-paste") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.missing-tool"))
elseif not noctalia.runStream((WATCH:gsub("@MAX@", tostring(PREVIEW_BYTES))), applyPreview) then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.stream"))
end
