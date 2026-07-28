--!nonstrict

local DEG = math.pi / 180

local WIDE_OPERATORS = {
	["\u{00d7}"] = "*",
	["\u{00f7}"] = "/",
	["\u{2212}"] = "-",
	["\u{2013}"] = "-",
	["\u{00b7}"] = "*",
}

local CONSTANTS = {
	pi = math.pi,
	tau = math.pi * 2,
	e = math.exp(1),
}

local ARITY = {
	atan2 = 2,
	mod = 2,
	pow = 2,
	hypot = 2,
}

local function sinh(x)
	return (math.exp(x) - math.exp(-x)) / 2
end

local function cosh(x)
	return (math.exp(x) + math.exp(-x)) / 2
end

local function tanh(x)
	if x > 20 then
		return 1
	end
	if x < -20 then
		return -1
	end
	local a, b = math.exp(x), math.exp(-x)
	return (a - b) / (a + b)
end

local function isDigit(c)
	return c >= "0" and c <= "9"
end

local function isAlpha(c)
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end

local function tokenize(src)
	local tokens = {}
	local i = 1
	local n = #src

	while i <= n do
		local wide = WIDE_OPERATORS[src:sub(i, i + 1)] or WIDE_OPERATORS[src:sub(i, i + 2)]
		if wide ~= nil then
			table.insert(tokens, { kind = "op", text = wide })
			i += WIDE_OPERATORS[src:sub(i, i + 1)] ~= nil and 2 or 3
			continue
		end

		local c = src:sub(i, i)

		if c == " " or c == "\t" then
			i += 1
		elseif isDigit(c) or (c == "." and isDigit(src:sub(i + 1, i + 1))) then
			local start = i
			while i <= n and isDigit(src:sub(i, i)) do
				i += 1
			end
			if src:sub(i, i) == "." then
				i += 1
				while i <= n and isDigit(src:sub(i, i)) do
					i += 1
				end
			end
			local mark = i
			if src:sub(i, i):lower() == "e" then
				local j = i + 1
				local sign = src:sub(j, j)
				if sign == "+" or sign == "-" then
					j += 1
				end
				if isDigit(src:sub(j, j)) then
					i = j
					while i <= n and isDigit(src:sub(i, i)) do
						i += 1
					end
				else
					i = mark
				end
			end
			local value = tonumber(src:sub(start, i - 1))
			if value == nil then
				return nil
			end
			table.insert(tokens, { kind = "num", value = value })
		elseif isAlpha(c) then
			local start = i
			while i <= n and (isAlpha(src:sub(i, i)) or isDigit(src:sub(i, i))) do
				i += 1
			end
			table.insert(tokens, { kind = "name", text = src:sub(start, i - 1):lower() })
		elseif c == "(" or c == ")" then
			table.insert(tokens, { kind = c })
			i += 1
		elseif c == "," or c == ";" then
			table.insert(tokens, { kind = "," })
			i += 1
		elseif c == "+" or c == "-" or c == "*" or c == "/" or c == "^" or c == "%" then
			table.insert(tokens, { kind = "op", text = c })
			i += 1
		else
			return nil
		end
	end

	return tokens
end

local function makeFunctions(degrees)
	local toAngle = degrees and function(x)
		return x * DEG
	end or function(x)
		return x
	end

	local fromAngle = degrees and function(x)
		return x / DEG
	end or function(x)
		return x
	end

	return {
		sin = function(a)
			return math.sin(toAngle(a[1]))
		end,
		cos = function(a)
			return math.cos(toAngle(a[1]))
		end,
		tan = function(a)
			return math.tan(toAngle(a[1]))
		end,
		asin = function(a)
			return fromAngle(math.asin(a[1]))
		end,
		acos = function(a)
			return fromAngle(math.acos(a[1]))
		end,
		atan = function(a)
			if #a >= 2 then
				return fromAngle(math.atan2(a[1], a[2]))
			end
			return fromAngle(math.atan(a[1]))
		end,
		atan2 = function(a)
			return fromAngle(math.atan2(a[1], a[2]))
		end,
		sinh = function(a)
			return sinh(a[1])
		end,
		cosh = function(a)
			return cosh(a[1])
		end,
		tanh = function(a)
			return tanh(a[1])
		end,
		ln = function(a)
			return math.log(a[1])
		end,
		log = function(a)
			if #a >= 2 then
				return math.log(a[1]) / math.log(a[2])
			end
			return math.log(a[1], 10)
		end,
		log2 = function(a)
			return math.log(a[1], 2)
		end,
		log10 = function(a)
			return math.log(a[1], 10)
		end,
		exp = function(a)
			return math.exp(a[1])
		end,
		sqrt = function(a)
			return math.sqrt(a[1])
		end,
		cbrt = function(a)
			local x = a[1]
			if x < 0 then
				return -((-x) ^ (1 / 3))
			end
			return x ^ (1 / 3)
		end,
		abs = function(a)
			return math.abs(a[1])
		end,
		floor = function(a)
			return math.floor(a[1])
		end,
		ceil = function(a)
			return math.ceil(a[1])
		end,
		round = function(a)
			return math.round(a[1])
		end,
		trunc = function(a)
			local x = a[1]
			return x >= 0 and math.floor(x) or math.ceil(x)
		end,
		sign = function(a)
			return math.sign(a[1])
		end,
		mod = function(a)
			return a[1] % a[2]
		end,
		pow = function(a)
			return a[1] ^ a[2]
		end,
		hypot = function(a)
			return math.sqrt(a[1] * a[1] + a[2] * a[2])
		end,
		min = function(a)
			return math.min(table.unpack(a))
		end,
		max = function(a)
			return math.max(table.unpack(a))
		end,
	}
