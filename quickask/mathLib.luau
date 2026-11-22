--!nonstrict
-- Minimal LaTeX -> Unicode converter for QuickAsk.
--
-- Converts common math notation inside $...$, $$...$$, \(...\) and \[...\]
-- delimiters into Unicode characters so answers stay readable in a plain
-- Markdown view. Anything unrecognised is left exactly as written, so a
-- malformed or exotic expression degrades to raw LaTeX instead of breaking
-- the answer.

local mathLib = {}

-- LaTeX command -> Unicode replacement.
local COMMANDS = {
    -- Greek, lowercase
    alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ε",
    varepsilon = "ε", zeta = "ζ", eta = "η", theta = "θ", vartheta = "ϑ",
    iota = "ι", kappa = "κ", lambda = "λ", mu = "μ", nu = "ν", xi = "ξ",
    pi = "π", rho = "ρ", sigma = "σ", tau = "τ", upsilon = "υ", phi = "φ",
    varphi = "φ", chi = "χ", psi = "ψ", omega = "ω",
    -- Greek, uppercase
    Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ",
    Pi = "Π", Sigma = "Σ", Phi = "Φ", Psi = "Ψ", Omega = "Ω",
    -- Operators and relations
    infty = "∞", partial = "∂", nabla = "∇", int = "∫", iint = "∬",
    iiint = "∭", oint = "∮", sum = "∑", prod = "∏", coprod = "∐",
    pm = "±", mp = "∓", cdot = "·", times = "×", div = "÷", ast = "∗",
    leq = "≤", le = "≤", geq = "≥", ge = "≥", neq = "≠", ne = "≠",
    approx = "≈", equiv = "≡", sim = "∼", simeq = "≃", propto = "∝",
    ll = "≪", gg = "≫", subset = "⊂", supset = "⊃", subseteq = "⊆",
    supseteq = "⊇", cup = "∪", cap = "∩", setminus = "∖", emptyset = "∅",
    ["in"] = "∈", notin = "∉", forall = "∀", exists = "∃", nexists = "∄",
    neg = "¬", land = "∧", lor = "∨", therefore = "∴", because = "∵",
    -- Arrows
    to = "→", rightarrow = "→", Rightarrow = "⇒", leftarrow = "←",
    Leftarrow = "⇐", leftrightarrow = "↔", Leftrightarrow = "⇔",
    mapsto = "↦", uparrow = "↑", downarrow = "↓",
    -- Delimiters and misc
    langle = "⟨", rangle = "⟩", lfloor = "⌊", rfloor = "⌋",
    lceil = "⌈", rceil = "⌉", cdots = "⋯", ldots = "…", dots = "…",
    prime = "′", degree = "°", angle = "∠", perp = "⊥", parallel = "∥",
    -- Named operators: keep the name, drop the backslash
    sin = "sin", cos = "cos", tan = "tan", cot = "cot", sec = "sec",
    csc = "csc", arcsin = "arcsin", arccos = "arccos", arctan = "arctan",
    sinh = "sinh", cosh = "cosh", tanh = "tanh",
    log = "log", ln = "ln", exp = "exp", lim = "lim", sup = "sup", inf = "inf",
    max = "max", min = "min", det = "det", gcd = "gcd", mod = "mod",
    -- Blackboard bold spelled out, since \mathbb{R} needs brace handling
    mathbbR = "ℝ", mathbbN = "ℕ", mathbbZ = "ℤ", mathbbQ = "ℚ", mathbbC = "ℂ",
    -- Further relations and operators
    nleq = "≰", ngeq = "≱", nless = "≮", ngtr = "≯", prec = "≺", succ = "≻",
    mid = "∣", nmid = "∤", lvert = "|", rvert = "|", vert = "|", Vert = "‖",
    lbrace = "{", rbrace = "}", lbrack = "[", rbrack = "]",
    otimes = "⊗", oplus = "⊕", ominus = "⊖", odot = "⊙", oslash = "⊘",
    bigcirc = "○", bullet = "•", star = "⋆", dagger = "†", ddagger = "‡",
    aleph = "ℵ", hbar = "ℏ", ell = "ℓ", wp = "℘", Re = "ℜ", Im = "ℑ",
    surd = "√", checkmark = "✓", Box = "□", square = "□", triangle = "△",
    asymp = "≍", doteq = "≐", models = "⊨", vdash = "⊢", dashv = "⊣",
    top = "⊤", bot = "⊥", upmodels = "⊨", sqcup = "⊔", sqcap = "⊓",
    uplus = "⊎", amalg = "⨿", wr = "≀", diamond = "⋄", bigtriangleup = "△",
    coloneqq = "≔", eqqcolon = "≕", longrightarrow = "⟶", longleftarrow = "⟵",
    Longrightarrow = "⟹", Longleftarrow = "⟸", longmapsto = "⟼",
    hookrightarrow = "↪", hookleftarrow = "↩", nrightarrow = "↛", nleftarrow = "↚",
    nearrow = "↗", searrow = "↘", swarrow = "↙", nwarrow = "↖",
    rightleftharpoons = "⇌", leftrightharpoons = "⇋", leadsto = "⇝",
    vdots = "⋮", ddots = "⋱", dotsb = "⋯", dotsm = "⋯", dotsc = "…",
    therefore = "∴", because = "∵", eqcolon = "∹",
}

