-- Calculator: "2+2*2=" or "/calc 2+2*2" is sent as "2+2*2 = 6", and
-- "Calculate" in a message menu counts someone else's expression.
-- The expression is read by our own parser: plugins have no load(), and
-- that is good, no code from a message can ever run. The decimal
-- separator, digits, grouping and angles are on the settings page, along
-- with the last results.

-- The example on the settings page: its answer changes with the settings.
local EXAMPLE = "1234567/7"

-- How many results the history keeps.
local HISTORY = 10

local function setting(key, default)
	return plugin.settings.get(key, default)
end

-- Plain ASCII spaces: what %s means depends on the C locale, and a byte of
-- a Cyrillic letter must never be cut off as a "space".
local function trim(text)
	return (text:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

-- Rounding functions give floats back: integers in Lua overflow silently,
-- and "floor(9e18)+floor(9e18)" must not turn negative.
local function float(fn)
	return function(x)
		return fn(x) * 1.0
	end
end

-- Functions for the angle unit of the settings: sin(90) is 1 in degrees.
local function functions(degrees)
	local k = degrees and math.pi / 180 or 1
	local log10 = function(x) return math.log(x, 10) end
	return {
		sqrt = math.sqrt,
		cbrt = function(x)
			return x < 0 and -((-x) ^ (1 / 3)) or x ^ (1 / 3)
		end,
		abs = math.abs,
		floor = float(math.floor),
		ceil = float(math.ceil),
		round = float(function(x) return math.floor(x + 0.5) end),
		exp = math.exp,
		ln = math.log,
		log = log10,
		lg = log10,
		sin = function(x) return math.sin(x * k) end,
		cos = function(x) return math.cos(x * k) end,
		tan = function(x) return math.tan(x * k) end,
		asin = function(x) return math.asin(x) / k end,
		acos = function(x) return math.acos(x) / k end,
		atan = function(x) return math.atan(x) / k end,
	}
end

-- "ans" is the last result, kept between runs.
local function constants()
	return { pi = math.pi, e = math.exp(1), ans = setting("ans", nil) }
end

local function factorial(n)
	if n < 0 or n ~= math.floor(n) or n > 170 then
		error("bad factorial")
	end
	local result = 1.0
	for i = 2, n do
		result = result * i
	end
	return result
end

-- "1,000,000" -> "1000000": commas between groups of three are thousands
-- when there are two of them at least; "1,500" stays a decimal 1.5.
local function thousands(number)
	local parts = {}
	for part in number:gmatch("[^,]+") do
		parts[#parts + 1] = part
	end
	if #parts < 3 or #parts[1] > 3 or number:find(",,") then
		return nil
	end
	for i = 2, #parts do
		if #parts[i] ~= 3 then
			return nil
		end
	end
	return table.concat(parts)
end

local function repeatGsub(text, pattern, replacement)
	local count
	repeat
		text, count = text:gsub(pattern, replacement)
	until count == 0
	return text
end

-- Text as people type it -> text the tokenizer reads. The second value
-- tells whether the expression had a decimal comma ("2,5").
local function normalize(text)
	text = text:gsub("×", "*"):gsub("·", "*"):gsub("÷", "/"):gsub("−", "-")
		:gsub("√", "sqrt "):gsub("π", "pi"):gsub("%*%*", "^")
	-- No-break and thin spaces come with numbers copied from elsewhere.
	text = text:gsub("\u{a0}", " "):gsub("\u{202f}", " "):gsub("\u{2009}", " ")
	text = text:gsub("%d[%d,]*%d", thousands)
	-- "15 000": a space inside a number groups its digits.
	text = repeatGsub(text, "(%d) (%d%d%d)%f[^%d]", "%1%2")
	-- "2x3", "2 х 3" (the Cyrillic one too) are multiplication.
	text = repeatGsub(text, "(%d)%s*[xX]%s*(%d)", "%1*%2")
	text = repeatGsub(text, "(%d)%s*х%s*(%d)", "%1*%2")
	text = repeatGsub(text, "(%d)%s*Х%s*(%d)", "%1*%2")
	local commas
	text, commas = text:gsub("(%d),(%d)", "%1.%2")
	return text, commas > 0
end

local function tokenize(text)
	local tokens, i = {}, 1
	while i <= #text do
		local c = text:sub(i, i)
		if c:match("[ \t\r\n]") then
			i = i + 1
		else
			local number = text:match("^%d+%.?%d*", i) or text:match("^%.%d+", i)
			if number then
				-- "1e-5": an exponent right after the digits.
				local exponent = text:match("^[eE][%+%-]?%d+", i + #number) or ""
				-- Floats: integers in Lua overflow silently.
				tokens[#tokens + 1] = { kind = "number", value = tonumber(number .. exponent) * 1.0 }
				i = i + #number + #exponent
			else
				local word = text:match("^[A-Za-z]+", i)
				if word then
					tokens[#tokens + 1] = { kind = "word", value = word:lower() }
					i = i + #word
				elseif c:match("[%+%-%*/%%%^%(%)!]") then
					tokens[#tokens + 1] = { kind = c }
					i = i + 1
				else
					return nil
				end
			end
		end
	end
	return tokens
end

-- Recursive descent: addition < multiplication < unary minus < power <
-- factorial. "2pi" and "2(1+1)" multiply without a sign.
local function parse(tokens, fns, consts)
	local position = 1
	local function peek()
		return tokens[position]
	end
	local function take()
		position = position + 1
		return tokens[position - 1]
	end
	local function accept(kind)
		local token = tokens[position]
		if token and token.kind == kind then
			position = position + 1
			return token
		end
	end
	-- Can this token start an operand? It tells "15%" (percent) from
	-- "7 % 3" (remainder).
	local function startsOperand(token)
		return token ~= nil
			and (token.kind == "number" or token.kind == "word" or token.kind == "(")
	end

	local expression, unary, power
	-- After "(": the value and its ")". A ")" missing at the very end is
	-- forgiven, "sqrt(2" means sqrt(2).
	local function group()
		local value = expression()
		if not accept(")") and peek() then
			error("no )")
		end
		return value
	end
	local function primary()
		local token = take()
		if not token then
			error("unexpected end")
		elseif token.kind == "number" then
			return token.value
		elseif token.kind == "(" then
			return group()
		elseif token.kind == "word" then
			local fn = fns[token.value]
			if fn then
				-- "sqrt(16)", and also "sqrt 16" and "√16".
				if accept("(") then
					return fn(group())
				end
				return fn(power())
			elseif consts[token.value] then
				return consts[token.value]
			end
		end
		error("bad token")
	end
	local function postfix()
		local value = primary()
		while accept("!") do
			value = factorial(value)
		end
		return value
	end
	power = function()
		local base = postfix()
		if accept("^") then
			return base ^ unary()
		end
		return base
	end
	unary = function()
		if accept("-") then return -unary() end
		if accept("+") then return unary() end
		return power()
	end
	-- The second value: the term is a bare percentage, "10%" in
	-- "1000-10%" = 900. "2*10%" is just 0.2 of something, not a share.
	local function term()
		local value = unary()
		local plain, percent = true, false
		while true do
			local token = peek()
			if accept("*") then
				value = value * unary()
				percent = false
			elseif accept("/") then
				value = value / unary()
				percent = false
			elseif accept("%") then
				if startsOperand(peek()) then
					value = math.fmod(value, unary())
					percent = false
				else
					value = value / 100
					percent = plain
				end
			elseif token and (token.kind == "(" or token.kind == "word") then
				value = value * unary()
				percent = false
			else
				return value, percent
			end
			plain = false
		end
	end
	expression = function()
		local value = term()
		while true do
			local sign = accept("+") and 1 or (accept("-") and -1)
			if not sign then
				return value
			end
			local part, percent = term()
			if percent then
				part = value * part
			end
			value = value + sign * part
		end
	end

	local value = expression()
	if position <= #tokens then
		error("extra tokens")
	end
	return value
end

-- The value and whether the expression wrote decimals with a comma.
local function evaluate(text)
	local normalized, comma = normalize(text)
	local tokens = tokenize(normalized)
	if not tokens or #tokens == 0 then
		return nil
	end
	local degrees = setting("angles", 1) == 2
	local ok, value = pcall(parse, tokens, functions(degrees), constants())
	if not ok or type(value) ~= "number" or value ~= value
		or value == math.huge or value == -math.huge then
		return nil
	end
	return value, comma
end

-- Comma or point: as in the expression, or always one of them.
local function useComma(comma)
	local separator = setting("separator", 1)
	if separator == 2 then
		return false
	elseif separator == 3 then
		return true
	end
	return comma
end

-- "1,234,567.5" or "1 234 567,5". Four digits read fine without a space in
-- the comma style, as people write them by hand.
local function groupDigits(whole, separator, minimum)
	if #whole < minimum then
		return whole
	end
	local grouped = whole:reverse():gsub("(%d%d%d)", "%1" .. separator):reverse()
	if grouped:sub(1, 1) == separator then
		grouped = grouped:sub(2)
	end
	return grouped
end

local function format(value, comma)
	comma = useComma(comma)
	local result
	local integer = math.tointeger(value)
	if integer and math.abs(value) < 1e15 then
		result = tostring(integer)
	else
		local digits = math.floor(setting("digits", 10))
		digits = math.max(3, math.min(digits, 15))
		result = string.format("%." .. digits .. "g", value)
	end
	local sign, whole, rest = result:match("^(-?)(%d+)(.*)$")
	if not whole then
		return result
	end
	if setting("group", false) and not rest:find("e") then
		whole = comma and groupDigits(whole, " ", 5) or groupDigits(whole, ",", 4)
	end
	if comma then
		rest = rest:gsub("%.", ",")
	end
	return sign .. whole .. rest
end

-- "2+2*2 = 6" or only "6".
local function answer(expression, result)
	if setting("result_only", false) then
		return result
	end
	return expression .. " = " .. result
end

local function loadHistory()
	local history = tg.json.decode(setting("history", "[]"))
	return type(history) == "table" and history or {}
end

-- The result becomes "ans" and goes to the top of the history.
local function remember(expression, value, result)
	plugin.settings.set("ans", value)
	local history = loadHistory()
	table.insert(history, 1, { expression = expression, result = result })
	while #history > HISTORY do
		table.remove(history)
	end
	plugin.settings.set("history", tg.json.encode(history))
end

-- "Hello =" and the like stay as they are: only digits and operations.
local function looksLikeMath(expression)
	local text = normalize(expression)
	return text:find("%d") ~= nil
		and text:match("^[A-Za-z0-9%s%.,%+%-%*/%%%^%(%)!]+$") ~= nil
		and (text:find("[%+%*/%%%^!%(]") or text:find(".%-") or text:find("[A-Za-z]")) ~= nil
end

-- "How much is 15*12 for a dozen?": the longest piece of digits and
-- operations in words around it that counts. It comes normalized, so the
-- second value tells whether the text wrote decimals with a comma.
local function findExpression(text)
	local best
	local normalized, comma = normalize(text)
	for piece in normalized:gmatch("[%d%s%.,%+%-%*/%%%^%(%)!]+") do
		piece = trim((piece:gsub("[%s=,%.]+$", "")))
		if (not best or #piece > #best) and looksLikeMath(piece) and evaluate(piece) then
			best = piece
		end
	end
	return best, comma
end

plugin.on("message.send", function(draft)
	local text = draft.text
	if text:match("^/calc%s*$") then
		notify(plugin.t("error.usage"))
		return false
	end
	local command = text:match("^/calc%s+(.+)$")
	local expression = command
	if not command then
		if not setting("equals", true) then
			return nil
		end
		expression = text:match("^(.-)%s*=%s*$")
		if not expression or not looksLikeMath(expression) then
			return nil
		end
	end
	expression = trim(expression)
	local value, comma = evaluate(expression)
	if not value then
		if command then
			notify(plugin.t("error.parse"))
			return false
		end
		return nil
	end
	local result = format(value, comma)
	remember(expression, value, result)
	return answer(expression, result)
end)

plugin.menu{
	place = "message",
	text = plugin.t("menu.calc"),
	icon = "stats",
	on_click = function(ctx)
		local text = ctx.message and ctx.message.text
		if not text or trim(text) == "" then
			notify(plugin.t("toast.no_text"))
			return
		end
		-- "2+2=" or "2+2 = ?" from a question in a chat.
		local expression = trim((trim(text):gsub("[%s=%?]+$", "")))
		local value, comma = evaluate(expression)
		if not value then
			local found, hadComma = findExpression(text)
			if found then
				expression = found
				value = evaluate(found)
				comma = hadComma
			end
		end
		if not value then
			notify(plugin.t("error.parse"))
			return
		end
		local result = format(value, comma)
		remember(expression, value, result)
		tg.ui.copy(result)
		notify(plugin.t("toast.copied", { expression = expression, result = result }))
	end,
}

-- The page is built every time it opens and after refresh(): the example
-- shows the answer with the current settings.
local function refresh()
	plugin.settings.refresh()
end

plugin.settings.page(function()
	local example, exampleComma = evaluate(EXAMPLE)
	local rows = {
		{ type = "header", text = plugin.t("settings.counting") },
		{
			type = "switch",
			key = "equals",
			text = plugin.t("settings.equals"),
			subtext = plugin.t("settings.equals.about"),
			icon = "edit",
			default = true,
		},
		{
			type = "switch",
			key = "result_only",
			text = plugin.t("settings.result_only"),
			subtext = plugin.t("settings.result_only.about"),
			icon = "reply",
			default = false,
			on_change = refresh,
		},
		{
			type = "selector",
			key = "angles",
			text = plugin.t("settings.angles"),
			items = {
				plugin.t("settings.angles.radians"),
				plugin.t("settings.angles.degrees"),
			},
			default = 1,
			icon = "customize",
		},
		{ type = "header", text = plugin.t("settings.numbers") },
		{
			type = "selector",
			key = "separator",
			text = plugin.t("settings.separator"),
			items = {
				plugin.t("settings.separator.auto"),
				plugin.t("settings.separator.point"),
				plugin.t("settings.separator.comma"),
			},
			default = 1,
			icon = "font",
			on_change = refresh,
		},
		{
			type = "switch",
			key = "group",
			text = plugin.t("settings.group"),
			subtext = plugin.t("settings.group.about"),
			icon = "select",
			default = false,
			on_change = refresh,
		},
		{
			type = "slider",
			key = "digits",
			text = plugin.t("settings.digits"),
			subtext = plugin.t("settings.digits.about"),
			icon = "info",
			min = 3,
			max = 15,
			step = 1,
			default = 10,
			on_change = refresh,
		},
		{
			type = "text",
			text = plugin.t("settings.example"),
			subtext = answer(EXAMPLE, format(example, exampleComma)),
			icon = "eye",
		},
	}
	local history = loadHistory()
	if #history > 0 then
		rows[#rows + 1] = { type = "header", text = plugin.t("settings.history") }
		for _, item in ipairs(history) do
			local result = item.result
			rows[#rows + 1] = {
				type = "text",
				text = item.expression,
				subtext = "= " .. result,
				icon = "copy",
				on_click = function()
					tg.ui.copy(result)
					notify(plugin.t("toast.copied_result", result))
				end,
			}
		end
		rows[#rows + 1] = {
			type = "text",
			text = plugin.t("settings.history.clear"),
			icon = "delete",
			red = true,
			on_click = function()
				plugin.settings.set("history", "[]")
				plugin.settings.set("ans", nil)
				refresh()
			end,
		}
	end
	rows[#rows + 1] = { type = "divider", text = plugin.t("settings.supported") }
	return rows
end)