end

local function evaluate(source, degrees)
	local tokens = tokenize(source)
	if tokens == nil or #tokens == 0 then
		return nil
	end

	local functions = makeFunctions(degrees)
	local pos = 1
	local failed = false

	local function peek()
		return tokens[pos]
	end

	local function fail()
		failed = true
		return 0
	end

	local parseExpression
	local parseUnary

	local function parsePrimary()
		local token = peek()
		if token == nil then
			return fail()
		end

		if token.kind == "num" then
			pos += 1
			return token.value
		end

		if token.kind == "(" then
			pos += 1
			local value = parseExpression()
			local closing = peek()
			if closing == nil or closing.kind ~= ")" then
				return fail()
			end
			pos += 1
			return value
		end

		if token.kind == "name" then
			pos += 1
			local name = token.text
			local following = peek()

			if following ~= nil and following.kind == "(" then
				local fn = functions[name]
				if fn == nil then
					return fail()
				end
				pos += 1
				local args = {}
				if peek() ~= nil and peek().kind ~= ")" then
					table.insert(args, parseExpression())
					while peek() ~= nil and peek().kind == "," do
						pos += 1
						table.insert(args, parseExpression())
					end
				end
				local closing = peek()
				if closing == nil or closing.kind ~= ")" then
					return fail()
				end
				pos += 1
				if #args < (ARITY[name] or 1) then
					return fail()
				end
				return fn(args)
			end

			local constant = CONSTANTS[name]
			if constant ~= nil then
				return constant
			end
			return fail()
		end

		return fail()
	end

	local function parsePostfix()
		local value = parsePrimary()
		while true do
			local token = peek()
			if token ~= nil and token.kind == "op" and token.text == "%" then
				pos += 1
				value /= 100
			else
				break
			end
		end
		return value
	end

	local function parsePower()
		local base = parsePostfix()
		local token = peek()
		if token ~= nil and token.kind == "op" and token.text == "^" then
			pos += 1
			return base ^ parseUnary()
		end
		return base
	end

	function parseUnary()
		local token = peek()
		if token ~= nil and token.kind == "op" and (token.text == "-" or token.text == "+") then
			pos += 1
			local value = parseUnary()
			return token.text == "-" and -value or value
		end
		return parsePower()
	end

	local function parseTerm()
		local value = parseUnary()
		while true do
			local token = peek()
			if token ~= nil and token.kind == "op" and (token.text == "*" or token.text == "/") then
				pos += 1
				local rhs = parseUnary()
				if token.text == "*" then
					value *= rhs
				else
					if rhs == 0 then
						return fail()
					end
					value /= rhs
				end
			elseif token ~= nil and token.kind == "(" then
				value *= parseUnary()
			else
				break
			end
		end
		return value
	end

	function parseExpression()
		local value = parseTerm()
		while true do
			local token = peek()
			if token ~= nil and token.kind == "op" and (token.text == "+" or token.text == "-") then
				pos += 1
				local rhs = parseTerm()
				if token.text == "+" then
					value += rhs
				else
					value -= rhs
				end
			else
				break
			end
		end
		return value
	end

	local ok, value = pcall(parseExpression)
	if not ok or failed or pos <= #tokens then
		return nil
	end
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

local function formatNumber(value, precision)
	if value == 0 then
		return "0"
	end

	local magnitude = math.abs(value)
	if magnitude >= 1e16 or magnitude < 1e-9 then
		local text = string.format("%." .. math.min(precision, 8) .. "e", value)
		local mantissa, exponent = text:match("^(.-)e([-+]%d+)$")
		if mantissa ~= nil then
			if mantissa:find("%.") then
				mantissa = mantissa:gsub("0+$", ""):gsub("%.$", "")
			end
			local sign, digits = exponent:match("^([-+])0*(%d+)$")
			return mantissa .. "e" .. (sign == "-" and "-" or "") .. digits
		end
		return text
	end

	local text = string.format("%." .. precision .. "f", value)
	if text:find("%.") then
		text = text:gsub("0+$", ""):gsub("%.$", "")
	end
	if text == "-0" then
		return "0"
	end
	return text
