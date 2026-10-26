--!nonstrict
-- keysmith — panel with four tabs.
--
--   Passgen   random characters (length, letters/case, digits, symbols) or a
--             memorable passphrase (EFF large wordlist, wordlist.txt).
--   Keygen    `openssl rand` keys: hex, base64, base64url; plus an
--             alphanumeric key drawn like a Passgen password.
--   JWT       decoder (decode only, the signature is never checked).
--   htpasswd  `htpasswd -n` line (password fed on stdin through a named pipe,
--             never in argv), optionally with every `$` doubled so it can sit
--             in a YAML/compose file.
--
-- Randomness: Luau has no CSPRNG, so every random choice comes from
-- /dev/urandom through `od` (one u32 pool per generation). Picks use rejection
-- sampling, so no character or word is more likely than another.
-- State key: "keysmith_open" (published for the bar glyph).
-- Secrets live in file-locals only and are wiped in onClose. The only things
-- written to disk are the special-characters list and the last tab, both in
-- the plugin data dir, plus a short-lived htpasswd-<n>.fifo pipe node (no data).

local LOWER = "abcdefghijklmnopqrstuvwxyz"
local UPPER = LOWER:upper()
local DIGITS = "0123456789"
local DEFAULT_SYMBOLS = "!@#%^&*()-_=+[]{}:;,.?"
local TWO32 = 4294967296
local SEPARATORS = { "-", ".", "_", "" }

local tab = "passgen"
local nonce = 0 -- bumped per request and on close; stale callbacks see a mismatch
local htpFifo = nil -- pipe of the htpasswd request in flight, removed on close
-- EFF wordlist as one string of fixed 10-byte records ("word" padded to 9
-- chars + "\n"), so a word is a substring and loading needs no parsing.
local WORD_RECORD = 10
local words = nil

local function newGen()
    return {
        mode = "random", -- "random" | "memorable"
        length = 20,
        letters = true,
        case = "mixed", -- "lower" | "upper" | "mixed"
        digits = true,
        symbols = true,
        words = 5,
        sep = "-",
        capital = true,
        number = false,
        result = "",
        bits = 0,
        kind = "password",
        specials = DEFAULT_SYMBOLS, -- editable in the panel, kept in the plugin data dir
        specialsRev = 0,
    }
end
local function newKey()
    return { format = "hex", length = 32, result = "", cmd = "", kind = "key" }
end
local function newHtp()
    return { user = "", pass = "", algo = "bcrypt", escape = true, result = "", rev = 0, kind = "htpasswd" }
end
local gen = newGen()
local key = newKey()
local jwt = { raw = "", rev = 0, view = nil }
local htp = newHtp()

local render

local function tr(k, subst)
    return noctalia.tr(k, subst)
end

local function fail(detail)
    noctalia.notifyError(tr("title"), detail or tr("err_generic"))
end

-- `kind` ("password" | "key" | "htpasswd") picks the notification text.
local function copySecret(text, kind)
    if text == "" then
        return
    end
    if noctalia.copyToClipboard(text, "text/plain") then
        noctalia.notify(tr("title"), tr(kind .. "_copied"))
    else
        fail(tr("err_copy"))
    end
end

-- Called with the freshly generated secret: show it, and copy it when the
-- copy_on_generate setting is on.
local function publish(target, text, extra)
    target.result = text
    if extra ~= nil then
        for k, v in pairs(extra) do
            target[k] = v
        end
    end
    if noctalia.getConfig("copy_on_generate") == true then
        copySecret(text, target.kind)
    end
    render()
end

-- Starts a request: returns its token, valid until the next request or close.
local function begin()
    nonce += 1
    return nonce
end