-- Layout commands carry no glyphs: drop them entirely.
local DISCARD = {
    "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle",
    "limits", "nolimits", "notag", "nonumber", "mathstrut", "strut",
    "hfill", "vfill", "hfil", "vfil", "centering", "noindent",
    "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
    "biggl", "biggr", "Biggl", "Biggr", "bigm", "Bigm",
    "left", "right", "middle", "enspace", "thinspace", "negthinspace",
    "allowbreak", "nobreak", "smallskip", "medskip", "bigskip",
}

-- Combining accents: base character then the mark.
local ACCENTS = {
    hat = "\204\130", dot = "\204\135", ddot = "\204\136",
    tilde = "\204\131", widetilde = "\204\131", bar = "\204\133",
    overline = "\204\133", underline = "\204\178", vec = "\226\131\151",
    check = "\204\140", breve = "\204\134", acute = "\204\129",
    grave = "\204\128", mathring = "\204\138",
}

-- Replace longest names first so \le is never matched inside \leq.
local ORDER = {}
for name in pairs(COMMANDS) do ORDER[#ORDER + 1] = name end
table.sort(ORDER, function(a, b)
    if #a ~= #b then return #a > #b end
    return a < b
end)

local SUPERSCRIPT = {
    ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴",
    ["5"] = "⁵", ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹",
    ["+"] = "⁺", ["-"] = "⁻", ["="] = "⁼", ["("] = "⁽", [")"] = "⁾",
    ["n"] = "ⁿ", ["i"] = "ⁱ", ["a"] = "ᵃ", ["b"] = "ᵇ", ["c"] = "ᶜ",
    ["d"] = "ᵈ", ["e"] = "ᵉ", ["f"] = "ᶠ", ["g"] = "ᵍ", ["h"] = "ʰ",
    ["k"] = "ᵏ", ["l"] = "ˡ", ["m"] = "ᵐ", ["o"] = "ᵒ", ["p"] = "ᵖ",
    ["r"] = "ʳ", ["s"] = "ˢ", ["t"] = "ᵗ", ["u"] = "ᵘ", ["v"] = "ᵛ",
    ["w"] = "ʷ", ["x"] = "ˣ", ["y"] = "ʸ", ["z"] = "ᶻ",
}

local SUBSCRIPT = {
    ["0"] = "₀", ["1"] = "₁", ["2"] = "₂", ["3"] = "₃", ["4"] = "₄",
    ["5"] = "₅", ["6"] = "₆", ["7"] = "₇", ["8"] = "₈", ["9"] = "₉",
    ["+"] = "₊", ["-"] = "₋", ["="] = "₌", ["("] = "₍", [")"] = "₎",
    ["a"] = "ₐ", ["e"] = "ₑ", ["h"] = "ₕ", ["i"] = "ᵢ", ["j"] = "ⱼ",
    ["k"] = "ₖ", ["l"] = "ₗ", ["m"] = "ₘ", ["n"] = "ₙ", ["o"] = "ₒ",
    ["p"] = "ₚ", ["s"] = "ₛ", ["t"] = "ₜ", ["x"] = "ₓ",
}

-- Translate one character at a time, iterating by codepoint so multi-byte
-- characters (π, √, …) pass through untouched instead of being split.
local function translate(mapTable, text)
    local out = {}
    for _, codepoint in utf8.codes(text) do
        local char = utf8.char(codepoint)
        out[#out + 1] = mapTable[char] or char
    end
    return table.concat(out)
end

-- \text{...}, \mathrm{...}, \operatorname{...}: keep the content.
-- Note: Lua patterns have no alternation, so each name is handled separately.
local TEXT_COMMANDS = {
    "text", "textrm", "textbf", "textit", "texttt", "textsf",
    "mathrm", "mathbf", "mathit", "mathtt", "mathsf", "mathcal", "mathfrak",
    "boldsymbol", "operatorname", "operatorname*",
}
local function unwrapTextCommands(s)
    for _, name in ipairs(TEXT_COMMANDS) do
        for _ = 1, 4 do
            local before = s
            s = s:gsub("\\" .. name .. "%s*{([^{}]*)}", function(inner)
                return inner
            end)
            if s == before then break end
        end
    end
    return s
end

-- \begin{matrix} / \end{matrix} and friends: drop the wrappers, keep the body.
local function unwrapEnvironments(s)
    s = s:gsub("\\begin%s*{[^{}]*}", "")
    s = s:gsub("\\end%s*{[^{}]*}", "")
    return s
end

-- Position of the brace that closes the group starting at openPos, or nil.
local function closingBrace(s, openPos)
    if s:sub(openPos, openPos) ~= "{" then return nil end
    local depth = 0
    for i = openPos, #s do
        local ch = s:sub(i, i)
        if ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then return i end
        end
    end
    return nil
end

-- Skip whitespace forward from position p.
local function skipSpace(s, p)
    while p <= #s and s:sub(p, p):match("%s") do p = p + 1 end
    return p
end

-- Expand every \frac{...}{...} whose arguments may themselves contain braces
-- (nested \frac, ^{...}, _{\cdot}, \sqrt{...}). Outermost first; the caller
-- loops so newly exposed inner constructs are handled next pass.
local function collapseFractions(s)
    local out, i = {}, 1
    while true do
        local found = s:find("\\frac", i, true)
        if not found then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, found - 1)

        local numOpen = skipSpace(s, found + 5)
        local numEnd = closingBrace(s, numOpen)
        local denOpen = numEnd and skipSpace(s, numEnd + 1) or nil
        local denEnd = denOpen and closingBrace(s, denOpen) or nil

        if not denEnd then
            -- Not a well-formed fraction: emit the token and keep scanning.
            out[#out + 1] = s:sub(found, found + 4)
            i = found + 5
        else
            local num = s:sub(numOpen + 1, numEnd - 1)
            local den = s:sub(denOpen + 1, denEnd - 1)
            if num == "" or den == "" then
                out[#out + 1] = s:sub(found, found + 4)
                i = found + 5
            else
                local simple = num:match("^[%w%.]+$") and den:match("^[%w%.]+$")
                if simple then
                    out[#out + 1] = num .. "/" .. den
                else
                    out[#out + 1] = "(" .. num .. "/" .. den .. ")"
                end
                i = denEnd + 1
            end
        end
    end
    return table.concat(out)
end

-- \sqrt{...} -> √(...), with the same brace handling as fractions.
local function collapseRoots(s)
    local out, i = {}, 1
    while true do
        local found = s:find("\\sqrt", i, true)
        if not found then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, found - 1)

        local open = skipSpace(s, found + 5)
        local close = closingBrace(s, open)

        if not close then
            out[#out + 1] = s:sub(found, found + 4)
            i = found + 5
        else
            local inner = s:sub(open + 1, close - 1)
            if inner == "" then
                out[#out + 1] = s:sub(found, found + 4)
                i = found + 5
            else
                out[#out + 1] = "√(" .. inner .. ")"
                i = close + 1
            end
        end
    end
    return table.concat(out)
end

-- ^{...} -> superscript, then a bare ^x -> superscript.
local function collapseSuperscripts(s)
    s = s:gsub("%^%s*{([^{}]*)}", function(inner)
        return translate(SUPERSCRIPT, inner)
    end)
    s = s:gsub("%^([%w])", function(char)
        return SUPERSCRIPT[char] or char
    end)
    return s
end

-- _{...} -> subscript, then a bare _x -> subscript.
local function collapseSubscripts(s)
    s = s:gsub("_%s*{([^{}]*)}", function(inner)
        return translate(SUBSCRIPT, inner)
    end)
    s = s:gsub("_([%w])", function(char)
        return SUBSCRIPT[char] or char
    end)
    return s
end

-- Leftover grouping braces with no commands inside: {abc} -> abc.
local function dropGroupingBraces(s)
    for _ = 1, 4 do
        local before = s
        s = s:gsub("{([^{}\\]+)}", function(inner) return inner end)
        if s == before then break end
    end
    return s
end

-- Convert a single math expression. Never raises on ordinary input, and
-- unrecognised constructs survive verbatim.
function mathLib.convert(source)
    if type(source) ~= "string" or source == "" then return source end

    local s = source

    s = unwrapEnvironments(s)
    s = unwrapTextCommands(s)
    s = s:gsub("\\mathbb%s*{([^{}]*)}", function(inner)
        return COMMANDS["mathbb" .. inner] or ("\\mathbb{" .. inner .. "}")
    end)
    -- Row and alignment separators left over from unwrapped environments.
    -- Handled before spacing removal, which would otherwise eat one of the
    -- two backslashes in \\.
    s = s:gsub("\\\\", " ; ")
    s = s:gsub("&", ", ")
    s = s:gsub(",%s+", ", ")
    s = s:gsub(" ;%s+", " ; ")
    s = s:gsub(" ,", ",")
    s = s:gsub(" ;", ";")

    s = s:gsub("\\[,;:! ]", "")
    s = s:gsub("\\quad%f[^%a]", " ")
    s = s:gsub("\\qquad%f[^%a]", "  ")
    -- Layout and spacing commands carry no glyph: drop them.
    for _, name in ipairs(DISCARD) do
        s = s:gsub("\\" .. name .. "%f[^%a]", "")
    end

    -- \boxed{x} -> [ x ], which reads as a framed result.
    for _ = 1, 4 do
        local before = s
        s = s:gsub("\\boxed%s*{([^{}]*)}", function(inner)
            if inner == "" then return inner end
            return "[ " .. inner .. " ]"
        end)
        if s == before then break end
    end

    -- \binom{n}{k} -> C(n,k)
    for _ = 1, 4 do
        local before = s
        s = s:gsub("\\binom%s*{([^{}]*)}{([^{}]*)}", function(n, k)
            if n == "" or k == "" then return nil end
            return "C(" .. n .. "," .. k .. ")"
        end)
        if s == before then break end
    end

    -- Colour and styling that only matter for rendering: keep the content.
    s = s:gsub("\\textcolor%s*{[^{}]*}", "")
    s = s:gsub("\\color%s*{[^{}]*}", "")
    s = s:gsub("\\colorbox%s*{[^{}]*}", "")
    s = s:gsub("\\fcolorbox%s*{[^{}]*}%s*{[^{}]*}", "")
    s = s:gsub("\\hspace%s*%*?%s*{[^{}]*}", " ")
    s = s:gsub("\\vspace%s*%*?%s*{[^{}]*}", "")

    -- Combining accents: \hat{x} -> x with a combining circumflex.
    for name, mark in pairs(ACCENTS) do
        for _ = 1, 4 do
            local before = s
            s = s:gsub("\\" .. name .. "%s*{([^{}]*)}", function(inner)
                if inner == "" then return nil end
                return inner .. mark
            end)
            if s == before then break end
        end
    end

    for _, name in ipairs(ORDER) do
        local replacement = COMMANDS[name]
        s = s:gsub("\\" .. name .. "%f[^%a]", function() return replacement end)
    end

    -- Innermost-first: a nested \sqrt inside \frac only becomes collapsible
    -- once the inner construct has been rewritten, so interleave the passes.
    for _ = 1, 8 do
        local before = s
        s = collapseRoots(s)
        s = collapseFractions(s)
        s = collapseSuperscripts(s)
        s = collapseSubscripts(s)
        if s == before then break end
    end

    -- Generic fallback: any command still standing is unknown, so keep its
    -- argument (or its bare name) rather than leaking a backslash.
    s = s:gsub("\\(%a+)%s*{([^{}]*)}", function(_, inner)
        return inner
    end)
    s = s:gsub("\\(%a+)", function(name)
        return name
    end)

    s = dropGroupingBraces(s)

    return s
end

-- Does this line look like bare LaTeX rather than ordinary prose?
--
-- Models often answer with "x^2 + y^2 = r^2" or "\frac{a}{b}" and no
-- delimiters. Converting everything would mangle snake_case identifiers and
-- stray carets, so a line is only treated as math when it carries at least
-- two independent math signals.
local function looksLikeMath(line)
    -- Filenames and paths such as img_2.png or notes_2024.md are identifiers,
    -- never math, even though they carry subscript-looking digits.
    if line:find("%a+_%d+%.%a") then return false end

    local score = 0

    -- Any \command is LaTeX-specific: it does not appear in plain text.
    local _, commands = line:gsub("\\%a+", "")
    score = score + commands * 2
    if score >= 2 then return true end

    -- x^2, x^{...}, x^n
    local _, carets = line:gsub("%^[{%d%a]", "")
    score = score + carets * 2
    if score >= 2 then return true end

    -- A braced or numeric subscript is math; "_letter" is usually an
    -- identifier such as some_variable, so it does not count.
    local _, braced = line:gsub("_[{]", "")
    score = score + braced * 2
    if score >= 2 then return true end

    local _, numeric = line:gsub("_%d", "")
    score = score + numeric
    return score >= 2
end

-- Convert one delimited math expression. Returns nil when the converter
-- fails, so the caller can keep the original text.
local function convertMath(inner)
    local ok, out = pcall(mathLib.convert, inner)
    if ok and type(out) == "string" then return out end
    return nil
end


-- Strip one balanced pair of surrounding parentheses.
-- Convert a stretch of prose: the explicitly delimited spans, then any line
-- that reads as bare LaTeX.
local function convertProse(text)
    if text == "" then return text end

    local s = text

    s = s:gsub("%$%$(.-)%$%$", function(inner)
        local out = convertMath(inner)
        return out and out or ("$$" .. inner .. "$$")
    end)
    s = s:gsub("\\%[(.-)\\%]", function(inner)
        local out = convertMath(inner)
        return out and out or ("\\[" .. inner .. "\\]")
    end)
    s = s:gsub("%$(.-)%$", function(inner)
        local out = convertMath(inner)
        return out and out or ("$" .. inner .. "$")
    end)
    s = s:gsub("\\%((.-)\\%)", function(inner)
        local out = convertMath(inner)
        return out and out or ("\\(" .. inner .. "\\)")
    end)

    -- Bare math, decided per line so one math-y line does not drag the whole
    -- answer through the converter. Replacing [^\n]+ keeps every newline.
    s = s:gsub("([^\n]+)", function(line)
        if looksLikeMath(line) then
            local out = convertMath(line)
            if out then return out end
        end
        return line
    end)

    return s
end

-- Rewrite math inside plain prose, skipping fenced blocks and inline code so
-- examples are never corrupted.
-- examples are never corrupted.
function mathLib.render(markdown)
    if type(markdown) ~= "string" or markdown == "" then return markdown end

    -- Protect escaped dollars so "\$5" is not read as a delimiter.
    local s = markdown:gsub("\\%$", "\1")

    local out = {}
    local position = 1
    local length = #s
    local inInlineCode = false

    while position <= length do
        local fenceStart = s:find("```", position, true)
        local tickStart = s:find("`", position, true)

        -- Inline code outranks a fence only when it starts first.
        if tickStart and (not fenceStart or tickStart < fenceStart) and (fenceStart == nil or tickStart ~= fenceStart) then
            local before = s:sub(position, tickStart - 1)
            out[#out + 1] = inInlineCode and before or convertProse(before)
            out[#out + 1] = "`"
            inInlineCode = not inInlineCode
            position = tickStart + 1
        elseif fenceStart then
            local before = s:sub(position, fenceStart - 1)
            out[#out + 1] = inInlineCode and before or convertProse(before)

            local fenceEnd = s:find("```", fenceStart + 3, true)
            if not fenceEnd then
                out[#out + 1] = s:sub(fenceStart) -- unterminated fence
                position = length + 1
            else
                out[#out + 1] = s:sub(fenceStart, fenceEnd + 2)
                position = fenceEnd + 3
            end
            inInlineCode = false
        else
            local rest = s:sub(position)
            out[#out + 1] = inInlineCode and rest or convertProse(rest)
            position = length + 1
        end
    end

    return (table.concat(out):gsub("\1", "$"))
end

return mathLib