end

local expression = ""
local lastExpression = ""
local result = "0"
local lastPreview = nil
local hasError = false
local inputKey = 0

local function precision()
	local value = noctalia.getConfig("precision")
	if type(value) ~= "number" then
		return 8
	end
	return math.clamp(math.floor(value), 0, 10)
end

local function useDegrees()
	return noctalia.getConfig("angle_unit") == "deg"
end

local function restore()
	local storedResult = noctalia.state.get("calc.result")
	if type(storedResult) == "string" and storedResult ~= "" then
		result = storedResult
	end
	local storedExpression = noctalia.state.get("calc.expression")
	if type(storedExpression) == "string" then
		expression = storedExpression
	end
	local storedLast = noctalia.state.get("calc.last_expression")
	if type(storedLast) == "string" then
		lastExpression = storedLast
	end
	hasError = noctalia.state.get("calc.error") == true
	lastPreview = nil
end

local function publish()
	noctalia.state.set("calc.result", result)
	noctalia.state.set("calc.expression", expression)
	noctalia.state.set("calc.last_expression", lastExpression)
	noctalia.state.set("calc.error", hasError)
end

local function preview()
	if expression == "" then
		return nil
	end
	local value = evaluate(expression, useDegrees())
	if value == nil then
		return nil
	end
	return formatNumber(value, precision())
end

local function displayValue()
	if hasError then
		return noctalia.tr("state.error")
	end
	if expression == "" then
		return result
	end
	local current = preview()
	if current ~= nil then
		lastPreview = current
	end
	return current or lastPreview or result
end

local function toggleSign()
	if expression == "" then
		expression = "-"
		return
	end

	local head, tail = expression:match("^(.-)([%d%.]+)$")
	if tail == nil then
		local last = expression:sub(-1)
		if last:match("[%+%-%*/%^%(]") then
			expression ..= "-"
		end
		return
	end

	local before = head:sub(-1)
	if before == "-" then
		local previous = head:sub(-2, -2)
		if head == "-" or previous:match("[%+%-%*/%^%(,]") then
			expression = head:sub(1, -2) .. tail
			return
		end
	end
	expression = head .. "-" .. tail
end

local render

local function clearAll()
	expression = ""
	lastExpression = ""
	result = "0"
	lastPreview = nil
	hasError = false
	inputKey += 1
end

local function commit()
	if expression == "" then
		return
	end

	local value = evaluate(expression, useDegrees())
	if value == nil then
		hasError = true
		lastExpression = expression
		expression = ""
		lastPreview = nil
		inputKey += 1
		return
	end

	result = formatNumber(value, precision())
	lastPreview = result
	lastExpression = expression
	expression = result
	hasError = false
	inputKey += 1
end

local function press(action, literal)
	if hasError and action ~= "clear" then
		hasError = false
		expression = ""
		lastExpression = ""
	end

	if action == "clear" then
		clearAll()
	elseif action == "delete" then
		expression = expression:sub(1, -2)
		inputKey += 1
	elseif action == "sign" then
		toggleSign()
		inputKey += 1
	elseif action == "equals" then
		commit()
	else
		expression ..= literal
		inputKey += 1
	end

	publish()
	render()
end

local KEYPAD = {
	{
		{ label = "AC", handler = "onCalcClear", variant = "destructive" },
		{ label = "+/-", handler = "onCalcSign", variant = "secondary" },
		{ label = "%", handler = "onCalcPercent", variant = "secondary" },
		{ label = "DEL", handler = "onCalcDelete", variant = "secondary" },
	},
	{
		{ label = "7", handler = "onCalcSeven" },
		{ label = "8", handler = "onCalcEight" },
		{ label = "9", handler = "onCalcNine" },
		{ label = "/", handler = "onCalcDivide", variant = "secondary" },
	},
	{
		{ label = "4", handler = "onCalcFour" },
		{ label = "5", handler = "onCalcFive" },
		{ label = "6", handler = "onCalcSix" },
		{ label = "*", handler = "onCalcMultiply", variant = "secondary" },
	},
	{
		{ label = "1", handler = "onCalcOne" },
		{ label = "2", handler = "onCalcTwo" },
		{ label = "3", handler = "onCalcThree" },
		{ label = "-", handler = "onCalcMinus", variant = "secondary" },
	},
	{
		{ label = "0", handler = "onCalcZero", grow = 2 },
		{ label = ".", handler = "onCalcDecimal" },
		{ label = "+", handler = "onCalcPlus", variant = "secondary" },
	},
	{
		{ label = "(", handler = "onCalcOpen", variant = "ghost" },
		{ label = ")", handler = "onCalcClose", variant = "ghost" },
		{ label = "=", handler = "onCalcEquals", variant = "primary", grow = 2 },
	},
}