-- Asks /dev/urandom for `count` u32 values (-v: no `*` duplicate collapsing).
local function fetchRandom(count, cb)
    local token = begin()
    local started = noctalia.runAsync({ "od", "-An", "-tu4", "-v", "-N", tostring(count * 4), "/dev/urandom" }, function(r)
        if token ~= nonce then
            return
        end
        local nums = {}
        if r.exitCode == 0 then
            for n in r.stdout:gmatch("%d+") do
                nums[#nums + 1] = tonumber(n)
            end
        end
        if #nums < count then
            fail(tr("err_random"))
            return
        end
        cb(nums)
    end)
    if not started then
        fail(tr("err_random"))
    end
end

-- Uniform integer in [1, n] from the pool; errors if rejection sampling eats
-- the whole pool (about 1 in 10^8 per pick, caught by the pcall in callers).
local function makePicker(nums)
    local i = 0
    return function(n)
        local limit = TWO32 - (TWO32 % n)
        while i < #nums do
            i += 1
            if nums[i] < limit then
                return nums[i] % n + 1
            end
        end
        error("random pool exhausted")
    end
end

local function pickChar(set, pick)
    local i = pick(#set)
    return set:sub(i, i)
end

local ALNUM = LOWER .. UPPER .. DIGITS

-- `length` random alphanumerics, handed to cb; failures are reported here.
local function randomAlnum(length, cb)
    fetchRandom(length + 16, function(nums)
        local pick = makePicker(nums)
        local ok, text = pcall(function()
            local out = {}
            for i = 1, length do
                out[i] = pickChar(ALNUM, pick)
            end
            return table.concat(out)
        end)
        if not ok then
            fail(tr("err_random"))
            return
        end
        cb(text)
    end)
end

-- Non-secret UI state lives in the plugin data dir: special_chars.txt, last_tab.txt.
local function dataFile(name)
    local dir = noctalia.pluginDataDir()
    return dir ~= nil and dir .. "/" .. name or nil
end

-- Removes a request's pipe and forgets it as the one in flight.
local function dropFifo(path)
    noctalia.removeFile(path)
    if htpFifo == path then
        htpFifo = nil
    end
end

-- Pipes left behind by a crash are empty nodes; clear them when the panel opens.
local function sweepFifos()
    local dir = noctalia.pluginDataDir()
    local names = dir ~= nil and noctalia.listDir(dir) or nil
    for _, name in ipairs(names or {}) do
        if name:match("^htpasswd%-%d+%.fifo$") then
            noctalia.removeFile(dir .. "/" .. name)
        end
    end
end

local function saveSpecials()
    local path = dataFile("special_chars.txt")
    if path ~= nil then
        noctalia.writeFile(path, gen.specials)
    end
end

-- The special characters field, cleaned: printable ASCII only, no
-- letters/digits/space, duplicates dropped.
local function specialChars()
    local raw = gen.specials
    local seen, out = {}, {}
    for i = 1, #raw do
        local c = raw:sub(i, i)
        local b = c:byte()
        if b > 32 and b < 127 and not c:match("%w") and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

-- Character classes the Passgen toggles select, one string per class.
local function activeClasses()
    local classes = {}
    if gen.letters then
        if gen.case ~= "upper" then
            classes[#classes + 1] = LOWER
        end
        if gen.case ~= "lower" then
            classes[#classes + 1] = UPPER
        end
    end
    if gen.digits then
        classes[#classes + 1] = DIGITS
    end
    if gen.symbols then
        classes[#classes + 1] = specialChars()
    end
    return classes
end

-- One char from every class (so each enabled set is present), the rest from
-- the union, then a Fisher-Yates shuffle to hide the pattern.
local function buildRandom(classes, length, pick)
    local all = table.concat(classes)
    local out = {}
    for _, class in ipairs(classes) do
        out[#out + 1] = pickChar(class, pick)
    end
    while #out < length do
        out[#out + 1] = pickChar(all, pick)
    end
    for i = #out, 2, -1 do
        local j = pick(i)
        out[i], out[j] = out[j], out[i]
    end
    return table.concat(out), length * math.log(#all, 2)
end

local function buildPassphrase(pick)
    local parts = {}
    for i = 1, gen.words do
        local at = (pick(#words // WORD_RECORD) - 1) * WORD_RECORD
        local w = words:sub(at + 1, at + WORD_RECORD):match("^[%a%-]+")
        assert(w ~= nil, "bad wordlist record")
        if gen.capital then
            w = w:sub(1, 1):upper() .. w:sub(2)
        end
        parts[i] = w
    end
    local text = table.concat(parts, gen.sep)
    local bits = gen.words * math.log(#words // WORD_RECORD, 2)
    if gen.number then
        text = text .. gen.sep .. string.format("%02d", pick(100) - 1)
        bits += math.log(100, 2)
    end
    return text, bits
end

local function generatePassgen()
    if gen.mode == "memorable" then
        if words == nil then
            fail(tr("err_wordlist"))
            return
        end
        fetchRandom(gen.words * 2 + 8, function(nums)
            local ok, text, bits = pcall(buildPassphrase, makePicker(nums))
            if not ok then
                fail(tr("err_random"))
                return
            end
            publish(gen, text, { bits = bits })
        end)
        return
    end
    if gen.symbols and specialChars() == "" then
        fail(tr("err_no_symbols"))
        return
    end
    local classes = activeClasses()
    if #classes == 0 then
        fail(tr("err_no_class"))
        return
    end
    local length = gen.length
    fetchRandom(length * 2 + 16, function(nums)
        local ok, text, bits = pcall(buildRandom, classes, length, makePicker(nums))
        if not ok then
            fail(tr("err_random"))
            return
        end
        publish(gen, text, { bits = bits })
    end)
end

local function generateKeygen()
    local length = key.length
    if key.format == "alnum" then
        randomAlnum(length, function(text)
            publish(key, text, { cmd = "" })
        end)
        return
    end
    if not noctalia.commandExists("openssl") then
        fail(tr("err_missing", { command = "openssl" }))
        return
    end
    local flag = key.format == "hex" and "-hex" or "-base64"
    local token = begin()
    local started = noctalia.runAsync({ "openssl", "rand", flag, tostring(length) }, function(r)
        if token ~= nonce then
            return
        end
        if r.exitCode ~= 0 then
            fail(r.stderr ~= "" and r.stderr or nil)
            return
        end
        local text = r.stdout:gsub("%s", "") -- openssl wraps base64 at 64 columns
        if key.format == "base64url" then
            text = text:gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
        end
        publish(key, text, { cmd = "openssl rand " .. flag .. " " .. length })
    end)
    if not started then
        fail()
    end
end

local function generateHtpasswd()
    if htp.user == "" or htp.pass == "" then
        fail(tr("err_htpasswd_empty"))
        return
    end
    -- A leading "-" would be read as an option; ":" is not allowed by htpasswd.
    if htp.user:sub(1, 1) == "-" or htp.user:find(":", 1, true) then
        fail(tr("err_htpasswd_user"))
        return
    end
    for _, cmd in ipairs({ "htpasswd", "mkfifo" }) do
        if not noctalia.commandExists(cmd) then
            fail(tr("err_missing", { command = cmd }))
            return
        end
    end
    local token = begin()
    local fifo = dataFile("htpasswd-" .. token .. ".fifo")
    if fifo == nil then
        fail()
        return
    end
    htpFifo = fifo
    local user, pass = htp.user, htp.pass
    local flags = htp.algo == "bcrypt" and "-inB -C 10" or "-inm"
    -- The password reaches htpasswd on stdin through a named pipe: argv and
    -- /proc/<pid>/cmdline never hold it, and nothing but the pipe node is
    -- created on disk. Only the user name and the pipe path are passed as
    -- positional arguments of the fixed script.
    noctalia.removeFile(fifo)
    local made = noctalia.runAsync({ "mkfifo", "-m", "600", fifo }, function(m)
        -- A newer request or a close came first: writing now would create a
        -- regular file holding the password.
        if token ~= nonce then
            dropFifo(fifo)
            return
        end
        if m.exitCode ~= 0 then
            fail(m.stderr ~= "" and m.stderr or nil)
            return
        end
        local started = noctalia.runAsync(
            { "sh", "-c", 'exec htpasswd ' .. flags .. ' "$0" < "$1"', user, fifo },
            function(r)
                dropFifo(fifo)
                if token ~= nonce then
                    return
                end
                local line = r.stdout:gsub("%s+$", "")
                if r.exitCode ~= 0 or line == "" then
                    fail(r.stderr ~= "" and r.stderr or nil)
                    return
                end
                if htp.escape then
                    line = line:gsub("%$", "$$")
                end
                publish(htp, line)
            end
        )
        if not started or not noctalia.fileExists(fifo) then
            dropFifo(fifo)
            fail()
            return
        end
        -- Blocks until the shell opens the pipe for reading (a few ms).
        noctalia.writeFile(fifo, pass)
    end)
    if not made then
        fail()
    end
end

-- Fills the htpasswd password field with 24 random alphanumerics.
local function generateHtpasswdPassword()
    randomAlnum(24, function(text)
        htp.pass = text
        htp.rev += 1
        htp.result = ""
        render()
    end)
end

-- ── UI helpers ──────────────────────────────────────────────────────────────

-- Row of exclusive buttons; `options` is a list of { id, label }.
local function choiceRow(name, options, current, onPick)
    local buttons = {}
    for _, o in ipairs(options) do
        buttons[#buttons + 1] = ui.button({
            key = name .. "-" .. o.id,
            text = o.label,
            variant = current == o.id and "primary" or "secondary",
            controlSize = "sm",
            onClick = function()
                onPick(o.id)
            end,
        })
    end
    return ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = tr(name), width = 120, color = "on_surface_variant" }),
        ui.row({ gap = 6, flexGrow = 1 }, buttons),
    })
end

local function toggleRow(name, checked, onChange)
    return ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr(name), flexGrow = 1 }),
        ui.toggle({
            key = "tg-" .. name,
            checked = checked,
            onChange = function(value)
                onChange(value == "true")
            end,
        }),
    })
end

-- One row: name, slider, current value.
local function sliderRow(name, min, max, value, onChange)
    return ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = tr(name), width = 120, color = "on_surface_variant" }),
        ui.slider({
            key = "sl-" .. name,
            min = min,
            max = max,
            step = 1,
            value = value,
            flexGrow = 1,
            onChange = function(v)
                local n = tonumber(v)
                if n ~= nil then
                    onChange(math.floor(n))
                end
            end,
        }),
        ui.label({ text = tostring(value), width = 32, textAlign = "end" }),
    })
