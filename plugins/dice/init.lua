-- Dice: "/roll 2d6+3" is sent as "🎲 2d6+3: 4 + 2 + 3 = 9". Also /coin,
-- /pick a | b | c, /rand 1 100 and /8ball. The result replaces the command,
-- so a reply stays a reply. Russian names work too: /кубик, /монетка,
-- /выбери, /число, /шар.

local BALL_ANSWERS = 20
local MAX_DICE = 100
local MAX_SIDES = 1000000
local MAX_TERMS = 10
local LIST_LIMIT = 20 -- more dice than this show only the sum

-- Lowercase for ASCII only: string.lower depends on the C locale and may
-- break UTF-8 bytes.
local function asciiLower(text)
	return (text:gsub("[A-Z]", function(c)
		return string.char(c:byte() + 32)
	end))
end

local function random(from, to)
	return math.random(from, to)
end

-- Roll ------------------------------------------------------------------------------

-- "2d6+1d4-1" -> terms { { sign, count, sides } or { sign, value } }.
local function parseRoll(expression)
	expression = asciiLower(expression):gsub("%s+", ""):gsub("д", "d"):gsub("Д", "d")
	if expression == "" then
		expression = "d6"
	elseif expression:match("^%d+$") then
		expression = "d" .. expression -- "/roll 20" is a d20
	end
	local terms, rebuilt = {}, ""
	for sign, body in expression:gmatch("([%+%-]?)([^%+%-]+)") do
		rebuilt = rebuilt .. sign .. body
		local count, sides = body:match("^(%d*)d(%d+)$")
		if not count and body:match("^(%d*)d%%$") then
			count, sides = body:match("^(%d*)d"), "100"
		end
		local term = { sign = (sign == "-") and -1 or 1 }
		if count then
			term.count = (count == "") and 1 or tonumber(count)
			term.sides = tonumber(sides)
			if term.count < 1 or term.count > MAX_DICE
				or term.sides < 1 or term.sides > MAX_SIDES then
				return nil
			end
		elseif body:match("^%d+$") and #body <= 9 then
			term.value = tonumber(body)
		else
			return nil
		end
		terms[#terms + 1] = term
	end
	if rebuilt ~= expression or #terms == 0 or #terms > MAX_TERMS then
		return nil
	end
	return terms, expression
end

local function roll(argument)
	local terms, expression = parseRoll(argument)
	if not terms then
		return nil
	end
	local parts, total, listed = {}, 0, true
	local function addPart(sign, text)
		if #parts == 0 then
			parts[1] = (sign < 0) and ("-" .. text) or text
		else
			parts[#parts + 1] = ((sign < 0) and "- " or "+ ") .. text
		end
	end
	for _, term in ipairs(terms) do
		if term.value then
			total = total + term.sign * term.value
			addPart(term.sign, tostring(term.value))
		else
			local values, sum = {}, 0
			for index = 1, term.count do
				local value = random(1, term.sides)
				values[index] = tostring(value)
				sum = sum + value
			end
			total = total + term.sign * sum
			if term.count > LIST_LIMIT then
				listed = false
				addPart(term.sign, tostring(sum))
			elseif term.sign < 0 and term.count > 1 then
				addPart(-1, "(" .. table.concat(values, " + ") .. ")")
			else
				for index, value in ipairs(values) do
					addPart((index == 1) and term.sign or 1, value)
				end
			end
		end
	end
	local result
	if #parts == 1 and (listed or #terms == 1) then
		result = tostring(total)
	else
		result = table.concat(parts, " ") .. " = " .. tostring(total)
	end
	return "🎲 " .. expression .. ": " .. result
end

-- Other commands ----------------------------------------------------------------

local function coin()
	return "🪙 " .. ((random(1, 2) == 1) and plugin.t("coin.heads") or plugin.t("coin.tails"))
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "a | b | c", "a, b, c", "a or b", "a или b".
local function splitOptions(text)
	local separators = { "|", ",", ";", "\n" }
	for _, separator in ipairs(separators) do
		if text:find(separator, 1, true) then
			local options = {}
			for piece in (text .. separator):gmatch("(.-)" .. "%" .. separator) do
				piece = trim(piece)
				if piece ~= "" then
					options[#options + 1] = piece
				end
			end
			return options
		end
	end
	local options = {}
	local spaced = " " .. text .. " "
	for _, word in ipairs({ " or ", " или ", " OR ", " ИЛИ " }) do
		if spaced:find(word, 1, true) then
			local position = 1
			while true do
				local from, to = spaced:find(word, position, true)
				local piece = trim(spaced:sub(position, from and (from - 1) or #spaced))
				if piece ~= "" then
					options[#options + 1] = piece
				end
				if not from then
					break
				end
				position = to + 1
			end
			return options
		end
	end
	return options
end

local function pick(argument)
	local options = splitOptions(argument)
	if #options < 2 then
		return nil
	end
	local chosen = options[random(1, #options)]
	return "🎯 " .. table.concat(options, " | ") .. " → " .. chosen
end

local function rand(argument)
	argument = trim(argument)
	local numbers = {}
	local a, b = argument:match("^(%-?%d+)%s*%.%.%s*(%-?%d+)$")
	if not a then
		a, b = argument:match("^(%-?%d+)%-(%-?%d+)$")
	end
	if not a then
		a, b = argument:match("^(%-?%d+)–(%-?%d+)$")
	end
	if a then
		numbers = { a, b }
	elseif argument ~= "" then
		for piece in argument:gmatch("%S+") do
			if not piece:match("^%-?%d+$") then
				return nil
			end
			numbers[#numbers + 1] = piece
		end
	end
	if #numbers > 2 then
		return nil
	end
	for index, number in ipairs(numbers) do
		if #number > 13 then
			return nil
		end
		numbers[index] = math.tointeger(tonumber(number))
	end
	local from, to = 1, 100
	if #numbers == 1 then
		to = numbers[1]
	elseif #numbers == 2 then
		from, to = numbers[1], numbers[2]
	end
	if from > to then
		from, to = to, from
	end
	return "🔢 " .. from .. "–" .. to .. ": " .. random(from, to)
end

local function ball(argument)
	local answer = plugin.t("ball." .. random(1, BALL_ANSWERS))
	argument = trim(argument)
	if argument == "" then
		return "🎱 " .. answer
	end
	return "🎱 " .. argument .. " — " .. answer
end

local COMMANDS = {
	roll = roll, ["кубик"] = roll, dice = roll,
	coin = coin, ["монетка"] = coin, ["монета"] = coin,
	pick = pick, choose = pick, ["выбери"] = pick,
	rand = rand, random = rand, ["число"] = rand,
	["8ball"] = ball, ["шар"] = ball,
}

local USAGE = {
	[roll] = "usage.roll",
	[pick] = "usage.pick",
	[rand] = "usage.rand",
}

local function botChat(peer)
	if not plugin.settings.get("skip_bots", true) then
		return false
	end
	local info = tg.peers.get(peer)
	return info ~= nil and info.type == "bot"
end

plugin.on("message.send", function(draft)
	local text = draft.text
	local name, argument = text:match("^/(%S+)%s*(.-)%s*$")
	if not name then
		return nil
	end
	local command = COMMANDS[asciiLower(name)]
	if not command or botChat(draft.peer) then
		return nil
	end
	local ok, result = pcall(command, argument)
	if not ok or not result then
		tg.toast({
			title = plugin.t("title"),
			text = plugin.t(USAGE[command] or "usage.roll"),
			duration = 6000,
		})
		return false
	end
	if plugin.settings.get("keep_command", false) then
		result = text .. "\n" .. result
	end
	return result
end)

plugin.settings.page(function()
	return {
		{ type = "header", text = plugin.t("settings.message") },
		{
			type = "switch",
			key = "keep_command",
			text = plugin.t("settings.keep_command"),
			subtext = plugin.t("settings.keep_command.about"),
			icon = "reply",
			default = false,
		},
		{
			type = "switch",
			key = "skip_bots",
			text = plugin.t("settings.skip_bots"),
			subtext = plugin.t("settings.skip_bots.about"),
			icon = "bot",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.commands") },
	}
end)