local function keypadRow(row, rowIndex)
	local buttons = {}
	for index, spec in ipairs(row) do
		table.insert(
			buttons,
			ui.button({
				key = "k" .. rowIndex .. "-" .. index,
				text = spec.label,
				variant = spec.variant or "default",
				fontSize = 15,
				height = 34,
				flexGrow = spec.grow or 1,
				onClick = spec.handler,
			})
		)
	end
	return ui.row({ key = "row" .. rowIndex, gap = 6 }, buttons)
end

function render()
	local shown = displayValue()
	local hint = hasError and lastExpression or (expression ~= "" and expression or lastExpression)
	local atRest = shown == "0" and expression == "" and lastExpression == ""
	local canCopy = not hasError and shown ~= "" and not atRest

	local keypad = {}
	for index, row in ipairs(KEYPAD) do
		table.insert(keypad, keypadRow(row, index))
	end

	panel.render(ui.column({ gap = 10, padding = 14 }, {
		ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "calculator", size = 16, color = "primary" }),
			ui.label({
				text = noctalia.tr("panel.title"),
				fontSize = 15,
				fontWeight = "bold",
				color = "on_surface",
				flexGrow = 1,
			}),
			ui.label({
				text = noctalia.tr(useDegrees() and "panel.deg" or "panel.rad"),
				fontSize = 11,
				color = "on_surface/0.55",
			}),
		}),

		ui.column({ gap = 2, padding = 10, fill = "primary/0.08", radius = 10 }, {
			ui.label({
				text = hint,
				fontSize = 11,
				color = "on_surface/0.6",
				textAlign = "right",
				maxLines = 1,
			}),
			ui.row({ gap = 6, align = "center" }, {
				ui.label({
					text = shown,
					fontSize = 30,
					fontWeight = "bold",
					color = hasError and "error" or "on_surface",
					textAlign = "right",
					maxLines = 1,
					flexGrow = 1,
				}),
				ui.button({
					key = "copy",
					glyph = "copy",
					glyphSize = 15,
					variant = "ghost",
					controlSize = "sm",
					contentAlign = "center",
					tooltip = noctalia.tr("panel.copy"),
					visible = canCopy,
					onClick = "onCalcCopy",
				}),
			}),
		}),

		ui.input({
			key = "expr-" .. inputKey,
			value = expression,
			placeholder = noctalia.tr("panel.placeholder"),
			fontSize = 13,
			controlSize = "sm",
			focus = true,
			onChange = "onCalcInputChange",
			onSubmit = "onCalcInputSubmit",
		}),

		ui.column({ gap = 6 }, keypad),
	}))
end

function onCalcClear()
	press("clear")
end

function onCalcSign()
	press("sign")
end

function onCalcPercent()
	press("append", "%")
end

function onCalcDelete()
	press("delete")
end

function onCalcZero()
	press("append", "0")
end

function onCalcOne()
	press("append", "1")
end

function onCalcTwo()
	press("append", "2")
end

function onCalcThree()
	press("append", "3")
end

function onCalcFour()
	press("append", "4")
end

function onCalcFive()
	press("append", "5")
end

function onCalcSix()
	press("append", "6")
end

function onCalcSeven()
	press("append", "7")
end

function onCalcEight()
	press("append", "8")
end

function onCalcNine()
	press("append", "9")
end

function onCalcDecimal()
	press("append", ".")
end

function onCalcPlus()
	press("append", "+")
end

function onCalcMinus()
	press("append", "-")
end

function onCalcMultiply()
	press("append", "*")
end

function onCalcDivide()
	press("append", "/")
end

function onCalcOpen()
	press("append", "(")
end

function onCalcClose()
	press("append", ")")
end

function onCalcEquals()
	press("equals")
end

function onCalcCopy()
	local shown = displayValue()
	if hasError or shown == "" then
		return
	end
	if noctalia.copyToClipboard(shown, "text/plain") then
		noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.copied", { value = shown }))
	end
end

function onCalcInputChange(value)
	expression = value
	hasError = false
	publish()
	render()
end

function onCalcInputSubmit()
	press("equals")
end

function onOpen(_context)
	restore()
	inputKey += 1
	render()
end

function onIpc(event, payload)
	if event == "clear" then
		clearAll()
	elseif event == "eval" and type(payload) == "string" then
		expression = payload
		commit()
	elseif event == "insert" and type(payload) == "string" then
		expression ..= payload
		inputKey += 1
	else
		return
	end
	publish()
	render()
end

noctalia.state.watch("calc.expression", function(value)
	if type(value) ~= "string" or value == expression then
		return
	end
	restore()
	inputKey += 1
	render()
end)

restore()
publish()