end

-- The generated secret is shown the same way on every tab. NBSP keeps the info
-- line's height before the first Generate, so the layout does not jump.
local NBSP = "\u{00A0}"
local RESULT_TITLE_SIZE = 22

local function resultBlock(text, info, onGenerate, onCopy)
    local has = text ~= ""
    return ui.column({ gap = 8 }, {
        ui.column({ gap = 6, fill = "surface", radius = 8, padding = 10 }, {
            ui.label({
                text = has and text or tr("empty_result"),
                fontSize = 20,
                fontFamily = "monospace",
                fontWeight = "medium",
                color = has and "on_surface" or "on_surface_variant",
                maxWidth = 500,
                maxLines = 5,
            }),
            ui.label({ text = info, fontSize = 11, color = "on_surface_variant" }),
        }),
        ui.row({ gap = 8 }, {
            ui.button({ text = tr("generate"), glyph = "refresh", variant = "primary", flexGrow = 1, onClick = onGenerate }),
            ui.button({ text = tr("copy"), glyph = "copy", variant = "secondary", enabled = has, onClick = onCopy }),
        }),
    })
end

-- A titled group of controls on a raised background.
local function section(title, glyph, children, titleSize)
    titleSize = titleSize or 17
    local rows = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = glyph, size = titleSize + 2, color = "primary" }),
            ui.label({ text = title, fontSize = titleSize, fontWeight = "bold", color = "primary" }),
        }),
    }
    for _, child in ipairs(children) do
        rows[#rows + 1] = child
    end
    return ui.column({ gap = 6, fill = "surface_container", radius = 10, padding = 10 }, rows)
end

-- ── Tabs ────────────────────────────────────────────────────────────────────

local function passgenTab()
    local typeRows = {
        choiceRow("mode", {
            { id = "random", label = tr("mode_random") },
            { id = "memorable", label = tr("mode_memorable") },
        }, gen.mode, function(id)
            gen.mode = id
            gen.result = ""
            render()
        end),
    }
    local contentRows = {}
    if gen.mode == "random" then
        typeRows[#typeRows + 1] = sliderRow("length", 8, 128, gen.length, function(n)
            gen.length = n
            render()
        end)
        contentRows[#contentRows + 1] = toggleRow("letters", gen.letters, function(v)
            gen.letters = v
            render()
        end)
        if gen.letters then
            contentRows[#contentRows + 1] = choiceRow("case", {
                { id = "lower", label = tr("case_lower") },
                { id = "upper", label = tr("case_upper") },
                { id = "mixed", label = tr("case_mixed") },
            }, gen.case, function(id)
                gen.case = id
                render()
            end)
        end
        contentRows[#contentRows + 1] = toggleRow("digits", gen.digits, function(v)
            gen.digits = v
            render()
        end)
        -- One row: label, the editable character list (only while on), reset, toggle.
        local symbolsRow = { ui.label({ text = tr("symbols"), flexGrow = gen.symbols and 0 or 1 }) }
        if gen.symbols then
            symbolsRow[#symbolsRow + 1] = ui.input({
                key = "specials-" .. gen.specialsRev,
                value = gen.specials,
                placeholder = tr("specials_placeholder"),
                controlSize = "sm",
                flexGrow = 1,
                onChange = function(v)
                    gen.specials = v
                    saveSpecials()
                end,
            })
            symbolsRow[#symbolsRow + 1] = ui.button({
                glyph = "restore",
                variant = "secondary",
                controlSize = "sm",
                tooltip = tr("tip_specials_reset"),
                onClick = function()
                    gen.specials = DEFAULT_SYMBOLS
                    gen.specialsRev += 1
                    saveSpecials()
                    render()
                end,
            })
        end
        symbolsRow[#symbolsRow + 1] = ui.toggle({
            key = "tg-symbols",
            checked = gen.symbols,
            onChange = function(value)
                gen.symbols = value == "true"
                render()
            end,
        })
        contentRows[#contentRows + 1] = ui.row({ gap = 8, align = "center" }, symbolsRow)
    else
        typeRows[#typeRows + 1] = sliderRow("word_count", 3, 10, gen.words, function(n)
            gen.words = n
            render()
        end)
        local seps = {}
        for _, s in ipairs(SEPARATORS) do
            seps[#seps + 1] = { id = s ~= "" and s or "none", label = s ~= "" and s or tr("sep_none") }
        end
        contentRows[#contentRows + 1] = choiceRow("separator", seps, gen.sep ~= "" and gen.sep or "none", function(id)
            gen.sep = id ~= "none" and id or ""
            render()
        end)
        contentRows[#contentRows + 1] = toggleRow("capital", gen.capital, function(v)
            gen.capital = v
            render()
        end)
        contentRows[#contentRows + 1] = toggleRow("add_number", gen.number, function(v)
            gen.number = v
            render()
        end)
    end
    local info = NBSP
    if gen.result ~= "" then
        info = tr("entropy", { bits = math.floor(gen.bits), length = utf8.len(gen.result) or #gen.result })
    end
    return {
        section(tr("section_type"), "adjustments-horizontal", typeRows),
        section(tr("section_contents"), "letter-case", contentRows),
        section(tr("section_password"), "password", {
            resultBlock(gen.result, info, generatePassgen, function()
                copySecret(gen.result, gen.kind)
            end),
        }, RESULT_TITLE_SIZE),
    }
end

local function keygenTab()
    local presets = {}
    for _, n in ipairs({ 16, 24, 32, 48, 64 }) do
        presets[#presets + 1] = ui.button({
            key = "preset-" .. n,
            text = tostring(n),
            variant = key.length == n and "primary" or "secondary",
            controlSize = "sm",
            onClick = function()
                key.length = n
                render()
            end,
        })
    end
    local unit = key.format == "alnum" and "length_chars" or "length_bytes"
    return {
        section(tr("section_options"), "adjustments-horizontal", {
            choiceRow("format", {
                { id = "hex", label = "hex" },
                { id = "base64", label = "base64" },
                { id = "base64url", label = "base64url" },
                { id = "alnum", label = tr("fmt_alnum") },
            }, key.format, function(id)
                key.format = id
                key.result = ""
                key.cmd = ""
                render()
            end),
            sliderRow(unit, 8, 128, key.length, function(n)
                key.length = n
                render()
            end),
            ui.row({ gap = 6, align = "center" }, {
                ui.label({ text = tr("presets"), width = 120, color = "on_surface_variant" }),
                ui.row({ gap = 6, flexGrow = 1 }, presets),
            }),
        }),
        section(tr("section_key"), "key", {
            resultBlock(key.result, key.cmd ~= "" and key.cmd or NBSP, generateKeygen, function()
                copySecret(key.result, key.kind)
            end),
        }, RESULT_TITLE_SIZE),
    }
end

local function htpasswdTab()
    return {
        section(tr("section_credentials"), "user", {
            ui.input({
                key = "htp-user-" .. htp.rev,
                value = htp.user,
                placeholder = tr("user_placeholder"),
                onChange = function(v)
                    htp.user = v
                end,
                onSubmit = function(v)
                    htp.user = v
                    generateHtpasswd()
                end,
            }),
            ui.row({ gap = 6, align = "center" }, {
                ui.input({
                    key = "htp-pass-" .. htp.rev,
                    value = htp.pass,
                    placeholder = tr("pass_placeholder"),
                    flexGrow = 1,
                    onChange = function(v)
                        htp.pass = v
                    end,
                    onSubmit = function(v)
                        htp.pass = v
                        generateHtpasswd()
                    end,
                }),
                ui.button({ glyph = "dice", variant = "secondary", tooltip = tr("tip_gen_pass"), onClick = generateHtpasswdPassword }),
            }),
        }),
        section(tr("section_options"), "adjustments-horizontal", {
            choiceRow("algorithm", {
                { id = "bcrypt", label = "bcrypt" },
                { id = "apr1", label = "apr1 (MD5)" },
            }, htp.algo, function(id)
                htp.algo = id
                htp.result = ""
                render()
            end),
            toggleRow("with_escape", htp.escape, function(v)
                htp.escape = v
                htp.result = ""
                render()
            end),
        }),
        section(tr("section_result"), "lock", {
            resultBlock(htp.result, htp.result ~= "" and (htp.escape and tr("escaped") or tr("plain")) or NBSP, generateHtpasswd, function()
                copySecret(htp.result, htp.kind)
            end),
        }, RESULT_TITLE_SIZE),
    }
end

-- ── JWT decoder ─────────────────────────────────────────────────────────────
-- Decode only: the signature is shown, never checked. The token is cut out of
-- whatever surrounds it (quotes, JSON, "Bearer ") before decoding.

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- base64url (padding optional) to bytes; nil on bad input.
local function b64urlDecode(text)
    local s = text:gsub("%-", "+"):gsub("_", "/"):gsub("=", "")
    if #s % 4 == 1 or s:find("[^%w%+/]") then
        return nil
    end
    local bits, nbits, out = 0, 0, {}
    for i = 1, #s do
        bits = bits * 64 + (B64:find(s:sub(i, i), 1, true) - 1)
        nbits += 6
        if nbits >= 8 then
            nbits -= 8
            local byte = math.floor(bits / 2 ^ nbits)
            bits = bits % 2 ^ nbits
            out[#out + 1] = string.char(byte)
        end
    end
    return table.concat(out)
end

local JWT_MAX_RAW = 20000 -- chars; pasted logs or files are refused, not scanned
local JWT_MAX_TOKEN = 12000

-- The first JWT-shaped run (header starts with "eyJ", i.e. `{"`), else the
-- first three dot-separated base64url runs.
local function extractToken(text)
    if #text > JWT_MAX_RAW then
        return nil
    end
    return text:match("eyJ[%w%-_]*%.[%w%-_]+%.[%w%-_]*") or text:match("[%w%-_]+%.[%w%-_]+%.[%w%-_]*")
end

-- Re-indents JSON text without reordering keys (decode/encode would).
local function prettyJson(text)
    local out, depth, inStr, esc, lastc = {}, 0, false, false, ""
    local function newline()
        out[#out + 1] = "\n" .. string.rep("  ", depth)
    end
    for i = 1, #text do
        local c = text:sub(i, i)
        if inStr then
            out[#out + 1] = c
            if esc then
                esc = false
            elseif c == "\\" then
                esc = true
            elseif c == '"' then
                inStr = false
                lastc = c
            end
        elseif c == '"' then
            inStr = true
            out[#out + 1] = c
        elseif c == "{" or c == "[" then
            out[#out + 1] = c
            local nxt = text:sub(i + 1):match("^%s*(.)")
            if nxt ~= "}" and nxt ~= "]" then
                depth += 1
                newline()
            end
            lastc = c
        elseif c == "}" or c == "]" then
            if lastc ~= "{" and lastc ~= "[" then
                depth -= 1
                newline()
            end
            out[#out + 1] = c
            lastc = c
        elseif c == "," then
            out[#out + 1] = c
            newline()
            lastc = c
        elseif c == ":" then
            out[#out + 1] = ": "
            lastc = c
        elseif not c:match("%s") then
            out[#out + 1] = c
            lastc = c
        end
    end
    return table.concat(out)
end

local function duration(seconds)
    seconds = math.abs(seconds)
    if seconds >= 86400 then
        return math.floor(seconds / 86400) .. "d " .. math.floor(seconds % 86400 / 3600) .. "h"
    elseif seconds >= 3600 then
        return math.floor(seconds / 3600) .. "h " .. math.floor(seconds % 3600 / 60) .. "m"
    end
    return math.floor(seconds / 60) .. "m " .. math.floor(seconds % 60) .. "s"
end

-- The validity headline ({ text, role }) from exp/nbf, and the time claims as
-- { name, date } pairs.
local function claimInfo(payload)
    local lines = {}
    local now = os.time()
    local status = { text = tr("jwt_no_exp"), role = "on_surface_variant" }
    local notYet = nil
    for _, name in ipairs({ "iat", "nbf", "exp" }) do
        local ts = type(payload) == "table" and payload[name] or nil
        if type(ts) == "number" then
            local ok, date = pcall(noctalia.formatTime, "%Y-%m-%d %H:%M:%S", ts)
            if ok then
                lines[#lines + 1] = { name = name, date = date }
                if name == "exp" then
                    if ts < now then
                        status = { text = tr("jwt_expired", { time = duration(now - ts) }), role = "error" }
                    else
                        status = { text = tr("jwt_valid", { time = duration(ts - now) }), role = "primary" }
                    end
                elseif name == "nbf" and ts > now then
                    notYet = tr("jwt_not_yet", { time = duration(ts - now) })
                end
            end
        end
    end
    if notYet ~= nil then
        status = { text = notYet, role = "error" }
    end
    return status, lines
end

local function clearJwt()
    jwt.raw, jwt.view = "", nil
    jwt.rev += 1
end

local function decodeJwt()
    jwt.view = nil
    if jwt.raw:match("^%s*$") then
        return
    end
    local token = extractToken(jwt.raw)
    if #jwt.raw > JWT_MAX_RAW or (token ~= nil and #token > JWT_MAX_TOKEN) then
        jwt.view = { err = tr("jwt_err_size") }
        return
    end
    if token == nil then
        jwt.view = { err = tr("jwt_err_format") }
        return
    end
    local h, p, sig = token:match("^([^.]+)%.([^.]+)%.(.*)$")
    local headerText, payloadText = b64urlDecode(h), b64urlDecode(p)
    local header = headerText ~= nil and noctalia.json.decode(headerText) or nil
    local payload = payloadText ~= nil and noctalia.json.decode(payloadText) or nil
    if header == nil or payload == nil then
        jwt.view = { err = tr("jwt_err_json") }
        return
    end
    local status, claims = claimInfo(payload)
    jwt.view = {
        header = prettyJson(headerText),
        payload = prettyJson(payloadText),
        status = status,
        claims = claims,
        sig = sig,
    }
end

local JSON_WIDTH = 460 -- px per line; labels in a row do not wrap, so long values are cut here
local MONO_EM = 0.6 -- monospace advance, in em

-- Splits a value into pieces of at most n characters (UTF-8 aware; a string
-- that is not valid UTF-8 is left whole).
local function chunkText(value, n)
    local len = utf8.len(value)
    if len == nil or len <= n then
        return { value }
    end
    local out, pos = {}, 1
    while pos <= #value do
        local nextPos = utf8.offset(value, n + 1, pos) or (#value + 1)
        out[#out + 1] = value:sub(pos, nextPos - 1)
        pos = nextPos
    end
    return out
end

-- One line of prettyJson output -> indent, key segments, value text, role, comma.
local function splitJsonLine(line)
    local indent = #line:match("^ *")
    local rest = line:sub(indent + 1)
    local head = {}
    if rest:sub(1, 1) == '"' then
        local i, esc = 2, false
        while i <= #rest do
            local c = rest:sub(i, i)
            if esc then
                esc = false
            elseif c == "\\" then
                esc = true
            elseif c == '"' then
                break
            end
            i += 1
        end
        if rest:sub(i + 1, i + 2) == ": " then
            head[#head + 1] = { rest:sub(1, i), "primary" }
            head[#head + 1] = { ": ", "on_surface_variant" }
            rest = rest:sub(i + 3)
        end
    end
    local comma = #rest > 1 and rest:sub(-1) == ","
    local value = comma and rest:sub(1, -2) or rest
    local first = value:sub(1, 1)
    local role = "secondary" -- numbers, true, false, null
    if first == '"' then
        role = "tertiary"
    elseif first == "{" or first == "[" or first == "}" or first == "]" then
        role = "on_surface_variant"
    end
    return indent, head, value, role, comma
end

-- Pretty JSON as colored rows: keys primary, strings tertiary, numbers and
-- literals secondary, punctuation muted.
local function jsonRows(text, size)
    local rows = {}
    local function addRow(indent, segs)
        local nodes = {}
        if indent > 0 then
            nodes[1] = ui.row({ width = indent * size * MONO_EM }, {})
        end
        for _, seg in ipairs(segs) do
            nodes[#nodes + 1] = ui.label({ text = seg[1], fontSize = size, fontFamily = "monospace", color = seg[2] })
        end
        rows[#rows + 1] = ui.row({ gap = 0 }, nodes)
    end
    local wrap = math.floor(JSON_WIDTH / (size * MONO_EM))
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local indent, head, value, role, comma = splitJsonLine(line)
        local headLen = 0
        for _, seg in ipairs(head) do
            headLen += #seg[1]
        end
        local chunks = chunkText(value, math.max(24, wrap - indent - headLen))
        for i, chunk in ipairs(chunks) do
            local segs = {}
            if i == 1 then
                for _, seg in ipairs(head) do
                    segs[#segs + 1] = seg
                end
            end
            segs[#segs + 1] = { chunk, role }
            if comma and i == #chunks then
                segs[#segs + 1] = { ",", "on_surface_variant" }
            end
            addRow(i == 1 and indent or indent + 2, segs)
        end
    end
    return rows
end

local function jwtJsonSection(title, glyph, text, size)
    return section(title, glyph, jsonRows(text, size), 15)
end

local function jwtTextSection(title, glyph, text)
    return section(title, glyph, {
        ui.label({ text = text ~= "" and text or "-", fontSize = 11, color = "on_surface", maxWidth = 500 }),
    }, 15)
end

-- Validity headline plus the time claims in one row (name over date), shown
-- above the decoded JSON.
local function jwtStatusBox(view)
    local children = { ui.label({ text = view.status.text, fontSize = 16, fontWeight = "bold", color = view.status.role }) }
    local cols = {}
    for _, claim in ipairs(view.claims) do
        cols[#cols + 1] = ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = claim.name, fontSize = 10, color = "on_surface_variant" }),
            ui.label({ text = claim.date, fontSize = 12, color = "on_surface" }),
        })
    end
    if #cols > 0 then
        children[#children + 1] = ui.row({ gap = 8 }, cols)
    end
    return ui.column({ gap = 4, fill = "surface_container", radius = 10, padding = 10, border = view.status.role, borderWidth = 1 }, children)
end

-- The decoded token as one JSON document: { "header": {...}, "payload": {...} }.
local function decodedJson(view)
    local function indentBlock(text)
        return (text:gsub("\n", "\n  "))
    end
    return '{\n  "header": ' .. indentBlock(view.header) .. ',\n  "payload": ' .. indentBlock(view.payload) .. "\n}"
end

local function jwtTab()
    local tokenRows = {
        ui.input({
            key = "jwt-" .. jwt.rev,
            value = jwt.raw,
            multiline = true,
            fontSize = 10,
            height = 90,
            placeholder = tr("jwt_placeholder"),
            onChange = function(v)
                jwt.raw = v
                decodeJwt()
                render()
            end,
        }),
        ui.row({ gap = 6 }, {
            ui.button({
                text = tr("jwt_paste"),
                glyph = "clipboard",
                variant = "secondary",
                flexGrow = 1,
                onClick = function()
                    local text = noctalia.clipboardText()
                    if text == nil or text == "" then
                        fail(tr("jwt_err_clipboard"))
                        return
                    end
                    jwt.raw = text
                    jwt.rev += 1
                    decodeJwt()
                    render()
                end,
            }),
            ui.button({
                text = tr("jwt_trim"),
                glyph = "scissors",
                variant = "secondary",
                flexGrow = 1,
                tooltip = tr("tip_jwt_trim"),
                onClick = function()
                    local token = extractToken(jwt.raw)
                    if token == nil or #token > JWT_MAX_TOKEN then
                        fail(tr(#jwt.raw > JWT_MAX_RAW and "jwt_err_size" or "jwt_err_format"))
                        return
                    end
                    jwt.raw = token
                    jwt.rev += 1
                    decodeJwt()
                    render()
                end,
            }),
            ui.button({
                text = tr("copy"),
                glyph = "copy",
                variant = "secondary",
                flexGrow = 1,
                tooltip = tr("tip_jwt_copy"),
                enabled = jwt.view ~= nil and jwt.view.err == nil,
                onClick = function()
                    copySecret(decodedJson(jwt.view), "jwt")
                end,
            }),
            ui.button({
                glyph = "eraser",
                variant = "secondary",
                tooltip = tr("jwt_clear"),
                onClick = function()
                    clearJwt()
                    render()
                end,
            }),
        }),
    }
    local rows = { section(tr("section_token"), "clipboard-text", tokenRows) }
    local view = jwt.view
    if view ~= nil and view.err ~= nil then
        rows[#rows + 1] = ui.label({ text = view.err, color = "error" })
    elseif view ~= nil then
        rows[#rows + 1] = jwtStatusBox(view)
        rows[#rows + 1] = jwtJsonSection(tr("jwt_header"), "file-code", view.header, 10)
        rows[#rows + 1] = jwtJsonSection(tr("jwt_payload"), "braces", view.payload, 12)
        rows[#rows + 1] = jwtTextSection(tr("jwt_signature"), "signature", view.sig)
    end
    return rows
end

local function saveTab()
    local path = dataFile("last_tab.txt")
    if path ~= nil then
        noctalia.writeFile(path, tab)
    end
end

local TABS = {
    { id = "passgen", glyph = "password", build = passgenTab },
    { id = "keygen", glyph = "key", build = keygenTab },
    { id = "jwt", glyph = "braces", build = jwtTab },
    { id = "htpasswd", glyph = "lock", build = htpasswdTab },
}

-- Footer button: puts the options of the open tab back to their defaults.
local function resetTab()
    nonce += 1
    if tab == "passgen" then
        local rev = gen.specialsRev
        gen = newGen()
        gen.specialsRev = rev + 1
        saveSpecials()
    elseif tab == "keygen" then
        key = newKey()
    elseif tab == "htpasswd" then
        local rev = htp.rev
        htp = newHtp()
        htp.rev = rev + 1
    else
        clearJwt()
    end
    render()
end

render = function()
    local tabButtons = {}
    local bodies = {}
    for _, t in ipairs(TABS) do
        tabButtons[#tabButtons + 1] = ui.button({
            key = "tab-" .. t.id,
            text = tr("tab_" .. t.id),
            glyph = t.glyph,
            variant = tab == t.id and "primary" or "ghost",
            flexGrow = 1,
            onClick = function()
                tab = t.id
                saveTab()
                render()
            end,
        })
        -- Every tab stays in the tree and the inactive ones are hidden: nodes that are
        -- destroyed and created again replay their entry animation (toggles slide on).
        bodies[#bodies + 1] = ui.scroll({ key = "body-" .. t.id, flexGrow = 1, gap = 8, visible = tab == t.id }, t.build())
    end
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
            ui.button({ glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = function() noctalia.openSettings() end }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = function() panel.close() end }),
        }),
        ui.row({ gap = 6 }, tabButtons),
    }
    for _, body in ipairs(bodies) do
        children[#children + 1] = body
    end
    children[#children + 1] = ui.row({ gap = 6 }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("reset"), glyph = "restore", variant = "ghost", tooltip = tr("tip_reset"), onClick = resetTab }),
    })
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
end

-- Loads the EFF wordlist once; only the Memorable mode needs it.
local function loadWordlist()
    if words ~= nil then
        return
    end
    local dir = noctalia.pluginDir()
    if dir == nil then
        return
    end
    noctalia.readFileAsync(dir .. "/wordlist.txt", function(data)
        if data ~= nil and #data > 0 and #data % WORD_RECORD == 0 then
            words = data
        end
    end)
end

-- start_tab setting: "last" reopens the tab used last (last_tab.txt), anything
-- else is a fixed tab id.
local function startTab()
    local valid = {}
    for _, t in ipairs(TABS) do
        valid[t.id] = true
    end
    local mode = noctalia.getConfig("start_tab")
    if type(mode) == "string" and valid[mode] then
        return mode
    end
    local path = dataFile("last_tab.txt")
    local saved = path ~= nil and noctalia.readFile(path) or nil
    saved = saved ~= nil and (saved:gsub("%s", "")) or nil
    return (saved ~= nil and valid[saved]) and saved or "passgen"
end

function onOpen(_context)
    tab = startTab()
    loadWordlist()
    sweepFifos()
    local path = dataFile("special_chars.txt")
    local saved = path ~= nil and noctalia.readFile(path) or nil
    if saved ~= nil then
        gen.specials = saved
        gen.specialsRev += 1
    end
    noctalia.state.set("keysmith_open", true)
    render()
end

-- Wipe every secret and drop any in-flight request.
function onClose()
    nonce += 1
    gen.result, gen.bits = "", 0
    key.result, key.cmd = "", ""
    htp.user, htp.pass, htp.result = "", "", ""
    clearJwt()
    htp.rev += 1
    if htpFifo ~= nil then
        dropFifo(htpFifo)
    end
    noctalia.state.set("keysmith_open", false)
end
